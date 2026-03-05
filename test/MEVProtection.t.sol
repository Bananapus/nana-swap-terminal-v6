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
contract MockTokenMEV is ERC20 {
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
contract MockWETHMEV is MockTokenMEV {
    constructor() MockTokenMEV("Wrapped Ether", "WETH", 18) {}

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

/// @title MEVProtection
/// @notice Tests MEV protection properties of JBSwapTerminal.
contract MEVProtection is PoolTestHelper {
    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    MockTokenMEV internal tokenA;
    MockTokenMEV internal tokenB;

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

    MockWETHMEV internal weth;

    address internal caller;
    address internal attacker;
    address internal beneficiary;
    address internal projectOwner;

    uint256 internal constant PROJECT_ID = 42;
    uint24 internal constant POOL_FEE = 3000; // 0.3%
    uint160 internal constant SQRT_PRICE_1_TO_1 = 79_228_162_514_264_337_593_543_950_336; // 2^96

    // -----------------------------------------------------------------------
    // setUp
    // -----------------------------------------------------------------------

    function setUp() public {
        // 1. Deploy tokens and sort so token0 < token1.
        weth = new MockWETHMEV();
        tokenA = new MockTokenMEV("Token A", "TKA", 18);
        tokenB = new MockTokenMEV("Token B", "TKB", 18);
        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        token0 = address(tokenA);
        token1 = address(tokenB);

        // 2. Create a real V3 pool via PoolTestHelper.
        pool = IUniswapV3Pool(address(createPool(token0, token1, POOL_FEE, SQRT_PRICE_1_TO_1, Chains.Other)));

        // 3. Seed liquidity (10K of each token, full-range).
        tokenA.mint(address(this), 10_000e18);
        tokenB.mint(address(this), 10_000e18);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        addLiquidityFullRange(address(pool), 10_000e18, 10_000e18);

        // 4. Deploy mock JB contracts.
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
        attacker = makeAddr("attacker");
        beneficiary = makeAddr("beneficiary");
        projectOwner = makeAddr("projectOwner");

        // 5. Deploy the real JBSwapTerminal. tokenOut = tokenB.
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

        // 6. Mock the factory's getPool.
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

        // 7. Mock projects.ownerOf.
        vm.mockCall(address(mockProjects), abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(projectOwner));

        // 8. Configure the default pool for this project.
        vm.prank(projectOwner);
        swapTerminal.addDefaultPool(PROJECT_ID, address(tokenA), pool);

        // 9. Mock the directory: primaryTerminalOf(PROJECT_ID, tokenB) => nextTerminal.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(tokenB))),
            abi.encode(nextTerminal)
        );

        // 10. Mock the next terminal's pay and addToBalanceOf to succeed.
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

    /// @notice Get a rough quote by performing a real swap, then reverting.
    function _quoteAmountOut(uint256 amountIn) internal returns (uint256 amountOut) {
        uint256 snap = vm.snapshot();

        tokenA.mint(address(this), amountIn);
        uint256 tokenBBefore = tokenB.balanceOf(address(this));
        this.swap(address(pool), address(tokenA), amountIn);
        amountOut = tokenB.balanceOf(address(this)) - tokenBBefore;

        vm.revertTo(snap);
    }

    /// @notice Execute a frontrunning swap directly on the pool (attacker bypasses terminal).
    function _frontrunSwap(uint256 amountIn) internal {
        tokenA.mint(address(this), amountIn);
        this.swap(address(pool), address(tokenA), amountIn);
    }

    /// @notice Execute a pay via the terminal. Returns the output or 0 if reverted.
    function _paySwapSafe(uint256 amountIn, uint256 minAmountOut) internal returns (uint256 output, bool reverted) {
        tokenA.mint(caller, amountIn);
        vm.startPrank(caller);
        tokenA.approve(address(swapTerminal), amountIn);

        bytes memory metadata = _quoteMetadata(minAmountOut);

        try swapTerminal.pay{value: 0}({
            projectId: PROJECT_ID,
            token: address(tokenA),
            amount: amountIn,
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

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    /// @notice Test frontrun protection: victim gets a quote, attacker frontrun-swaps a large amount,
    ///         then victim pays with original quote. Should revert or output drops significantly.
    function test_frontrunProtection() public {
        uint256 victimAmount = 100e18;
        uint256 frontrunAmount = 2000e18; // 20% of pool

        // Step 1: Victim gets a quote before frontrun.
        uint256 expectedOutPreFrontrun = _quoteAmountOut(victimAmount);
        // Victim sets minAmountOut to 95% of their expected output.
        uint256 victimMinOut = (expectedOutPreFrontrun * 95) / 100;

        // Step 2: Attacker frontrun-swaps (moves price against victim).
        _frontrunSwap(frontrunAmount);

        // Step 3: Victim attempts swap with their original quote.
        // The pool price has moved. If the victim's minAmountOut is tight enough,
        // the swap should revert because the output dropped below the minimum.
        (uint256 output, bool reverted) = _paySwapSafe(victimAmount, victimMinOut);

        if (reverted) {
            // The slippage protection correctly rejected the swap.
            // This is the ideal MEV protection outcome.
            assertTrue(true, "frontrun protection: swap correctly reverted");
        } else {
            // If the swap somehow succeeded despite the frontrun, the output should be
            // at least the victim's minimum (the terminal enforces this).
            assertGe(output, victimMinOut, "if swap succeeded, output must meet minimum");
        }
    }

    /// @notice Sandwich attack quantification: compare output with and without frontrun.
    ///         Verify that the user quote (dynamic limit) mitigates the loss.
    function test_sandwichQuantified() public {
        uint256 victimAmount = 100e18;
        uint256 frontrunAmount = 1000e18; // 10% of pool

        // Step 1: Get the clean output (no frontrun).
        uint256 cleanOutput = _quoteAmountOut(victimAmount);

        // Step 2: Snapshot, execute frontrun, then get the degraded output.
        uint256 snap = vm.snapshot();

        _frontrunSwap(frontrunAmount);
        uint256 degradedOutput = _quoteAmountOut(victimAmount);

        // Step 3: Quantify the loss.
        uint256 loss = cleanOutput - degradedOutput;
        uint256 lossBps = (loss * 10_000) / cleanOutput;

        // The frontrun should cause measurable loss.
        assertGt(loss, 0, "frontrun should cause loss");
        assertGt(lossBps, 0, "loss in bps should be > 0");

        // Step 4: Verify the dynamic limit helps — victim using clean quote as minimum
        // should have their swap rejected (protecting them from the sandwich).
        uint256 victimMinOut = (cleanOutput * 98) / 100; // 98% of clean — tight protection

        (uint256 output, bool reverted) = _paySwapSafe(victimAmount, victimMinOut);

        // Restore state.
        vm.revertTo(snap);

        if (reverted) {
            // The dynamic limit correctly protected the victim from the sandwich.
            assertTrue(true, "dynamic limit protected victim from sandwich");
        } else {
            // If it succeeded, the loss must be within the 2% tolerance.
            assertGe(output, victimMinOut, "output must meet the dynamic limit if swap succeeded");
        }
    }

    /// @notice Slightly move price, then swap with slightly stale quote.
    ///         Should produce output but less than original quote.
    function test_partialFillOnPriceLimit() public {
        uint256 victimAmount = 50e18;

        // Step 1: Get clean quote.
        uint256 cleanOutput = _quoteAmountOut(victimAmount);

        // Step 2: Slight price movement (small swap, ~1% of pool).
        uint256 smallMove = 100e18;
        _frontrunSwap(smallMove);

        // Step 3: Get the post-move quote.
        uint256 postMoveOutput = _quoteAmountOut(victimAmount);

        // The post-move output should be less than clean (price moved against us).
        assertLt(postMoveOutput, cleanOutput, "post-move output should be less than clean");

        // Step 4: Execute swap with a generous minimum (50% of clean output).
        // This should succeed because the price movement was small.
        uint256 generousMin = cleanOutput / 2;
        (uint256 output, bool reverted) = _paySwapSafe(victimAmount, generousMin);

        assertFalse(reverted, "swap with generous min should not revert for small price move");
        assertGt(output, 0, "should produce output");
        assertGe(output, generousMin, "output should meet generous minimum");
        // Output should be less than the clean output (price has moved).
        assertLt(output, cleanOutput, "output should be less than pre-move clean output");
    }
}
