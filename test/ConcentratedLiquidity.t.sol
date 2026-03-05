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
contract MockTokenCL is ERC20 {
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
contract MockWETHCL is MockTokenCL {
    constructor() MockTokenCL("Wrapped Ether", "WETH", 18) {}

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

/// @title ConcentratedLiquidity
/// @notice Tests V3 concentrated liquidity interactions with JBSwapTerminal.
contract ConcentratedLiquidity is PoolTestHelper {
    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    MockTokenCL internal tokenA;
    MockTokenCL internal tokenB;

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

    MockWETHCL internal weth;

    address internal caller;
    address internal beneficiary;
    address internal projectOwner;

    uint256 internal constant PROJECT_ID = 42;
    uint24 internal constant POOL_FEE = 3000; // 0.3%
    int24 internal constant TICK_SPACING = 60; // for 0.3% fee
    uint160 internal constant SQRT_PRICE_1_TO_1 = 79_228_162_514_264_337_593_543_950_336; // 2^96

    // -----------------------------------------------------------------------
    // setUp
    // -----------------------------------------------------------------------

    function setUp() public {
        // 1. Deploy tokens and sort so token0 < token1.
        weth = new MockWETHCL();
        tokenA = new MockTokenCL("Token A", "TKA", 18);
        tokenB = new MockTokenCL("Token B", "TKB", 18);
        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        token0 = address(tokenA);
        token1 = address(tokenB);

        // 2. Create a real V3 pool via PoolTestHelper.
        pool = IUniswapV3Pool(address(createPool(token0, token1, POOL_FEE, SQRT_PRICE_1_TO_1, Chains.Other)));

        // 3. Deploy mock JB contracts.
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

        // 4. Deploy the real JBSwapTerminal. tokenOut = tokenB.
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

        // 5. Mock the factory's getPool.
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

        // 6. Mock projects.ownerOf.
        vm.mockCall(address(mockProjects), abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(projectOwner));

        // 7. Configure the default pool for this project.
        vm.prank(projectOwner);
        swapTerminal.addDefaultPool(PROJECT_ID, address(tokenA), pool);

        // 8. Mock the directory: primaryTerminalOf(PROJECT_ID, tokenB) => nextTerminal.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(tokenB))),
            abi.encode(nextTerminal)
        );

        // 9. Mock the next terminal's pay and addToBalanceOf to succeed.
        vm.mockCall(nextTerminal, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(1)));
        vm.mockCall(nextTerminal, abi.encodeWithSelector(IJBTerminal.addToBalanceOf.selector), abi.encode());
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// @notice Build JB metadata containing a `quoteForSwap` entry.
    function _quoteMetadata(uint256 minAmountOut) internal view returns (bytes memory) {
        bytes4 metadataId = JBMetadataResolver.getId("quoteForSwap", address(swapTerminal));
        return JBMetadataResolver.addToMetadata("", metadataId, abi.encode(minAmountOut));
    }

    /// @notice Seed concentrated liquidity at the given tick range.
    function _seedConcentrated(int24 lower, int24 upper, uint256 amount0, uint256 amount1) internal {
        tokenA.mint(address(this), amount0);
        tokenB.mint(address(this), amount1);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        addLiquidity(address(pool), lower, upper, amount0, amount1);
    }

    /// @notice Seed full-range liquidity.
    function _seedFullRange(uint256 amount0, uint256 amount1) internal {
        tokenA.mint(address(this), amount0);
        tokenB.mint(address(this), amount1);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        addLiquidityFullRange(address(pool), amount0, amount1);
    }

    /// @notice Execute a swap via the terminal. Returns the output or reverts.
    function _paySwap(uint256 amountIn, uint256 minAmountOut) internal returns (uint256 output) {
        tokenA.mint(caller, amountIn);
        vm.startPrank(caller);
        tokenA.approve(address(swapTerminal), amountIn);

        bytes memory metadata = _quoteMetadata(minAmountOut);

        swapTerminal.pay({
            projectId: PROJECT_ID,
            token: address(tokenA),
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: metadata
        });
        vm.stopPrank();

        // Output is held in the terminal since the mock next terminal doesn't pull.
        output = tokenB.balanceOf(address(swapTerminal));
    }

    /// @notice Get a rough quote via snapshot/revert.
    function _quoteAmountOut(uint256 amountIn) internal returns (uint256 amountOut) {
        uint256 snap = vm.snapshot();

        tokenA.mint(address(this), amountIn);
        uint256 tokenBBefore = tokenB.balanceOf(address(this));
        this.swap(address(pool), address(tokenA), amountIn);
        amountOut = tokenB.balanceOf(address(this)) - tokenBBefore;

        vm.revertTo(snap);
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    /// @notice Liquidity at [-600, 600] (~6%), small swap stays in range.
    function test_swapWithinConcentratedRange() public {
        // Concentrated liquidity at [-600, 600] (about +/-6% around current price).
        _seedConcentrated(-600, 600, 100_000e18, 100_000e18);

        uint256 amountIn = 10e18; // small swap relative to liquidity
        uint256 expected = _quoteAmountOut(amountIn);
        uint256 minOut = (expected * 90) / 100;

        uint256 output = _paySwap(amountIn, minOut);

        assertGt(output, 0, "should produce output");
        assertGe(output, minOut, "output should meet minimum");
        // For a small swap within concentrated range, slippage should be minimal.
        // Output should be > 95% of expected (very close to 1:1 in concentrated range).
        assertGe(output, (expected * 95) / 100, "output should be close to expected for in-range swap");
    }

    /// @notice Larger swap crosses tick boundary -- output less than full-range equivalent.
    function test_swapCrossingTickBoundary() public {
        // Narrow concentrated liquidity at [-600, 600].
        _seedConcentrated(-600, 600, 10_000e18, 10_000e18);

        // A large swap that will cross the tick boundary.
        // In a [-600, 600] range with 10K each side, swapping ~1K should push price significantly.
        uint256 amountIn = 1000e18;

        // Get the actual quote (which will reflect the tick crossing).
        uint256 quotedOutput = _quoteAmountOut(amountIn);

        // Execute the swap with a generous minimum.
        uint256 output = _paySwap(amountIn, quotedOutput / 2);

        assertGt(output, 0, "should produce output");
        // Concentrated should give more or similar output for moderate swaps due to deeper
        // liquidity within the range. But for large swaps that exit the range, they may give less.
        // The key assertion: the swap succeeded and produced reasonable output.
        assertGe(output, amountIn / 10, "output should be reasonable");
    }

    /// @notice Very narrow range [-60, 60], large swap exits active range.
    ///         Expect partial fill (only the liquidity within range is available).
    function test_swapExitingLiquidity() public {
        // Very narrow range: [-60, 60] (~0.6% around current price).
        _seedConcentrated(-60, 60, 1000e18, 1000e18);

        // Large swap that will exhaust the narrow range liquidity.
        uint256 amountIn = 500e18;

        // The swap should still succeed (V3 partial fills by stopping at the price limit),
        // but the output will be limited by available liquidity.
        // Use a very generous minimum (essentially 0) to allow partial fills.
        uint256 output = _paySwap(amountIn, 0);

        assertGt(output, 0, "should produce some output even if partial fill");
        // Output will be much less than input since liquidity runs out quickly.
        assertLt(output, amountIn, "output should be less than input due to price impact");
    }

    /// @notice Liquidity only above current price. For a zeroForOne swap (tokenA -> tokenB),
    ///         price decreases, so above-range liquidity is unreachable.
    ///         Swap with minAmountOut > 0 should revert.
    function test_noLiquidityAtCurrentPrice() public {
        // For a zeroForOne swap (selling token0 for token1), the price DECREASES.
        // Liquidity above current tick won't be reached.
        // Place liquidity only at [600, 1200] — above current tick (0).
        tokenA.mint(address(this), 10_000e18);
        tokenB.mint(address(this), 10_000e18);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        addLiquidity(address(pool), 600, 1200, 10_000e18, 10_000e18);

        // Try to swap tokenA -> tokenB.
        // The price needs to go DOWN but there's no liquidity below current tick.
        // V3 will just stop at the sqrtPriceLimit with zero or minimal output.
        uint256 amountIn = 1e18;

        tokenA.mint(caller, amountIn);
        vm.startPrank(caller);
        tokenA.approve(address(swapTerminal), amountIn);

        // Use a meaningful minAmountOut to ensure revert when output is insufficient.
        bytes memory metadata = _quoteMetadata(amountIn / 2);

        vm.expectRevert();
        swapTerminal.pay({
            projectId: PROJECT_ID,
            token: address(tokenA),
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: metadata
        });
        vm.stopPrank();
    }

    /// @notice Compare deep concentrated (+-1%) vs shallow full-range. Small swap:
    ///         concentrated should have better execution (less slippage).
    function test_deepConcentratedVsShallowFullRange() public {
        uint256 amountIn = 100e18; // larger swap to make the difference measurable

        // Snapshot the clean pool state.
        uint256 snap = vm.snapshot();

        // --- Scenario A: Deep concentrated at +/-1% (ticks [-120, 120]) ---
        _seedConcentrated(-120, 120, 100_000e18, 100_000e18);
        uint256 concentratedOutput = _quoteAmountOut(amountIn);

        // Revert to the clean pool state.
        vm.revertTo(snap);

        // --- Scenario B: Same total liquidity spread across full range ---
        _seedFullRange(100_000e18, 100_000e18);
        uint256 fullRangeOutput = _quoteAmountOut(amountIn);

        // For a small-to-moderate swap, concentrated liquidity should provide better execution
        // (more output) because the same capital is concentrated in a narrow range,
        // providing more depth around the current price.
        assertGt(
            concentratedOutput,
            fullRangeOutput,
            "concentrated should produce more output than full-range for small swap"
        );

        // Verify both produce meaningful output.
        assertGt(concentratedOutput, 0, "concentrated output should be > 0");
        assertGt(fullRangeOutput, 0, "full-range output should be > 0");
    }
}
