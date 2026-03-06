// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";

import {JBSwapTerminal} from "./JBSwapTerminal.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {JBSwapLib} from "./libraries/JBSwapLib.sol";

/// @notice Extends JBSwapTerminal with automatic pool discovery. When no pool is configured for a token,
/// the terminal searches the Uniswap V3 factory for an existing pool across common fee tiers and uses it.
/// This enables projects to accept any token that has a Uniswap V3 pool without manual configuration.
contract JBMultiSwapTerminal is JBSwapTerminal {
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBMultiSwapTerminal_NoPoolFound(address tokenIn, address tokenOut);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The default TWAP window used for auto-discovered pools that have no configured twapWindow.
    uint256 public constant DEFAULT_TWAP_WINDOW = 10 minutes;

    /// @notice The fee tiers to search when auto-discovering pools, ordered by commonality.
    /// 3000 = 0.3%, 500 = 0.05%, 10000 = 1%, 100 = 0.01%.
    uint24[4] public FEE_TIERS = [uint24(3000), uint24(500), uint24(10_000), uint24(100)];

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBProjects projects,
        IPermit2 permit2,
        address owner,
        IWETH9 weth,
        address tokenOut,
        IUniswapV3Factory factory,
        address trustedForwarder
    )
        JBSwapTerminal(directory, permissions, projects, permit2, owner, weth, tokenOut, factory, trustedForwarder)
    {}

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Public wrapper for _discoverPool, useful for off-chain queries.
    /// @param normalizedTokenIn The input token (wrapped if native).
    /// @param normalizedTokenOut The output token (wrapped if native).
    /// @return pool The pool with the highest liquidity.
    function discoverPool(
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        external
        view
        returns (IUniswapV3Pool pool)
    {
        return _discoverPool(normalizedTokenIn, normalizedTokenOut);
    }

    /// @notice Returns an accounting context for any token. For configured tokens, returns the stored context.
    /// For unconfigured tokens, returns a dynamic 18-decimal context since this terminal can auto-discover pools.
    /// @param projectId The ID of the project to get the accounting context for.
    /// @param token The address of the token to get the accounting context for.
    /// @return context The accounting context for the project ID and token.
    function accountingContextForTokenOf(
        uint256 projectId,
        address token
    )
        external
        view
        override
        returns (JBAccountingContext memory context)
    {
        // Try the parent's stored context first.
        context = _accountingContextFor[projectId][token];
        if (context.token != address(0)) return context;

        context = _accountingContextFor[DEFAULT_PROJECT_ID][token];
        if (context.token != address(0)) return context;

        // No stored context — return a dynamic one for auto-discovered tokens.
        context = JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Override to support auto-discovered pools via factory verification.
    /// @dev If a stored pool matches msg.sender, uses parent behavior. Otherwise, verifies
    ///      msg.sender was deployed by the factory for the correct token pair and fee.
    /// @param amount0Delta The amount of token 0 being used for the swap.
    /// @param amount1Delta The amount of token 1 being used for the swap.
    /// @param data Data passed in by the swap operation.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        // Unpack the data from the original swap config.
        (uint256 projectId, address tokenIn) = abi.decode(data, (uint256, address));

        // Normalize the token (wrap native token if needed).
        address normalizedTokenIn = tokenIn == JBConstants.NATIVE_TOKEN ? address(WETH) : tokenIn;

        // Check stored pools first.
        IUniswapV3Pool storedPool = _poolFor[projectId][normalizedTokenIn];
        if (address(storedPool) == address(0)) storedPool = _poolFor[DEFAULT_PROJECT_ID][normalizedTokenIn];

        if (msg.sender == address(storedPool)) {
            // Configured pool — proceed with transfer.
        } else {
            // No stored pool match — verify via factory.
            address normalizedTokenOut = _normalizedTokenOut();
            uint24 fee = IUniswapV3Pool(msg.sender).fee();
            address expectedPool = FACTORY.getPool(normalizedTokenIn, normalizedTokenOut, fee);

            if (msg.sender != expectedPool) revert JBSwapTerminal_CallerNotPool(msg.sender);
        }

        // Calculate the amount of tokens to send to the pool (the positive delta).
        uint256 amountToSendToPool = amount0Delta < 0 ? uint256(amount1Delta) : uint256(amount0Delta);

        // Wrap native tokens if needed.
        if (tokenIn == JBConstants.NATIVE_TOKEN) WETH.deposit{value: amountToSendToPool}();

        // Transfer the tokens to the pool.
        IERC20(normalizedTokenIn).safeTransfer(msg.sender, amountToSendToPool);
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Override to add auto-discovery when no configured pool exists.
    /// @dev If a pool is configured (project-specific or default), uses parent behavior.
    ///      If no pool is configured, searches the factory for the best pool.
    ///      For auto-discovered pools without a user quote, uses DEFAULT_TWAP_WINDOW for TWAP.
    /// @param metadata The metadata in which `quoteForSwap` context is provided.
    /// @param projectId The ID of the project for which the swap is being performed.
    /// @param normalizedTokenIn The address of the token being swapped.
    /// @param amount The amount of tokens to swap.
    /// @param normalizedTokenOut The address of the token to receive.
    /// @return minAmountOut The minimum amount of tokens to receive from the swap.
    /// @return pool The pool to perform the swap in.
    function _pickPoolAndQuote(
        bytes calldata metadata,
        uint256 projectId,
        address normalizedTokenIn,
        uint256 amount,
        address normalizedTokenOut
    )
        internal
        view
        override
        returns (uint256 minAmountOut, IUniswapV3Pool pool)
    {
        // Try configured pools first (project-specific, then default).
        pool = _poolFor[projectId][normalizedTokenIn];
        if (address(pool) == address(0)) {
            pool = _poolFor[DEFAULT_PROJECT_ID][normalizedTokenIn];
        }

        // If a configured pool exists, use the parent's full logic.
        if (address(pool) != address(0)) {
            return super._pickPoolAndQuote(metadata, projectId, normalizedTokenIn, amount, normalizedTokenOut);
        }

        // No configured pool — auto-discover from factory.
        pool = _discoverPool(normalizedTokenIn, normalizedTokenOut);

        // Check for a user-provided quote.
        (bool exists, bytes memory quote) =
            JBMetadataResolver.getDataFor({id: JBMetadataResolver.getId("quoteForSwap"), metadata: metadata});

        if (exists) {
            (minAmountOut) = abi.decode(quote, (uint256));
        } else {
            // No user quote — use TWAP with DEFAULT_TWAP_WINDOW.
            uint32 oldestObservation = OracleLibrary.getOldestObservationSecondsAgo(address(pool));

            if (oldestObservation == 0) revert JBSwapTerminal_NoObservationHistory();

            uint256 twapWindow = DEFAULT_TWAP_WINDOW;
            if (oldestObservation < twapWindow) twapWindow = oldestObservation;

            (int24 arithmeticMeanTick, uint128 liquidity) =
                OracleLibrary.consult({pool: address(pool), secondsAgo: uint32(twapWindow)});

            if (liquidity == 0) revert JBSwapTerminal_NoLiquidity();

            {
                uint256 slippageTolerance = _getSlippageTolerance({
                    amountIn: amount,
                    liquidity: liquidity,
                    tokenOut: normalizedTokenOut,
                    tokenIn: normalizedTokenIn,
                    arithmeticMeanTick: arithmeticMeanTick,
                    poolFeeBps: uint256(pool.fee()) / 100
                });

                if (slippageTolerance >= SLIPPAGE_DENOMINATOR) return (0, pool);

                if (amount > type(uint128).max) revert JBSwapTerminal_AmountOverflow(amount);
                minAmountOut = OracleLibrary.getQuoteAtTick({
                    tick: arithmeticMeanTick,
                    baseAmount: uint128(amount),
                    baseToken: normalizedTokenIn,
                    quoteToken: normalizedTokenOut
                });

                minAmountOut -= (minAmountOut * slippageTolerance) / SLIPPAGE_DENOMINATOR;
            }
        }
    }

    /// @notice Search the Uniswap V3 factory for a pool between two tokens across common fee tiers.
    /// @dev Returns the pool with the highest liquidity. Reverts if no pool exists.
    /// @param normalizedTokenIn The input token (wrapped if native).
    /// @param normalizedTokenOut The output token (wrapped if native).
    /// @return bestPool The pool with the highest liquidity.
    function _discoverPool(
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        internal
        view
        returns (IUniswapV3Pool bestPool)
    {
        uint128 bestLiquidity;

        for (uint256 i; i < 4; i++) {
            address poolAddr = FACTORY.getPool(normalizedTokenIn, normalizedTokenOut, FEE_TIERS[i]);

            if (poolAddr == address(0)) continue;

            uint128 poolLiquidity = IUniswapV3Pool(poolAddr).liquidity();

            if (poolLiquidity > bestLiquidity) {
                bestLiquidity = poolLiquidity;
                bestPool = IUniswapV3Pool(poolAddr);
            }
        }

        if (address(bestPool) == address(0)) {
            revert JBMultiSwapTerminal_NoPoolFound(normalizedTokenIn, normalizedTokenOut);
        }
    }
}
