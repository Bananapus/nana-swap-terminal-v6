// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {PoolTestHelper} from "@exhausted-pigeon/uniswap-v3-foundry-pool/src/PoolTestHelper.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";

import "../src/JBSwapTerminal.sol";
import {JBSwapLib} from "../src/libraries/JBSwapLib.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import "forge-std/Test.sol";

/// @notice Minimal mock ERC20 with public mint.
contract MockTokenOSS is ERC20 {
    uint8 internal _dec;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _dec = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal mock WETH that wraps/unwraps ETH and supports ERC20 operations.
contract MockWETHOSS is MockTokenOSS {
    constructor() MockTokenOSS("Wrapped Ether", "WETH", 18) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// @title OrderSizeStress
/// @notice Tests different order magnitudes across varying pool depths.
///         3 depths x 5 sizes = 15 scenarios total, split across 3 test functions.
contract OrderSizeStress is PoolTestHelper {
    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    MockTokenOSS internal tokenA;
    MockTokenOSS internal tokenB;

    address internal token0;
    address internal token1;

    IUniswapV3Pool internal pool;
    JBSwapTerminal internal swapTerminal;

    IJBDirectory internal mockDirectory;
    IJBPermissions internal mockPermissions;
    IJBProjects internal mockProjects;
    IPermit2 internal mockPermit2;
    IUniswapV3Factory internal mockFactory;
    address internal nextTerminal;

    MockWETHOSS internal weth;

    address internal caller;
    address internal beneficiary;
    address internal projectOwner;

    uint256 internal constant PROJECT_ID = 42;
    uint24 internal constant POOL_FEE = 3000; // 0.3%
    uint160 internal constant SQRT_PRICE_1_TO_1 = 79_228_162_514_264_337_593_543_950_336; // 2^96

    // -----------------------------------------------------------------------
    // setUp — deploys tokens, mocks, and terminal (but NOT the pool)
    // -----------------------------------------------------------------------

    function setUp() public {
        // 1. Deploy tokens and sort so token0 < token1.
        weth = new MockWETHOSS();
        tokenA = new MockTokenOSS("Token A", "TKA", 18);
        tokenB = new MockTokenOSS("Token B", "TKB", 18);
        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        token0 = address(tokenA);
        token1 = address(tokenB);

        // 2. Deploy mock JB contracts.
        mockDirectory = IJBDirectory(makeAddr("directory"));
        vm.etch(address(mockDirectory), hex"00");
        mockPermissions = IJBPermissions(makeAddr("permissions"));
        vm.etch(address(mockPermissions), hex"00");
        mockProjects = IJBProjects(makeAddr("projects"));
        vm.etch(address(mockProjects), hex"00");
        mockPermit2 = IPermit2(makeAddr("permit2"));
        vm.etch(address(mockPermit2), hex"00");
        mockFactory = IUniswapV3Factory(makeAddr("factory"));
        vm.etch(address(mockFactory), hex"00");
        nextTerminal = makeAddr("nextTerminal");
        vm.etch(nextTerminal, hex"00");

        caller = makeAddr("caller");
        beneficiary = makeAddr("beneficiary");
        projectOwner = makeAddr("projectOwner");

        // 3. Deploy the real JBSwapTerminal. tokenOut = tokenB.
        swapTerminal = new JBSwapTerminal(
            mockDirectory,
            mockPermissions,
            mockProjects,
            mockPermit2,
            projectOwner,
            IWETH9(address(weth)),
            address(tokenB),
            mockFactory,
            address(0)
        );

        // 4. Mock projects.ownerOf.
        vm.mockCall(address(mockProjects), abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(projectOwner));

        // 5. Mock the directory: primaryTerminalOf(PROJECT_ID, tokenB) => nextTerminal.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(tokenB))),
            abi.encode(nextTerminal)
        );

        // 6. Mock the next terminal's pay and addToBalanceOf to succeed.
        vm.mockCall(nextTerminal, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(1)));
        vm.mockCall(nextTerminal, abi.encodeWithSelector(IJBTerminal.addToBalanceOf.selector), abi.encode());

        // 7. Create the pool, seed with minimal liquidity — tests will add more.
        pool = IUniswapV3Pool(address(createPool(token0, token1, POOL_FEE, SQRT_PRICE_1_TO_1, Chains.Other)));

        // 8. Mock the factory's getPool.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (token0, token1, POOL_FEE)),
            abi.encode(address(pool))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (token1, token0, POOL_FEE)),
            abi.encode(address(pool))
        );

        // 9. Configure the default pool for this project.
        vm.prank(projectOwner);
        swapTerminal.addDefaultPool(PROJECT_ID, address(tokenA), pool);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// @notice Build JB metadata containing a `quoteForSwap` entry.
    function _quoteMetadata(uint256 minAmountOut) internal view returns (bytes memory) {
        bytes4 metadataId = JBMetadataResolver.getId("quoteForSwap", address(swapTerminal));
        return JBMetadataResolver.addToMetadata("", metadataId, abi.encode(minAmountOut));
    }

    /// @notice Seed the pool with `depth` liquidity (full-range).
    function _seedLiquidity(uint256 depth) internal {
        tokenA.mint(address(this), depth);
        tokenB.mint(address(this), depth);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        addLiquidityFullRange(address(pool), depth, depth);
    }

    /// @notice Get a rough quote by performing a real swap, then reverting.
    function _quoteAmountOut(uint256 amountIn) internal returns (uint256 amountOut) {
        uint256 snap = vm.snapshot();

        tokenA.mint(address(this), amountIn);
        uint256 tokenBBefore = tokenB.balanceOf(address(this));
        this.swap(address(pool), address(tokenA), amountIn);
        amountOut = tokenB.balanceOf(address(this)) - tokenBBefore;

        vm.revertTo(snap);
    }

    /// @notice Execute a swap of `size` through the terminal.
    /// @return output The amount of tokenB received, or 0 if reverted.
    /// @return reverted Whether the swap reverted.
    function _executeSwap(uint256 size) internal returns (uint256 output, bool reverted) {
        // Get a quote first — use try/catch since very large swaps may fail even quoting.
        uint256 minAmountOut;
        try this._quoteAmountOutExternal(size) returns (uint256 quoted) {
            minAmountOut = quoted / 2; // 50% of expected — very generous.
        } catch {
            minAmountOut = 0;
        }

        // Mint tokenA to caller and approve.
        tokenA.mint(caller, size);
        vm.startPrank(caller);
        tokenA.approve(address(swapTerminal), size);

        bytes memory metadata = _quoteMetadata(minAmountOut);

        // Execute the pay — catch reverts.
        try swapTerminal.pay{value: 0}({
            projectId: PROJECT_ID,
            token: address(tokenA),
            amount: size,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: metadata
        }) {
            output = tokenB.balanceOf(address(swapTerminal));
            reverted = false;
        } catch {
            reverted = true;
            output = 0;
        }
        vm.stopPrank();
    }

    /// @dev External wrapper so we can try/catch it.
    function _quoteAmountOutExternal(uint256 amountIn) external returns (uint256) {
        return _quoteAmountOut(amountIn);
    }

    /// @notice Run 5 order sizes against the pool. Validates outputs are sensible.
    function _runSizesForDepth(uint256 depth, string memory depthLabel) internal {
        uint256[5] memory sizes = [uint256(0.001e18), 0.1e18, 1e18, 10e18, 100e18];
        string[5] memory sizeLabels = ["0.001", "0.1", "1", "10", "100"];

        for (uint256 s; s < 5; s++) {
            // Snapshot so each swap starts from clean pool state.
            uint256 snap = vm.snapshot();

            (uint256 output, bool reverted) = _executeSwap(sizes[s]);

            if (sizes[s] > depth) {
                // When order size exceeds pool depth, a revert or very low output is acceptable.
                if (!reverted) {
                    assertGt(
                        output,
                        0,
                        string.concat(
                            "depth=", depthLabel, " size=", sizeLabels[s], ": output should be > 0 if swap succeeded"
                        )
                    );
                }
                // Revert is expected for oversized orders — pass silently.
            } else {
                // When order size <= pool depth, the swap should succeed.
                assertFalse(
                    reverted, string.concat("depth=", depthLabel, " size=", sizeLabels[s], ": should not revert")
                );
                assertGt(
                    output, 0, string.concat("depth=", depthLabel, " size=", sizeLabels[s], ": output should be > 0")
                );
                // For a 1:1 pool, output should be at least 10% of input for sub-depth orders.
                assertGe(
                    output,
                    sizes[s] / 10,
                    string.concat("depth=", depthLabel, " size=", sizeLabels[s], ": output should be >= 10% of input")
                );
            }

            // Restore pool state for next size.
            vm.revertTo(snap);
        }
    }

    // -----------------------------------------------------------------------
    // Tests: one per depth (thin, medium, deep) x 5 sizes each = 15 scenarios
    // -----------------------------------------------------------------------

    /// @notice Thin pool (10 ETH depth) x 5 order sizes.
    function test_thinPoolDepth() public {
        _seedLiquidity(10e18);
        _runSizesForDepth(10e18, "thin(10)");
    }

    /// @notice Medium pool (1K ETH depth) x 5 order sizes.
    function test_mediumPoolDepth() public {
        _seedLiquidity(1000e18);
        _runSizesForDepth(1000e18, "medium(1K)");
    }

    /// @notice Deep pool (100K ETH depth) x 5 order sizes.
    function test_deepPoolDepth() public {
        _seedLiquidity(100_000e18);
        _runSizesForDepth(100_000e18, "deep(100K)");
    }
}
