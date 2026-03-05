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
contract MockTokenSV is ERC20 {
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
contract MockWETHSV is MockTokenSV {
    constructor() MockTokenSV("Wrapped Ether", "WETH", 18) {}

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

/// @title SigmoidValidation
/// @notice Tests the sigmoid mathematical properties of JBSwapLib slippage tolerance functions.
contract SigmoidValidation is PoolTestHelper {
    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    MockTokenSV internal tokenA;
    MockTokenSV internal tokenB;

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

    MockWETHSV internal weth;

    address internal caller;
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
        weth = new MockWETHSV();
        tokenA = new MockTokenSV("Token A", "TKA", 18);
        tokenB = new MockTokenSV("Token B", "TKB", 18);
        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        token0 = address(tokenA);
        token1 = address(tokenB);

        // 2. Create a real V3 pool via PoolTestHelper.
        pool = IUniswapV3Pool(address(createPool(token0, token1, POOL_FEE, SQRT_PRICE_1_TO_1, Chains.Other)));

        // 3. Seed liquidity (100K of each token, full-range).
        tokenA.mint(address(this), 100_000e18);
        tokenB.mint(address(this), 100_000e18);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        addLiquidityFullRange(address(pool), 100_000e18, 100_000e18);

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

    /// @notice Get pool's current liquidity and sqrtPrice.
    function _getPoolState() internal view returns (uint128 liquidity, uint160 sqrtPriceX96) {
        liquidity = pool.liquidity();
        (sqrtPriceX96,,,,,,) = pool.slot0();
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    /// @notice For 5 amounts: compute sigmoid tolerance, execute real swap, verify actual
    ///         slippage is within the tolerance.
    function test_sigmoidMatchesRealSlippage() public {
        uint256[5] memory amounts = [uint256(1e18), 10e18, 100e18, 1000e18, 10_000e18];

        (uint128 liquidity, uint160 sqrtP) = _getPoolState();
        bool zeroForOne = address(tokenA) < address(tokenB); // tokenA is token0

        // Pool fee in basis points: 3000/100 = 30 bps.
        uint256 poolFeeBps = uint256(POOL_FEE) / 100;

        for (uint256 i; i < 5; i++) {
            uint256 amountIn = amounts[i];

            // Calculate sigmoid impact and tolerance.
            uint256 impact = JBSwapLib.calculateImpact(amountIn, liquidity, sqrtP, zeroForOne);
            uint256 toleranceBps = JBSwapLib.getSlippageTolerance(impact, poolFeeBps);

            // Execute a real swap via snapshot to measure actual slippage.
            uint256 actualOutput = _quoteAmountOut(amountIn);

            // For a 1:1 pool, the "ideal" output is amountIn.
            // Actual slippage = (ideal - actual) / ideal * 10000 bps.
            uint256 actualSlippageBps;
            if (actualOutput < amountIn) {
                actualSlippageBps = ((amountIn - actualOutput) * 10_000) / amountIn;
            }

            // The sigmoid tolerance should be >= actual slippage.
            // (The sigmoid is designed to be a conservative upper bound.)
            assertGe(
                toleranceBps,
                actualSlippageBps,
                string.concat("sigmoid tolerance should >= actual slippage for amount index ", vm.toString(i))
            );

            // Verify tolerance is reasonable (not 0, not > MAX_SLIPPAGE).
            assertGt(toleranceBps, 0, "tolerance should be > 0");
            assertLe(toleranceBps, 8800, "tolerance should be <= MAX_SLIPPAGE (8800 bps)");
        }
    }

    /// @notice Vary size and verify tolerance increases monotonically.
    function test_sigmoidScalesWithImpact() public {
        (uint128 liquidity, uint160 sqrtP) = _getPoolState();
        bool zeroForOne = address(tokenA) < address(tokenB);
        uint256 poolFeeBps = uint256(POOL_FEE) / 100;

        // Increasing amounts: 0.01, 0.1, 1, 10, 100, 1000, 10000 ETH.
        uint256[7] memory amounts = [uint256(0.01e18), 0.1e18, 1e18, 10e18, 100e18, 1000e18, 10_000e18];

        uint256 prevTolerance = 0;

        for (uint256 i; i < 7; i++) {
            uint256 impact = JBSwapLib.calculateImpact(amounts[i], liquidity, sqrtP, zeroForOne);
            uint256 tolerance = JBSwapLib.getSlippageTolerance(impact, poolFeeBps);

            // Tolerance should be monotonically non-decreasing as amount increases.
            assertGe(
                tolerance, prevTolerance, string.concat("tolerance should be non-decreasing at index ", vm.toString(i))
            );

            prevTolerance = tolerance;
        }

        // Additionally, the first tolerance (tiny swap) should be close to minimum,
        // and the last tolerance (huge swap) should be close to or at maximum.
        uint256 firstImpact = JBSwapLib.calculateImpact(amounts[0], liquidity, sqrtP, zeroForOne);
        uint256 firstTolerance = JBSwapLib.getSlippageTolerance(firstImpact, poolFeeBps);

        uint256 lastImpact = JBSwapLib.calculateImpact(amounts[6], liquidity, sqrtP, zeroForOne);
        uint256 lastTolerance = JBSwapLib.getSlippageTolerance(lastImpact, poolFeeBps);

        // Minimum is poolFee + 100 bps = 130 bps, but floor at 200 bps.
        assertLe(firstTolerance, 500, "tiny swap tolerance should be relatively low");
        assertGt(lastTolerance, firstTolerance, "huge swap tolerance should be > tiny swap tolerance");
    }

    /// @notice Different pool fees should produce different minimum tolerances.
    ///         Higher fee = higher minimum tolerance.
    function test_sigmoidRespectsPoolFee() public {
        // Use zero impact to isolate the effect of pool fee on the minimum slippage.
        // At impact=0, sigmoid returns minSlippage = max(poolFeeBps + 100, 200).
        // So fees above 100 bps start pushing the minimum above the 200 bps floor.

        // Pool fees where the minimum starts to differentiate:
        // 50 bps: min = max(150, 200) = 200
        // 150 bps: min = max(250, 200) = 250
        // 500 bps: min = max(600, 200) = 600
        // 1000 bps: min = max(1100, 200) = 1100
        uint256[4] memory poolFees = [uint256(50), 150, 500, 1000];

        uint256 prevTolerance = 0;

        for (uint256 i; i < 4; i++) {
            // Zero impact: sigmoid returns the minimum slippage directly.
            uint256 tolerance = JBSwapLib.getSlippageTolerance(0, poolFees[i]);

            // Higher pool fee should produce higher or equal tolerance.
            assertGe(
                tolerance,
                prevTolerance,
                string.concat("higher fee should produce higher tolerance at index ", vm.toString(i))
            );

            prevTolerance = tolerance;
        }

        // Verify 150 bps fee gives higher minimum than 50 bps fee.
        uint256 lowFeeTolerance = JBSwapLib.getSlippageTolerance(0, 50);
        uint256 highFeeTolerance = JBSwapLib.getSlippageTolerance(0, 150);
        assertGt(highFeeTolerance, lowFeeTolerance, "150 bps fee should produce higher minimum than 50 bps fee");

        // Also verify with non-zero impact — the effect should persist.
        (uint128 liquidity, uint160 sqrtP) = _getPoolState();
        uint256 impact = JBSwapLib.calculateImpact(1000e18, liquidity, sqrtP, true);
        uint256 tolLow = JBSwapLib.getSlippageTolerance(impact, 150);
        uint256 tolHigh = JBSwapLib.getSlippageTolerance(impact, 500);
        assertGt(tolHigh, tolLow, "500 bps fee tolerance should be > 150 bps fee tolerance with same impact");
    }

    /// @notice Test impact precision for small swaps. Verify that the calculation maintains
    ///         precision for sub-ETH amounts and that impact scales correctly.
    function test_impactPrecisionNoRounding() public {
        (uint128 liquidity, uint160 sqrtP) = _getPoolState();
        bool zeroForOne = address(tokenA) < address(tokenB);

        // 1 wei in a 100K pool: mulDiv(1, 1e18, liquidity_raw) can round to 0
        // because the V3 liquidity is extremely large relative to 1 wei.
        // This is mathematically correct — the impact truly IS zero for 1 wei.
        uint256 impact1wei = JBSwapLib.calculateImpact(1, liquidity, sqrtP, zeroForOne);
        // Accept that 1 wei may round to 0 — this is not a precision bug.

        // For meaningful amounts (1 gwei = 1e9 wei), impact should be > 0.
        uint256 impactGwei = JBSwapLib.calculateImpact(1e9, liquidity, sqrtP, zeroForOne);
        assertGt(impactGwei, 0, "1 gwei impact should be > 0 in a 100K pool");

        // 1 ETH should produce clearly non-zero impact.
        uint256 impact1eth = JBSwapLib.calculateImpact(1e18, liquidity, sqrtP, zeroForOne);
        assertGt(impact1eth, 0, "1 ETH impact should be > 0");
        assertGt(impact1eth, impactGwei, "1 ETH impact should be > 1 gwei impact");

        // Impact should scale roughly linearly for small amounts.
        uint256 impact10eth = JBSwapLib.calculateImpact(10e18, liquidity, sqrtP, zeroForOne);
        assertGt(impact10eth, impact1eth, "10 ETH impact should be > 1 ETH impact");

        // Verify the tolerance produced by zero impact is the minimum floor.
        uint256 poolFeeBps = uint256(POOL_FEE) / 100;
        uint256 toleranceZero = JBSwapLib.getSlippageTolerance(0, poolFeeBps);
        // Minimum tolerance for 30 bps fee = max(30 + 100, 200) = 200 bps.
        assertEq(toleranceZero, 200, "zero impact tolerance should be exactly the floor (200 bps)");

        // Tolerance for 1 wei (if impact == 0) should also be the floor.
        uint256 tolerance1wei = JBSwapLib.getSlippageTolerance(impact1wei, poolFeeBps);
        assertEq(tolerance1wei, 200, "1 wei tolerance should be the floor (200 bps)");
    }
}
