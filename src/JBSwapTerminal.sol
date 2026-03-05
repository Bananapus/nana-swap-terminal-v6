// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissioned} from "@bananapus/core-v6/src/interfaces/IJBPermissioned.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPermitTerminal} from "@bananapus/core-v6/src/interfaces/IJBPermitTerminal.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";

import {IJBSwapTerminal} from "./interfaces/IJBSwapTerminal.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {JBSwapLib} from "./libraries/JBSwapLib.sol";

/// @notice The `JBSwapTerminal` accepts payments in any token. When the `JBSwapTerminal` is paid, it uses a Uniswap
/// pool to exchange the tokens it received for tokens that another one of its project's terminals can accept. Then, it
/// pays that terminal with the tokens it got from the pool, forwarding the specified beneficiary to receive any tokens
/// or NFTs minted by that payment, as well as payment metadata and other arguments.
/// @dev To prevent excessive slippage, the user/client can specify a minimum quote and a pool to use in their payment's
/// metadata using the `JBMetadataResolver` format. If they don't, a quote is calculated for them based on the TWAP
/// oracle for the project's default pool for that token (set by the project's owner).
/// @custom:metadata-id-used quoteForSwap and permit2
/// @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
contract JBSwapTerminal is
    JBPermissioned,
    Ownable,
    ERC2771Context,
    IJBTerminal,
    IJBPermitTerminal,
    IJBSwapTerminal,
    IUniswapV3SwapCallback
{
    // A library that adds default safety checks to ERC20 functionality.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBSwapTerminal_CallerNotPool(address caller);
    error JBSwapTerminal_InvalidTwapWindow(uint256 window, uint256 minWindow, uint256 maxWindow);
    error JBSwapTerminal_SpecifiedSlippageExceeded(uint256 amount, uint256 minimum);
    error JBSwapTerminal_NoDefaultPoolDefined(uint256 projectId, address token);
    error JBSwapTerminal_NoLiquidity();
    error JBSwapTerminal_NoMsgValueAllowed(uint256 value);
    error JBSwapTerminal_NoObservationHistory();
    error JBSwapTerminal_PermitAllowanceNotEnough(uint256 amount, uint256 allowance);
    error JBSwapTerminal_TokenNotAccepted(uint256 projectId, address token);
    error JBSwapTerminal_UnexpectedCall(address caller);
    error JBSwapTerminal_WrongPool(address pool, address expectedPool);
    error JBSwapTerminal_AmountOverflow(uint256 amount);
    error JBSwapTerminal_ZeroToken();

    //*********************************************************************//
    // -------------------------- custom events -------------------------- //
    //*********************************************************************//

    event Permit2AllowanceFailed(address indexed token, address indexed owner, bytes reason);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The ID to store default values in.
    uint256 public constant override DEFAULT_PROJECT_ID = 0;

    /// @notice Projects cannot specify a TWAP window longer than this constant.
    /// @dev This serves to avoid excessively long TWAP windows that could lead to outdated pricing information and
    /// higher gas costs due to increased computational requirements.
    uint256 public constant override MAX_TWAP_WINDOW = 2 days;

    /// @notice Projects cannot specify a TWAP window shorter than this constant.
    /// @dev This serves to avoid extremely short TWAP windows that could be manipulated or subject to high volatility.
    uint256 public constant override MIN_TWAP_WINDOW = 2 minutes;

    /// @notice The denominator used when calculating TWAP slippage tolerance values.
    uint160 public constant override SLIPPAGE_DENOMINATOR = 10_000;

    /// @notice The uncertain slippage tolerance allowed.
    /// @dev This serves to avoid extremely low slippage tolerances that could result in failed swaps.
    uint256 public constant override UNCERTAIN_SLIPPAGE_TOLERANCE = 1050;

    /// @notice The minimum cardinality for a pool to be configured as a default pool.
    /// @dev The cardinality is automatically increased to this number when added as a default pool.
    uint16 public constant override MIN_DEFAULT_POOL_CARDINALITY = 10;

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The directory of terminals and controllers for `PROJECTS`.
    IJBDirectory public immutable DIRECTORY;

    /// @notice The factory to use for creating new pools
    /// @dev We rely on "a" factory, vanilla uniswap v3 or potential fork
    IUniswapV3Factory public immutable FACTORY;

    /// @notice The permit2 utility.
    IPermit2 public immutable PERMIT2;

    /// @notice Mints ERC-721s that represent project ownership and transfers.
    IJBProjects public immutable PROJECTS;

    /// @notice The token which flows out of this terminal (JBConstants.NATIVE_TOKEN for the chain native token)
    address public immutable TOKEN_OUT;

    /// @notice The ERC-20 wrapper for the native token.
    /// @dev "wETH" is used as a generic term throughout, but any native token wrapper can be used.
    IWETH9 public immutable WETH;

    //*********************************************************************//
    // --------------- internal immutable stored properties -------------- //
    //*********************************************************************//

    /// @notice A flag indicating if the token out is the chain native token (eth on mainnet for instance)
    /// @dev    If so, the token out should be unwrapped before being sent to the next terminal
    bool internal immutable _OUT_IS_NATIVE_TOKEN;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice A mapping which stores accounting contexts to use for a given project ID and token.
    /// @dev Accounting contexts are set up for a project ID and token when the project's owner uses
    /// `addDefaultPool(...)` for that token.
    /// @custom:param projectId The ID of the project to get the accounting context for.
    /// @custom:param token The address of the token to get the accounting context for.
    mapping(uint256 projectId => mapping(address token => JBAccountingContext)) internal _accountingContextFor;

    /// @notice A mapping which stores the default pool to use for a given project ID and token.
    /// @dev Default pools are set by the project owner with `addDefaultPool(...)`, the project 0 acts as a wildcard
    /// @dev Default pools are used when a payer doesn't specify a pool in their payment's metadata.
    /// @custom:param projectId The ID of the project to get the pool for.
    /// @custom:param tokenIn The address of the token to get the pool for.
    mapping(uint256 projectId => mapping(address tokenIn => IUniswapV3Pool)) internal _poolFor;

    /// @notice A mapping which stores the tokens that have an accounting context for a given project ID.
    /// @dev This is used to retrieve all the accounting contexts for a project ID.
    /// @custom:param projectId The ID of the project to get the tokens with a context for.
    mapping(uint256 projectId => address[]) internal _tokensWithAContext;

    /// @notice The twap window for each project's pools.
    /// @custom:param projectId The ID of the project to get the TWAP window for.
    /// @custom:param pool The pool to get the TWAP parameters for.
    mapping(uint256 projectId => mapping(IUniswapV3Pool pool => uint256 params)) internal _twapWindowOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory A contract storing directories of terminals and controllers for each project.
    /// @param permissions A contract storing permissions.
    /// @param projects A contract which mints ERC-721s that represent project ownership and transfers.
    /// @param permit2 A permit2 utility.
    /// @param owner The owner of the contract.
    /// @param weth A contract which wraps the native token.
    /// @param tokenOut The token which flows out of this terminal (JBConstants.NATIVE_TOKEN for the chain native token)
    /// @param factory A factory which creates Uniswap V3 pools.
    /// @param trustedForwarder The trusted forwarder for the contract.
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
        JBPermissioned(permissions)
        ERC2771Context(trustedForwarder)
        Ownable(owner)
    {
        if (tokenOut == address(0)) revert JBSwapTerminal_ZeroToken();

        DIRECTORY = directory;
        PROJECTS = projects;
        PERMIT2 = permit2;
        WETH = weth;
        TOKEN_OUT = tokenOut;
        _OUT_IS_NATIVE_TOKEN = tokenOut == JBConstants.NATIVE_TOKEN;
        FACTORY = factory;
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Get the accounting context for the specified project ID and token.
    /// @dev Accounting contexts are set up in `addDefaultPool(...)`.
    /// @param projectId The ID of the project to get the accounting context for.
    /// @param token The address of the token to get the accounting context for.
    /// @return context A `JBAccountingContext` containing the accounting context for the project ID and token.
    function accountingContextForTokenOf(
        uint256 projectId,
        address token
    )
        external
        view
        override
        returns (JBAccountingContext memory context)
    {
        // Get a reference to the context for the given projectId.
        context = _accountingContextFor[projectId][token];

        // If one wasn't found, check for a default.
        if (context.token == address(0)) {
            context = _accountingContextFor[DEFAULT_PROJECT_ID][token];
        }
    }

    /// @notice Return all the accounting contexts for a specified project ID.
    /// @dev    This includes both project-specific and generic accounting contexts, with the project-specific contexts
    ///         taking precedence.
    /// @param projectId The ID of the project to get the accounting contexts for.
    /// @return contexts An array of `JBAccountingContext` containing the accounting contexts for the project ID.
    function accountingContextsOf(uint256 projectId)
        external
        view
        override
        returns (JBAccountingContext[] memory contexts)
    {
        // Keep a reference to the tokens that have a known context for the project.
        address[] memory projectContextTokens = _tokensWithAContext[projectId];

        // Keep a reference to the default tokens that have a known context.
        address[] memory genericContextTokens = _tokensWithAContext[DEFAULT_PROJECT_ID];

        // Keep a reference to the number of project-specific contexts.
        uint256 numberOfProjectContextTokens = projectContextTokens.length;

        // Keep a reference to the number of generic contexts.
        uint256 numberOfGenericContextTokens = genericContextTokens.length;

        // Combine the two.
        contexts = new JBAccountingContext[](numberOfProjectContextTokens + numberOfGenericContextTokens);

        // include all the project specific contexts
        for (uint256 i; i < numberOfProjectContextTokens; i++) {
            contexts[i] = _accountingContextFor[projectId][projectContextTokens[i]];
        }

        // Keep a reference to the number of combined token contexts.
        uint256 numberOfCombinedContextTokens = numberOfProjectContextTokens;

        // add the generic contexts, iff they are not defined for the project (ie do not include duplicates)
        for (uint256 i; i < numberOfGenericContextTokens; i++) {
            // Skip if there is already a project context for the token.
            bool skip;

            for (uint256 j; j < numberOfProjectContextTokens; j++) {
                if (projectContextTokens[j] == genericContextTokens[i]) {
                    skip = true;
                    break;
                }
            }

            if (!skip) {
                contexts[numberOfCombinedContextTokens++] =
                    _accountingContextFor[DEFAULT_PROJECT_ID][genericContextTokens[i]];
            }
        }

        // Downsize the array to the actual length, if needed
        if (numberOfCombinedContextTokens < contexts.length) {
            assembly {
                mstore(contexts, numberOfCombinedContextTokens)
            }
        }

        return contexts;
    }

    /// @notice Empty implementation to satisfy the interface. This terminal has no surplus.
    function currentSurplusOf(
        uint256 projectId,
        JBAccountingContext[] memory accountingContexts,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        override
        returns (uint256)
    {}

    /// @notice Returns the default pool for a given project and token or, if a project has no default pool for the
    ///         token, the overall default pool for the token.
    /// @param projectId The ID of the project to retrieve the default pool for.
    /// @param tokenIn The address of the token to retrieve the default pool for.
    /// @return pool The default pool for the token, or the overall default pool for the token if the project has none.
    /// @return zeroForOne Whether `tokenIn` is token0 in the pool (true) or token1 (false).
    function getPoolFor(
        uint256 projectId,
        address tokenIn
    )
        external
        view
        returns (IUniswapV3Pool pool, bool zeroForOne)
    {
        // Get the pool for the project ID and token.
        pool = _poolFor[projectId][tokenIn];

        // If the pool is not set, get the pool for the default project ID and token.
        if (address(pool) == address(0)) {
            pool = _poolFor[DEFAULT_PROJECT_ID][tokenIn];
        }

        // Keep a reference to whether the token is being swapped into or out of the pool.
        zeroForOne = tokenIn < _normalizedTokenOut();
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Indicates if this contract adheres to the specified interface.
    /// @dev See {IERC165-supportsInterface}.
    /// @param interfaceId The ID of the interface to check for adherance to.
    /// @return A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IJBPermitTerminal).interfaceId
            || interfaceId == type(IERC165).interfaceId || interfaceId == type(IUniswapV3SwapCallback).interfaceId
            || interfaceId == type(IJBPermissioned).interfaceId || interfaceId == type(IJBSwapTerminal).interfaceId;
    }

    /// @notice Returns the default twap parameters for a given pool project.
    /// @param projectId The ID of the project to retrieve TWAP parameters for.
    /// @return twapWindow The period of time in the past to calculate the TWAP from.
    function twapWindowOf(uint256 projectId, IUniswapV3Pool pool) public view returns (uint256) {
        // Get a reference to the twap window for the provided project.
        uint256 twapWindow = _twapWindowOf[projectId][pool];

        // Check the default if needed.
        if (twapWindow == 0) {
            twapWindow = _twapWindowOf[DEFAULT_PROJECT_ID][pool];
        }

        return twapWindow;
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @dev `ERC-2771` specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
    }

    /// @notice The calldata. Preferred to use over `msg.data`.
    /// @return calldata The `msg.data` of this call.
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @notice The message's sender. Preferred to use over `msg.sender`.
    /// @return sender The address which sent this call.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }

    /// @notice Returns the token that flows out of this terminal, wrapped as an ERC-20 if needed.
    /// @dev If the token out is the chain native token (ETH on mainnet), wrapped ETH is returned
    /// @return The token that flows out of this terminal.
    function _normalizedTokenOut() internal view returns (address) {
        return _OUT_IS_NATIVE_TOKEN ? address(WETH) : TOKEN_OUT;
    }

    /// @notice Picks the pool and quote for the swap.
    /// @param metadata The metadata in which `quoteForSwap` context is provided.
    /// @param projectId The ID of the project for which the swap is being performed.
    /// @param normalizedTokenIn The address of the token being swapped, normalized to the wrapped native token.
    /// @param amount The amount of tokens to swap.
    /// @param normalizedTokenOut The address of the token to receive from the swap, normalized to the wrapped native
    /// token.
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
        returns (uint256 minAmountOut, IUniswapV3Pool pool)
    {
        // If there is no quote, check for this project's default pool for the token and get a quote based on
        // its TWAP.
        pool = _poolFor[projectId][normalizedTokenIn];

        // If this project doesn't have a default pool specified for this token, try using a generic one.
        if (address(pool) == address(0)) {
            pool = _poolFor[DEFAULT_PROJECT_ID][normalizedTokenIn];

            // If there's no default pool neither, revert.
            if (address(pool) == address(0)) {
                revert JBSwapTerminal_NoDefaultPoolDefined(projectId, normalizedTokenIn);
            }
        }

        // Check for a quote passed in by the user/client.
        (bool exists, bytes memory quote) =
            JBMetadataResolver.getDataFor({id: JBMetadataResolver.getId("quoteForSwap"), metadata: metadata});

        // If there's a quote, use it.
        if (exists) {
            // M-4 NOTE: The user-provided quote is accepted without a TWAP floor. This is by design:
            // - The quote comes from the payer (msg.sender) who is spending their own funds. A low minAmountOut
            //   only harms the payer themselves (via sandwich attacks), not the project.
            // - Frontends/aggregators typically fetch real-time quotes from Uniswap's Quoter contract, which are
            //   more accurate than TWAP. Enforcing a TWAP floor could cause legitimate swaps to revert if the
            //   TWAP is stale or has been manipulated upward.
            // - Protocol-internal flows (e.g., payouts via JBMultiTerminal._sendPayoutToSplit) do NOT include a
            //   quoteForSwap in metadata, so they always use the TWAP-based fallback below.
            // - This pattern is consistent with the JBBuybackHook's "quote" metadata and standard DEX routers.
            (minAmountOut) = abi.decode(quote, (uint256));
        } else {
            // Get a quote based on the pool's TWAP, including a default slippage maximum.
            uint256 twapWindow = twapWindowOf(projectId, pool);

            // Use the oldest observation if it's less than the twapWindow.
            uint32 oldestObservation = OracleLibrary.getOldestObservationSecondsAgo(address(pool));
            if (oldestObservation < twapWindow) twapWindow = oldestObservation;

            // Keep a reference to the TWAP tick.
            int24 arithmeticMeanTick;

            // Keep a reference to the liquidity.
            uint128 liquidity;

            // Revert when the pool lacks observation history — slot0 is flash-loan manipulable.
            if (oldestObservation == 0) revert JBSwapTerminal_NoObservationHistory();

            //slither-disable-next-line unused-return
            (arithmeticMeanTick, liquidity) =
                OracleLibrary.consult({pool: address(pool), secondsAgo: uint32(twapWindow)});

            // Revert when there's no liquidity — accepting zero output loses the user's funds.
            if (liquidity == 0) revert JBSwapTerminal_NoLiquidity();

            // Calculate slippage tolerance + quote in a scoped block to avoid stack-too-deep.
            {
                // Calculate the slippage tolerance using the continuous sigmoid formula.
                // Pool fee is converted from hundredths of a bip (Uniswap V3 format) to basis points.
                uint256 slippageTolerance = _getSlippageTolerance({
                    amountIn: amount,
                    liquidity: liquidity,
                    tokenOut: normalizedTokenOut,
                    tokenIn: normalizedTokenIn,
                    arithmeticMeanTick: arithmeticMeanTick,
                    poolFeeBps: uint256(pool.fee()) / 100
                });

                // If the slippage tolerance meets or exceeds the maximum, return an empty quote.
                if (slippageTolerance >= SLIPPAGE_DENOMINATOR) return (0, pool);

                // Get a quote based on this TWAP tick.
                if (amount > type(uint128).max) revert JBSwapTerminal_AmountOverflow(amount);
                minAmountOut = OracleLibrary.getQuoteAtTick({
                    tick: arithmeticMeanTick,
                    baseAmount: uint128(amount),
                    baseToken: normalizedTokenIn,
                    quoteToken: normalizedTokenOut
                });

                // Return the lowest acceptable return based on the TWAP and its parameters.
                minAmountOut -= (minAmountOut * slippageTolerance) / SLIPPAGE_DENOMINATOR;
            }
        }
    }

    /// @notice Get the slippage tolerance for a given amount in and liquidity.
    /// @dev Uses the continuous sigmoid formula from JBSwapLib for smoother behavior across all swap sizes.
    /// @param amountIn The amount in to get the slippage tolerance for.
    /// @param liquidity The liquidity to get the slippage tolerance for.
    /// @param tokenOut The outgoing token to get the slippage tolerance for.
    /// @param tokenIn The incoming token to get the slippage tolerance for.
    /// @param arithmeticMeanTick The arithmetic mean tick to get the slippage tolerance for.
    /// @param poolFeeBps The pool fee in basis points (e.g., 30 for 0.3%).
    /// @return slippageTolerance The slippage tolerance for the given amount in and liquidity.
    function _getSlippageTolerance(
        uint256 amountIn,
        uint128 liquidity,
        address tokenOut,
        address tokenIn,
        int24 arithmeticMeanTick,
        uint256 poolFeeBps
    )
        internal
        pure
        returns (uint256)
    {
        // Direction: is tokenIn token0?
        (address token0,) = tokenOut < tokenIn ? (tokenOut, tokenIn) : (tokenIn, tokenOut);
        bool zeroForOne = tokenIn == token0;

        // sqrtP in Q96 from the TWAP tick
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);

        // If the sqrtP is 0, there's no valid price so we'll return the maximum slippage tolerance.
        if (sqrtP == 0) return SLIPPAGE_DENOMINATOR;

        // Calculate impact using 1e18 precision (prevents rounding to 0 for small swaps).
        uint256 impact = JBSwapLib.calculateImpact(amountIn, liquidity, sqrtP, zeroForOne);

        // Use the continuous sigmoid formula with pool fee awareness.
        return JBSwapLib.getSlippageTolerance(impact, poolFeeBps);
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Empty implementation to satisfy the interface. Accounting contexts are set in `addDefaultPool(...)`.
    function addAccountingContextsFor(
        uint256 projectId,
        JBAccountingContext[] calldata accountingContexts
    )
        external
        override
    {}

    /// @notice Set a project's default pool and accounting context for the specified token. Only the project's owner,
    /// an address with `ADD_SWAP_TERMINAL_POOL` permission from the owner or the terminal owner can call this function.
    /// @dev The pool should have been deployed by the factory associated to this contract. We don't rely on create2
    /// address
    /// as this terminal might be used on other chain, where the factory bytecode might differ or the main dex be a
    /// fork.
    /// @param projectId The ID of the project to set the default pool for. The project 0 acts as a catch-all, where
    /// non-set pools are defaulted to.
    /// @param token The address of the token to set the default pool for.
    /// @param pool The Uniswap V3 pool to set as the default for the specified token.
    function addDefaultPool(uint256 projectId, address token, IUniswapV3Pool pool) external override {
        // Only the project owner can set the default pool for a token, and only project owners can set the pool for
        // their project.
        projectId == DEFAULT_PROJECT_ID
            ? _checkOwner()
            : _requirePermissionFrom({
                account: PROJECTS.ownerOf(projectId),
                projectId: projectId,
                permissionId: JBPermissionIds.ADD_SWAP_TERMINAL_POOL
            });

        // Keep a reference to the normalized token out, which wraps the native token if needed.
        address normalizedTokenOut = _normalizedTokenOut();

        // Keep a reference to the normalized token, which wraps the native token if needed.
        address normalizedTokenIn = token == JBConstants.NATIVE_TOKEN ? address(WETH) : token;

        // Keep a reference to whether the token is being swapped into or out of the pool.
        bool zeroForOne = normalizedTokenIn < normalizedTokenOut;

        // Check if the pool has beed deployed by the factory
        // Factory stores both directions, future proofing
        if (
            FACTORY.getPool({
                tokenA: zeroForOne ? normalizedTokenIn : normalizedTokenOut,
                tokenB: zeroForOne ? normalizedTokenOut : normalizedTokenIn,
                fee: pool.fee()
            }) != address(pool)
        ) {
            revert JBSwapTerminal_WrongPool(
                address(pool),
                FACTORY.getPool({
                    tokenA: zeroForOne ? normalizedTokenIn : normalizedTokenOut,
                    tokenB: zeroForOne ? normalizedTokenOut : normalizedTokenIn,
                    fee: pool.fee()
                })
            );
        }

        // Proactively set up TWAP history. If the cardinality is already higher this is a no-op.
        // _getQuote also reverts if the pool lacks sufficient observations as a safety net.
        pool.increaseObservationCardinalityNext(MIN_DEFAULT_POOL_CARDINALITY);

        // Store the token as having an accounting context.
        if (_poolFor[projectId][normalizedTokenIn] == IUniswapV3Pool(address(0))) {
            _tokensWithAContext[projectId].push(token);
        }

        // Update the project's pool for the token.
        _poolFor[projectId][normalizedTokenIn] = pool;

        // Update the project's accounting context for the token.
        _accountingContextFor[projectId][token] = JBAccountingContext({
            token: token,
            decimals: token == JBConstants.NATIVE_TOKEN ? 18 : IERC20Metadata(token).decimals(),
            currency: uint32(uint160(token))
        });
    }

    /// @notice Accepts funds for a given project, swaps them if necessary, and adds them to the project's balance in
    /// the specified terminal.
    /// @dev This function handles the token in transfer, potentially swaps the tokens to the desired output token, and
    /// then adds the swapped tokens to the project's balance in the specified terminal.
    /// @param projectId The ID of the project for which funds are being accepted and added to its balance.
    /// @param token The address of the token being paid in.
    /// @param amount The amount of tokens being paid in.
    /// @param shouldReturnHeldFees A boolean to indicate whether held fees should be returned.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes in `JBMetadataResolver`'s format which can contain additional data for the swap and adding
    /// to balance.
    function addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool shouldReturnHeldFees,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable
        override
    {
        // Get a reference to the project's primary terminal for the destination token that is being swapped into.
        IJBTerminal terminal = DIRECTORY.primaryTerminalOf({projectId: projectId, token: TOKEN_OUT});

        // Revert if the project does not have a primary terminal for the destination token.
        if (address(terminal) == address(0)) revert JBSwapTerminal_TokenNotAccepted(projectId, TOKEN_OUT);

        // Execute the swap.
        uint256 receivedFromSwap = _handleTokenTransfersAndSwap({
            projectId: projectId,
            tokenIn: token,
            amount: _acceptFundsFor({token: token, amount: amount, metadata: metadata}),
            metadata: metadata
        });

        // Trigger any pre-transfer logic.
        uint256 payValue = _beforeTransferFor({to: address(terminal), token: TOKEN_OUT, amount: receivedFromSwap});

        // Add to the primary terminal's balance in the resulting token, forwarding along the beneficiary and other
        // arguments.
        terminal.addToBalanceOf{value: payValue}({
            projectId: projectId,
            token: TOKEN_OUT,
            amount: receivedFromSwap,
            shouldReturnHeldFees: shouldReturnHeldFees,
            memo: memo,
            metadata: metadata
        });
    }

    /// @notice Set the specified project's rules for calculating a quote based on the TWAP. Only the project's owner or
    /// an address with `MODIFY_TWAP_PARAMS` permission from the owner  or the terminal owner can call this function.
    /// @param projectId The ID of the project to set the TWAP-based quote rules for.
    /// @param twapWindow The period of time over which the TWAP is calculated, in seconds.
    /// of `SLIPPAGE_DENOMINATOR`).
    function addTwapParamsFor(uint256 projectId, IUniswapV3Pool pool, uint256 twapWindow) external override {
        // Only the project owner can set the default twap params for a pool, and only project owners can set the
        // params for their projects.
        projectId == DEFAULT_PROJECT_ID
            ? _checkOwner()
            : _requirePermissionFrom({
                account: PROJECTS.ownerOf(projectId),
                projectId: projectId,
                permissionId: JBPermissionIds.ADD_SWAP_TERMINAL_TWAP_PARAMS
            });

        // Make sure the specified window is within reasonable bounds.
        if (twapWindow < MIN_TWAP_WINDOW || twapWindow > MAX_TWAP_WINDOW) {
            revert JBSwapTerminal_InvalidTwapWindow(twapWindow, MIN_TWAP_WINDOW, MAX_TWAP_WINDOW);
        }

        // Set the TWAP params for the project.
        _twapWindowOf[projectId][pool] = twapWindow;
    }

    /// @notice Empty implementation to satisfy the interface.
    function migrateBalanceOf(
        uint256 projectId,
        address token,
        IJBTerminal to
    )
        external
        override
        returns (uint256 balance)
    {}

    /// @notice Pay a project by swapping the incoming tokens for tokens that one of the project's other terminals
    /// accepts, passing along the funds received from the swap and the specified parameters.
    /// @param projectId The ID of the project being paid.
    /// @param token The address of the token being paid in.
    /// @param amount The amount of tokens being paid in, as a fixed point number with the same amount of decimals as
    /// the `token`. If `token` is the native token, `amount` is ignored and `msg.value` is used in its place.
    /// @param beneficiary The beneficiary address to pass along to the other terminal. If the other terminal mints
    /// tokens, for example, they will be minted for this address.
    /// @param minReturnedTokens The minimum number of project tokens expected in return, as a fixed point number with
    /// the same number of decimals as the other terminal. This value will be passed along to the other terminal.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes in `JBMetadataResolver`'s format which can contain a quote from the user/client. The quote
    /// should contain a minimum amount of tokens to receive from the swap and the pool to use. This metadata is also
    /// passed to the other terminal's emitted event, as well as its data hook and pay hook if applicable.
    /// @return The number of tokens received from the swap, as a fixed point number with the same amount of decimals as
    /// that token.
    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable
        virtual
        override
        returns (uint256)
    {
        // Get a reference to the project's primary terminal for the destination token that is being swapped into.
        IJBTerminal terminal = DIRECTORY.primaryTerminalOf({projectId: projectId, token: TOKEN_OUT});

        // Revert if the project does not have a primary terminal for the destination token.
        if (address(terminal) == address(0)) revert JBSwapTerminal_TokenNotAccepted(projectId, TOKEN_OUT);

        // Execute the swap.
        uint256 receivedFromSwap = _handleTokenTransfersAndSwap({
            projectId: projectId,
            tokenIn: token,
            amount: _acceptFundsFor({token: token, amount: amount, metadata: metadata}),
            metadata: metadata
        });

        // Trigger any pre-transfer logic.
        // Keep a reference to the amount that'll be paid as a `msg.value`.
        uint256 payValue = _beforeTransferFor({to: address(terminal), token: TOKEN_OUT, amount: receivedFromSwap});

        // Pay the primary terminal in the resulting token, forwarding along the beneficiary and other arguments.
        return terminal.pay{value: payValue}({
            projectId: projectId,
            token: TOKEN_OUT,
            amount: receivedFromSwap,
            beneficiary: beneficiary,
            minReturnedTokens: minReturnedTokens,
            memo: memo,
            metadata: metadata
        });
    }

    /// @notice The Uniswap v3 pool callback where the token transfer is expected to happen.
    /// @dev Only an uniswap v3 pool can call this function
    /// @param amount0Delta The amount of token 0 being used for the swap.
    /// @param amount1Delta The amount of token 1 being used for the swap.
    /// @param data Data passed in by the swap operation.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        // Unpack the data from the original swap config (forwarded through `_swap(...)`).
        (uint256 projectId, address tokenIn) = abi.decode(data, (uint256, address));

        // Keep a reference to the normalized token, wrapping the native token if needed.
        address normalizedTokenIn = tokenIn == JBConstants.NATIVE_TOKEN ? address(WETH) : tokenIn;

        // Keep a reference to the pool that'll be used to perform the swap.
        IUniswapV3Pool storedPool = _poolFor[projectId][normalizedTokenIn];

        // If there's no pool, look for a default pool.
        if (address(storedPool) == address(0)) storedPool = _poolFor[DEFAULT_PROJECT_ID][normalizedTokenIn];

        // Make sure the address making this call is the expected pool.
        if (msg.sender != address(storedPool)) revert JBSwapTerminal_CallerNotPool(msg.sender);

        // Keep a reference to the amount of tokens that should be sent to fulfill the swap (the positive delta).
        uint256 amountToSendToPool = amount0Delta < 0 ? uint256(amount1Delta) : uint256(amount0Delta);

        // Wrap native tokens if needed.
        if (tokenIn == JBConstants.NATIVE_TOKEN) WETH.deposit{value: amountToSendToPool}();

        // Transfer the tokens being swapped to the pool.
        // This terminal should NEVER keep a token balance.
        IERC20(normalizedTokenIn).safeTransfer(msg.sender, amountToSendToPool);
    }

    //*********************************************************************//
    // ---------------------------- receive  ----------------------------- //
    //*********************************************************************//

    /// @notice Fallback to prevent native tokens being sent to this terminal.
    /// @dev Native tokens should only be sent to this terminal when being unwrapped from a swap.
    receive() external payable {
        if (msg.sender != address(WETH)) revert JBSwapTerminal_UnexpectedCall(msg.sender);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Accepts a token being paid in.
    /// @param token The address of the token being paid in.
    /// @param amount The amount of tokens being paid in.
    /// @param metadata The metadata in which `permit2` context is provided.
    /// @return amount The amount of tokens that have been accepted.
    function _acceptFundsFor(address token, uint256 amount, bytes calldata metadata) internal returns (uint256) {
        // If native tokens are being paid in, return the `msg.value`.
        if (token == JBConstants.NATIVE_TOKEN) return msg.value;

        // Otherwise, the `msg.value` should be 0.
        if (msg.value != 0) revert JBSwapTerminal_NoMsgValueAllowed(msg.value);

        // Unpack the `JBSingleAllowance` to use given by the frontend.
        (bool exists, bytes memory parsedMetadata) =
            JBMetadataResolver.getDataFor({id: JBMetadataResolver.getId("permit2"), metadata: metadata});

        // If the metadata contained permit data, use it to set the allowance.
        if (exists) {
            // Keep a reference to the allowance context parsed from the metadata.
            (JBSingleAllowance memory allowance) = abi.decode(parsedMetadata, (JBSingleAllowance));

            // Make sure the permit allowance is enough for this payment. If not, revert early.
            if (amount > allowance.amount) {
                revert JBSwapTerminal_PermitAllowanceNotEnough(amount, allowance.amount);
            }

            // Keep a reference to the permit rules.
            IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
                details: IAllowanceTransfer.PermitDetails({
                    token: token,
                    amount: allowance.amount,
                    expiration: allowance.expiration,
                    nonce: allowance.nonce
                }),
                spender: address(this),
                sigDeadline: allowance.sigDeadline
            });

            try PERMIT2.permit({owner: _msgSender(), permitSingle: permitSingle, signature: allowance.signature}) {}
                catch (bytes memory reason) {
                    emit Permit2AllowanceFailed(token, _msgSender(), reason);
                }
        }

        // Transfer the tokens from the `_msgSender()` to this terminal.
        _transferFrom({from: _msgSender(), to: payable(address(this)), token: token, amount: amount});

        // Return the amount transferred. Fee-on-transfer tokens are not supported by the swap terminal.
        return amount;
    }

    /// @notice Logic to be triggered before transferring tokens from this terminal.
    /// @param to The address to transfer tokens to.
    /// @param token The token being transfered.
    /// @param amount The amount of tokens to transfer, as a fixed point number with the same number of decimals as the
    /// token.
    /// @return payValue The amount that'll be paid as a `msg.value`.
    function _beforeTransferFor(address to, address token, uint256 amount) internal virtual returns (uint256) {
        // If the token is the native token, return early.
        if (_OUT_IS_NATIVE_TOKEN) return amount;

        // Otherwise, set the appropriate allowance for the recipient.
        IERC20(token).safeIncreaseAllowance(to, amount);

        return 0;
    }

    /// @notice Handles token transfers and swaps for a given project.
    /// @dev This function is responsible for transferring tokens from the sender to this terminal and performing a
    /// swap.
    /// @param projectId The ID of the project for which tokens are being transferred and possibly swapped.
    /// @param tokenIn The address of the token coming to this terminal.
    /// @param metadata Additional data to be used in the swap.
    /// @return amountToSend The amount of tokens to send after the swap, to the next terminal
    function _handleTokenTransfersAndSwap(
        uint256 projectId,
        address tokenIn,
        uint256 amount,
        bytes calldata metadata
    )
        internal
        returns (uint256)
    {
        // Keep a reference to the normalized token, which wraps the native token if needed.
        address normalizedTokenIn = tokenIn == JBConstants.NATIVE_TOKEN ? address(WETH) : tokenIn;

        // Keep a reference to the normalized token out, which wraps the native token if needed.
        address normalizedTokenOut = _normalizedTokenOut();

        // If the token in is the same as the token out, don't swap, just call the next terminal
        if ((tokenIn == JBConstants.NATIVE_TOKEN && _OUT_IS_NATIVE_TOKEN) || (normalizedTokenIn == normalizedTokenOut))
        {
            return amount;
        }

        // Get the quote that should be used for the swap, and the pool where the swap will take place.
        (uint256 minAmountOut, IUniswapV3Pool pool) = _pickPoolAndQuote({
            metadata: metadata,
            projectId: projectId,
            normalizedTokenIn: normalizedTokenIn,
            amount: amount,
            normalizedTokenOut: normalizedTokenOut
        });

        // Swap if needed. The callback will ensure that we're within the intended slippage tolerance.
        uint256 amountToSend = _swap({
            tokenIn: tokenIn,
            amountIn: amount,
            minAmountOut: minAmountOut,
            zeroForOne: normalizedTokenIn < normalizedTokenOut,
            projectId: projectId,
            pool: pool
        });

        // Send back any leftover tokens to the payer
        uint256 leftover = IERC20(normalizedTokenIn).balanceOf(address(this));

        if (leftover != 0) {
            // If the token in is the native token, unwrap it from the WETH contract and send it to the payer.
            if (tokenIn == JBConstants.NATIVE_TOKEN) {
                WETH.withdraw(leftover);
            }

            _transferFrom({from: address(this), to: payable(_msgSender()), token: tokenIn, amount: leftover});
        }

        return amountToSend;
    }

    /// @notice Swaps tokens based on the provided swap configuration.
    /// @param tokenIn The address of the token being swapped.
    /// @param amountIn The amount of tokens to swap.
    /// @param minAmountOut The minimum amount of tokens to receive from the swap.
    /// @param zeroForOne The order of the token values being passed into the swap.
    /// @param projectId The ID of the project for which the swap is being performed.
    /// @param pool The pool to perform the swap in.
    /// @return amountOut The amount of tokens received from the swap.
    function _swap(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        bool zeroForOne,
        uint256 projectId,
        IUniswapV3Pool pool
    )
        internal
        returns (uint256 amountOut)
    {
        // Perform the swap in the specified pool, passing in parameters from the swap configuration.
        (int256 amount0, int256 amount1) = pool.swap({
            recipient: address(this), // Send output tokens to this terminal.
            zeroForOne: zeroForOne, // The direction of the swap.
            amountSpecified: int256(amountIn), // The amount of input tokens to swap.
            // Dynamic sqrtPriceLimit computed from minimum acceptable output (MEV protection).
            sqrtPriceLimitX96: JBSwapLib.sqrtPriceLimitFromAmounts(amountIn, minAmountOut, zeroForOne),
            data: abi.encode(projectId, tokenIn) // Additional data forwarded to the callback.
        });

        // Calculate the amount of tokens received from the swap.
        amountOut = uint256(-(zeroForOne ? amount1 : amount0));

        // Ensure the amount received is not less than the minimum amount specified in the swap configuration.
        if (amountOut < minAmountOut) revert JBSwapTerminal_SpecifiedSlippageExceeded(amountOut, minAmountOut);

        // If the output token is a native token, unwrap it from its wrapped form.
        if (_OUT_IS_NATIVE_TOKEN) WETH.withdraw(amountOut);
    }

    /// @notice Transfers tokens.
    /// @param from The address to transfer tokens from.
    /// @param to The address to transfer tokens to.
    /// @param token The address of the token being transfered.
    /// @param amount The amount of tokens to transfer, as a fixed point number with the same number of decimals as the
    /// token.
    function _transferFrom(address from, address payable to, address token, uint256 amount) internal virtual {
        if (from == address(this)) {
            // If the token is native token, assume the `sendValue` standard.
            if (token == JBConstants.NATIVE_TOKEN) return Address.sendValue(to, amount);

            // If the transfer is from this terminal, use `safeTransfer`.
            return IERC20(token).safeTransfer(to, amount);
        }

        // If there's sufficient approval, transfer normally.
        if (IERC20(token).allowance({owner: address(from), spender: address(this)}) >= amount) {
            return IERC20(token).safeTransferFrom(from, to, amount);
        }

        // Otherwise, attempt to use the `permit2` method.
        PERMIT2.transferFrom(from, to, uint160(amount), token);
    }
}
