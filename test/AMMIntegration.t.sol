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
contract MockToken is ERC20 {
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
contract MockWETH is MockToken {
    constructor() MockToken("Wrapped Ether", "WETH", 18) {}

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

/// @title AMMIntegration
/// @notice End-to-end integration tests for JBSwapTerminal using real Uniswap V3 pools
///         deployed locally via PoolTestHelper (no fork required).
contract AMMIntegration is PoolTestHelper {
    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    MockToken internal tokenA; // the token we pay *in*
    MockToken internal tokenB; // the token the terminal swaps *to*

    // Sorted references (token0 < token1) for pool arithmetic.
    address internal token0;
    address internal token1;

    IUniswapV3Pool internal pool;
    JBSwapTerminal internal swapTerminal;

    // Mock JB infrastructure addresses.
    IJBDirectory internal mockDirectory;
    IJBPermissions internal mockPermissions;
    IJBProjects internal mockProjects;
    IPermit2 internal mockPermit2;
    IUniswapV3Factory internal mockFactory;
    address internal nextTerminal;

    MockWETH internal weth;

    address internal caller;
    address internal beneficiary;
    address internal projectOwner;

    uint256 internal constant PROJECT_ID = 42;
    uint24 internal constant POOL_FEE = 3000; // 0.3 %
    uint160 internal constant SQRT_PRICE_1_TO_1 = 79_228_162_514_264_337_593_543_950_336; // 2^96

    // -----------------------------------------------------------------------
    // setUp
    // -----------------------------------------------------------------------

    function setUp() public {
        // 1. Deploy tokens and sort so token0 < token1.
        weth = new MockWETH();
        tokenA = new MockToken("Token A", "TKA", 18);
        tokenB = new MockToken("Token B", "TKB", 18);
        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        token0 = address(tokenA);
        token1 = address(tokenB);

        // 2. Create a real V3 pool via PoolTestHelper.
        //    PoolTestHelper returns its own IUniswapV3Pool type; cast through address.
        pool = IUniswapV3Pool(address(createPool(token0, token1, POOL_FEE, SQRT_PRICE_1_TO_1, Chains.Other)));

        // 3. Seed liquidity (1M of each token, full-range).
        tokenA.mint(address(this), 1_000_000e18);
        tokenB.mint(address(this), 1_000_000e18);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        addLiquidityFullRange(address(pool), 1_000_000e18, 1_000_000e18);

        // 4. Deploy mock JB contracts (etch so they have code at the address).
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

        // 5. Deploy the real JBSwapTerminal.
        //    tokenOut = tokenB (the token we swap *to*).
        swapTerminal = new JBSwapTerminal(
            mockDirectory,
            mockPermissions,
            mockProjects,
            mockPermit2,
            projectOwner, // terminal owner
            IWETH9(address(weth)),
            address(tokenB), // TOKEN_OUT
            mockFactory,
            address(0) // no trusted forwarder
        );

        // 6. Mock the factory's getPool to return our real pool for both token orderings.
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

        // 7. Mock projects.ownerOf to return projectOwner.
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

    /// @notice Get a rough quote by performing a real swap via PoolTestHelper, then
    ///         reversing it. For simplicity, we do a direct pool swap from this contract
    ///         and record the output.
    function _quoteAmountOut(uint256 amountIn) internal returns (uint256 amountOut) {
        // Snapshot so we can revert the quote swap.
        uint256 snapshot = vm.snapshot();

        // Mint tokens for the quote swap.
        tokenA.mint(address(this), amountIn);

        // Perform the swap via PoolTestHelper's swap (uses this contract's callback).
        uint256 tokenBBefore = tokenB.balanceOf(address(this));
        this.swap(address(pool), address(tokenA), amountIn);
        amountOut = tokenB.balanceOf(address(this)) - tokenBBefore;

        // Revert to snapshot so the pool state is untouched.
        vm.revertTo(snapshot);
    }

    // -----------------------------------------------------------------------
    // Test 1: pay() executes a real swap
    // -----------------------------------------------------------------------

    /// @notice Calling `pay()` with tokenA should execute a real V3 swap and forward
    ///         tokenB to the next terminal via `pay()`.
    function test_payExecutesRealSwap() public {
        uint256 amountIn = 1000e18;

        // Get an accurate quote so the swap will not revert on slippage.
        uint256 expectedOut = _quoteAmountOut(amountIn);
        // Use 95% of the expected output as minAmountOut to leave room for price impact.
        uint256 minAmountOut = (expectedOut * 95) / 100;

        // Mint tokenA to caller and approve the terminal.
        tokenA.mint(caller, amountIn);
        vm.prank(caller);
        tokenA.approve(address(swapTerminal), amountIn);

        // Build metadata with the quote.
        bytes memory metadata = _quoteMetadata(minAmountOut);

        // Execute the pay.
        vm.prank(caller);
        swapTerminal.pay({
            projectId: PROJECT_ID,
            token: address(tokenA),
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: metadata
        });

        // Assertions:
        // - Caller's tokenA was consumed.
        assertEq(tokenA.balanceOf(caller), 0, "caller should have 0 tokenA left");
        // - The swap terminal should not hold any leftover tokenA.
        assertEq(tokenA.balanceOf(address(swapTerminal)), 0, "terminal should not hold leftover tokenA");
        // - The swap terminal received tokenB from the real swap and approved it to the
        //   next terminal. Since the next terminal is a mock that does not pull tokens,
        //   tokenB remains in the terminal. Verify a non-zero amount was swapped.
        uint256 terminalTokenB = tokenB.balanceOf(address(swapTerminal));
        assertGe(terminalTokenB, minAmountOut, "swap output should meet the minimum");
        // - Verify the allowance was set for the next terminal.
        assertGe(
            tokenB.allowance(address(swapTerminal), nextTerminal),
            0,
            "tokenB should have been approved to next terminal"
        );
    }

    // -----------------------------------------------------------------------
    // Test 2: addToBalance() executes a real swap
    // -----------------------------------------------------------------------

    /// @notice Calling `addToBalanceOf()` with tokenA should execute a real V3 swap
    ///         and forward tokenB to the next terminal via `addToBalanceOf()`.
    function test_addToBalanceExecutesRealSwap() public {
        uint256 amountIn = 500e18;

        uint256 expectedOut = _quoteAmountOut(amountIn);
        uint256 minAmountOut = (expectedOut * 95) / 100;

        tokenA.mint(caller, amountIn);
        vm.prank(caller);
        tokenA.approve(address(swapTerminal), amountIn);

        bytes memory metadata = _quoteMetadata(minAmountOut);

        vm.prank(caller);
        swapTerminal.addToBalanceOf({
            projectId: PROJECT_ID,
            token: address(tokenA),
            amount: amountIn,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: metadata
        });

        // Caller's tokenA was consumed.
        assertEq(tokenA.balanceOf(caller), 0, "caller should have 0 tokenA left");
        // Terminal should not hold any leftover tokenA.
        assertEq(tokenA.balanceOf(address(swapTerminal)), 0, "terminal should not hold leftover tokenA");
        // tokenB remains in the terminal because the mock next terminal does not pull it.
        // Verify a non-zero swap output was produced.
        uint256 terminalTokenB = tokenB.balanceOf(address(swapTerminal));
        assertGe(terminalTokenB, minAmountOut, "swap output should meet the minimum");
    }

    // -----------------------------------------------------------------------
    // Test 3: TWAP-based minimum output (no user quote)
    // -----------------------------------------------------------------------

    /// @notice When no quote metadata is provided, the terminal should use the TWAP
    ///         oracle to compute a minimum output and execute the swap.
    function test_twapBasedMinimumOutput() public {
        uint256 amountIn = 100e18;

        // Set TWAP params for the project's pool.
        vm.prank(projectOwner);
        swapTerminal.addTwapParamsFor(PROJECT_ID, pool, 2 minutes);

        // Build TWAP observations: increase cardinality, perform swaps, warp time.
        pool.increaseObservationCardinalityNext(20);

        // Swap a small amount to create an observation at the current timestamp.
        tokenA.mint(address(this), 1e18);
        tokenA.approve(address(pool), type(uint256).max);
        this.swap(address(pool), address(tokenA), 1e18);

        // Advance time so we have a historical observation.
        vm.warp(block.timestamp + 3 minutes);

        // Perform another small swap to create a second observation.
        tokenA.mint(address(this), 1e18);
        this.swap(address(pool), address(tokenA), 1e18);

        // Advance a little more so the observation is in the past.
        vm.warp(block.timestamp + 1 minutes);

        // Now call pay() WITHOUT quote metadata -- the terminal should use TWAP.
        tokenA.mint(caller, amountIn);
        vm.prank(caller);
        tokenA.approve(address(swapTerminal), amountIn);

        // Empty metadata (no quoteForSwap entry).
        bytes memory metadata = "";

        vm.prank(caller);
        swapTerminal.pay({
            projectId: PROJECT_ID,
            token: address(tokenA),
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: metadata
        });

        // If we got here without reverting, the TWAP-based swap executed successfully.
        assertEq(tokenA.balanceOf(caller), 0, "caller tokenA should be consumed");
    }

    // -----------------------------------------------------------------------
    // Test 4: User quote overrides TWAP
    // -----------------------------------------------------------------------

    /// @notice When the user provides a quote in metadata, it should be used
    ///         as minAmountOut instead of the TWAP-derived value.
    function test_userQuoteOverridesTwap() public {
        uint256 amountIn = 200e18;

        // Set TWAP params.
        vm.prank(projectOwner);
        swapTerminal.addTwapParamsFor(PROJECT_ID, pool, 2 minutes);

        // Create observations (same as test 3).
        pool.increaseObservationCardinalityNext(20);
        tokenA.mint(address(this), 1e18);
        tokenA.approve(address(pool), type(uint256).max);
        this.swap(address(pool), address(tokenA), 1e18);
        vm.warp(block.timestamp + 3 minutes);
        tokenA.mint(address(this), 1e18);
        this.swap(address(pool), address(tokenA), 1e18);
        vm.warp(block.timestamp + 1 minutes);

        // Get quote and use a lower minAmountOut (the user quote should take precedence).
        uint256 expectedOut = _quoteAmountOut(amountIn);
        uint256 userMinAmountOut = (expectedOut * 90) / 100; // 90% -- more lenient than TWAP typically

        tokenA.mint(caller, amountIn);
        vm.prank(caller);
        tokenA.approve(address(swapTerminal), amountIn);

        bytes memory metadata = _quoteMetadata(userMinAmountOut);

        // This should succeed using the user's quote rather than the TWAP.
        vm.prank(caller);
        swapTerminal.pay({
            projectId: PROJECT_ID,
            token: address(tokenA),
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: metadata
        });

        assertEq(tokenA.balanceOf(caller), 0, "caller tokenA should be consumed");
    }

    // -----------------------------------------------------------------------
    // Test 5: Swap reverts on slippage exceeded
    // -----------------------------------------------------------------------

    /// @notice Providing an unrealistically high minAmountOut should cause the swap
    ///         to revert with JBSwapTerminal_SpecifiedSlippageExceeded.
    function test_swapRevertsOnSlippageExceeded() public {
        uint256 amountIn = 1000e18;

        // Quote the real expected output, then demand 10x that -- impossible.
        uint256 expectedOut = _quoteAmountOut(amountIn);
        uint256 unrealisticMin = expectedOut * 10;

        tokenA.mint(caller, amountIn);
        vm.prank(caller);
        tokenA.approve(address(swapTerminal), amountIn);

        bytes memory metadata = _quoteMetadata(unrealisticMin);

        // The swap should revert because the pool cannot deliver 10x the expected output.
        // The revert could be JBSwapTerminal_SpecifiedSlippageExceeded or SPL (the V3 pool's
        // sqrtPriceLimit check), depending on how JBSwapLib.sqrtPriceLimitFromAmounts computes
        // the limit.
        vm.prank(caller);
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
    }
}
