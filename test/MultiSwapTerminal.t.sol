// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./helper/UnitFixture.sol";
import "../src/JBMultiSwapTerminal.sol";
import {IUniswapV3PoolState} from "@uniswap/v3-core/contracts/interfaces/pool/IUniswapV3PoolState.sol";
import {IUniswapV3PoolImmutables} from "@uniswap/v3-core/contracts/interfaces/pool/IUniswapV3PoolImmutables.sol";

contract MultiSwapTerminalTest is UnitFixture {
    JBMultiSwapTerminal public multiSwapTerminal;

    function setUp() public override {
        super.setUp();

        multiSwapTerminal = new JBMultiSwapTerminal(
            mockJBDirectory,
            mockJBPermissions,
            mockJBProjects,
            mockPermit2,
            terminalOwner,
            mockWETH,
            mockTokenOut,
            mockUniswapFactory,
            address(0)
        );
    }

    // ───────────────────────────────────────────────────────────────────
    //  _discoverPool tests
    // ───────────────────────────────────────────────────────────────────

    function test_discoverPool_findsHighestLiquidity() public {
        address tokenIn = makeAddr("tokenIn");
        vm.etch(tokenIn, hex"00");

        // Create mock pools for two fee tiers
        address pool3000 = makeAddr("pool3000");
        vm.etch(pool3000, hex"00");
        address pool500 = makeAddr("pool500");
        vm.etch(pool500, hex"00");

        // Factory returns pool3000 for 3000 fee tier
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, mockTokenOut, 3000)),
            abi.encode(pool3000)
        );
        // Factory returns pool500 for 500 fee tier
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, mockTokenOut, 500)),
            abi.encode(pool500)
        );
        // Factory returns address(0) for other tiers
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, mockTokenOut, 10_000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, mockTokenOut, 100)),
            abi.encode(address(0))
        );

        // pool500 has higher liquidity
        vm.mockCall(pool3000, abi.encodeCall(IUniswapV3PoolState.liquidity, ()), abi.encode(uint128(1000e18)));
        vm.mockCall(pool500, abi.encodeCall(IUniswapV3PoolState.liquidity, ()), abi.encode(uint128(5000e18)));

        IUniswapV3Pool discovered = multiSwapTerminal.discoverPool(tokenIn, mockTokenOut);
        assertEq(address(discovered), pool500, "should pick pool with highest liquidity");
    }

    function test_discoverPool_revertsWhenNoPool() public {
        address tokenIn = makeAddr("tokenIn");

        // Factory returns address(0) for all fee tiers
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, mockTokenOut, 3000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, mockTokenOut, 500)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, mockTokenOut, 10_000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, mockTokenOut, 100)),
            abi.encode(address(0))
        );

        vm.expectRevert(
            abi.encodeWithSelector(JBMultiSwapTerminal.JBMultiSwapTerminal_NoPoolFound.selector, tokenIn, mockTokenOut)
        );
        multiSwapTerminal.discoverPool(tokenIn, mockTokenOut);
    }

    function test_discoverPool_singlePool() public {
        address tokenIn = makeAddr("tokenIn");
        vm.etch(tokenIn, hex"00");

        address pool10000 = makeAddr("pool10000");
        vm.etch(pool10000, hex"00");

        // Only 10000 fee tier has a pool
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, mockTokenOut, 3000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, mockTokenOut, 500)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, mockTokenOut, 10_000)),
            abi.encode(pool10000)
        );
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, mockTokenOut, 100)),
            abi.encode(address(0))
        );

        vm.mockCall(pool10000, abi.encodeCall(IUniswapV3PoolState.liquidity, ()), abi.encode(uint128(100e18)));

        IUniswapV3Pool discovered = multiSwapTerminal.discoverPool(tokenIn, mockTokenOut);
        assertEq(address(discovered), pool10000, "should find the only existing pool");
    }

    // ───────────────────────────────────────────────────────────────────
    //  uniswapV3SwapCallback tests
    // ───────────────────────────────────────────────────────────────────

    function test_callback_acceptsAutoDiscoveredPool() public {
        address tokenIn = makeAddr("tokenIn");
        vm.etch(tokenIn, hex"00");
        uint256 projectId = 1;

        // Create a mock pool that the factory verifies
        address discoveredPool = makeAddr("discoveredPool");
        vm.etch(discoveredPool, hex"00");

        // Mock: pool.fee() returns 3000
        vm.mockCall(discoveredPool, abi.encodeCall(IUniswapV3PoolImmutables.fee, ()), abi.encode(uint24(3000)));

        // Mock: factory verifies this pool
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, mockTokenOut, 3000)),
            abi.encode(discoveredPool)
        );

        // Mock: token transfer from terminal to pool
        vm.mockCall(
            tokenIn, abi.encodeCall(IERC20.allowance, (address(multiSwapTerminal), discoveredPool)), abi.encode(uint256(0))
        );
        vm.mockCall(tokenIn, abi.encodeCall(IERC20.transfer, (discoveredPool, 1e18)), abi.encode(true));

        // Call the callback as the discovered pool
        bytes memory callbackData = abi.encode(projectId, tokenIn);
        vm.prank(discoveredPool);
        multiSwapTerminal.uniswapV3SwapCallback(int256(1e18), -int256(0.95e18), callbackData);
    }

    function test_callback_rejectsUnverifiedPool() public {
        address tokenIn = makeAddr("tokenIn");
        vm.etch(tokenIn, hex"00");
        uint256 projectId = 1;

        address fakePool = makeAddr("fakePool");
        vm.etch(fakePool, hex"00");

        // Mock: pool.fee() returns 3000
        vm.mockCall(fakePool, abi.encodeCall(IUniswapV3PoolImmutables.fee, ()), abi.encode(uint24(3000)));

        // Mock: factory does NOT verify this pool
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, mockTokenOut, 3000)),
            abi.encode(address(0))
        );

        bytes memory callbackData = abi.encode(projectId, tokenIn);
        vm.prank(fakePool);
        vm.expectRevert(abi.encodeWithSelector(JBSwapTerminal.JBSwapTerminal_CallerNotPool.selector, fakePool));
        multiSwapTerminal.uniswapV3SwapCallback(int256(1e18), -int256(0.95e18), callbackData);
    }

    // ───────────────────────────────────────────────────────────────────
    //  accountingContextForTokenOf tests
    // ───────────────────────────────────────────────────────────────────

    function test_accountingContextForTokenOf_unconfiguredToken() public {
        address tokenIn = makeAddr("unconfiguredToken");

        JBAccountingContext memory context = multiSwapTerminal.accountingContextForTokenOf(1, tokenIn);

        assertEq(context.token, tokenIn);
        assertEq(context.decimals, 18);
        assertEq(context.currency, uint32(uint160(tokenIn)));
    }

    // ───────────────────────────────────────────────────────────────────
    //  TWAP fallback test (no user quote on auto-discovered pool)
    // ───────────────────────────────────────────────────────────────────

    function test_pay_autoDiscovery_revertsNoObservationHistory() public {
        // When no user quote and pool has no TWAP history, should revert
        address tokenIn = makeAddr("tokenIn");
        vm.etch(tokenIn, hex"00");
        uint256 projectId = 1;

        address pool = makeAddr("discoveredPool");
        vm.etch(pool, hex"00");

        // Factory has a pool at 3000
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, mockTokenOut, 3000)),
            abi.encode(pool)
        );
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, mockTokenOut, 500)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, mockTokenOut, 10_000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, mockTokenOut, 100)),
            abi.encode(address(0))
        );
        vm.mockCall(pool, abi.encodeCall(IUniswapV3PoolState.liquidity, ()), abi.encode(uint128(1000e18)));

        // Mock token transfer
        vm.mockCall(
            tokenIn, abi.encodeCall(IERC20.allowance, (address(this), address(multiSwapTerminal))), abi.encode(1e18)
        );
        vm.mockCall(
            tokenIn,
            abi.encodeCall(IERC20.transferFrom, (address(this), address(multiSwapTerminal), 1e18)),
            abi.encode(true)
        );
        vm.mockCall(tokenIn, abi.encodeCall(IERC20.balanceOf, (address(multiSwapTerminal))), abi.encode(uint256(0)));

        // Mock destination terminal
        vm.mockCall(
            address(mockJBDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, mockTokenOut)),
            abi.encode(IJBTerminal(makeAddr("destTerminal")))
        );

        // No quoteForSwap in metadata — triggers TWAP path
        // Pool mock has no observation data so OracleLibrary will revert
        vm.expectRevert(); // Will revert trying to read pool observations
        multiSwapTerminal.pay(projectId, tokenIn, 1e18, address(this), 0, "", "");
    }

    // ───────────────────────────────────────────────────────────────────
    //  DEFAULT_TWAP_WINDOW and FEE_TIERS constants
    // ───────────────────────────────────────────────────────────────────

    function test_constants() public view {
        assertEq(multiSwapTerminal.DEFAULT_TWAP_WINDOW(), 10 minutes);
        assertEq(multiSwapTerminal.FEE_TIERS(0), 3000);
        assertEq(multiSwapTerminal.FEE_TIERS(1), 500);
        assertEq(multiSwapTerminal.FEE_TIERS(2), 10_000);
        assertEq(multiSwapTerminal.FEE_TIERS(3), 100);
    }
}
