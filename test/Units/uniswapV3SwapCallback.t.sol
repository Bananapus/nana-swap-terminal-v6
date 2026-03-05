// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "../helper/UnitFixture.sol";

contract JBSwapTerminaluniswapV3SwapCallback is UnitFixture {
    using stdStorage for StdStorage;

    uint256 projectId = 1337;
    address token = makeAddr("token");
    IUniswapV3Pool pool = IUniswapV3Pool(makeAddr("pool"));

    function setUp() public override {
        super.setUp();

        swapTerminal = JBSwapTerminal(
            payable(new ForTest_SwapTerminal(
                    mockJBProjects,
                    mockJBPermissions,
                    mockJBDirectory,
                    mockPermit2,
                    makeAddr("owner"),
                    mockWETH,
                    mockTokenOut,
                    mockUniswapFactory
                ))
        );
    }

    modifier givenTheProjectHasAPoolToUse() {
        ForTest_SwapTerminal(payable(swapTerminal)).forTest_forceAddPool(projectId, token, pool);
        _;
    }

    function test_WhenTheCallerIsTheProjectPool() external givenTheProjectHasAPoolToUse {
        vm.mockCall(token, abi.encodeCall(IERC20.transfer, (address(pool), 0)), abi.encode(true));
        bytes memory data = abi.encode(projectId, token);

        // it should succeed
        vm.expectCall(token, abi.encodeCall(IERC20.transfer, (address(pool), 0)));

        vm.prank(address(pool));
        swapTerminal.uniswapV3SwapCallback(0, 0, data);
    }

    function test_RevertWhen_TheCallerIsNotTheProjectPool(address caller) external givenTheProjectHasAPoolToUse {
        vm.assume(caller != address(pool));

        bytes memory data = abi.encode(projectId, token);

        // it should revert
        vm.expectRevert(abi.encodeWithSelector(JBSwapTerminal.JBSwapTerminal_CallerNotPool.selector, caller));

        vm.prank(caller);
        swapTerminal.uniswapV3SwapCallback(0, 0, data);
    }

    modifier givenTheProjectHasNoPool() {
        ForTest_SwapTerminal(payable(swapTerminal)).forTest_forceAddPool(swapTerminal.DEFAULT_PROJECT_ID(), token, pool);
        _;
    }

    function test_WhenTheCallerIsTheDefaultPool() external givenTheProjectHasNoPool {
        vm.mockCall(token, abi.encodeCall(IERC20.transfer, (address(pool), 0)), abi.encode(true));
        bytes memory data = abi.encode(projectId, token);

        // it should succeed
        vm.expectCall(token, abi.encodeCall(IERC20.transfer, (address(pool), 0)));

        vm.prank(address(pool));
        swapTerminal.uniswapV3SwapCallback(0, 0, data);
    }

    function test_RevertWhen_TheCallerIsNotTheDefaultPool(address caller) external givenTheProjectHasNoPool {
        vm.assume(caller != address(pool));

        bytes memory data = abi.encode(projectId, token);

        // it should revert
        vm.expectRevert(abi.encodeWithSelector(JBSwapTerminal.JBSwapTerminal_CallerNotPool.selector, caller));

        vm.prank(caller);
        swapTerminal.uniswapV3SwapCallback(0, 0, data);
    }

    function test_WhenTheTokenToSendIsTheNativeToken() external {
        token = JBConstants.NATIVE_TOKEN;
        ForTest_SwapTerminal(payable(swapTerminal)).forTest_forceAddPool(projectId, address(mockWETH), pool);

        // it should wrap to weth
        vm.mockCall(address(mockWETH), abi.encodeCall(IWETH9.deposit, ()), "");
        vm.expectCall(address(mockWETH), abi.encodeCall(IWETH9.deposit, ()));

        // it should use weth as token to send to the pool
        vm.mockCall(address(mockWETH), abi.encodeCall(IERC20.transfer, (address(pool), 0)), abi.encode(true));
        vm.expectCall(address(mockWETH), abi.encodeCall(IERC20.transfer, (address(pool), 0)));

        vm.prank(address(pool));
        swapTerminal.uniswapV3SwapCallback(0, 0, abi.encode(projectId, token));
    }

    function test_WhenAmount0IsPositiveOrNull(int256 amountZero, int256 amountOne) external {
        amountZero = bound(amountZero, 0, type(int256).max);

        ForTest_SwapTerminal(payable(swapTerminal)).forTest_forceAddPool(projectId, token, pool);
        // Safely casted as bound to be positive
        vm.mockCall(token, abi.encodeCall(IERC20.transfer, (address(pool), uint256(amountZero))), abi.encode(true));
        bytes memory data = abi.encode(projectId, token);

        // it should send the amount0 of token to the pool
        vm.expectCall(token, abi.encodeCall(IERC20.transfer, (address(pool), uint256(amountZero))));

        vm.prank(address(pool));
        swapTerminal.uniswapV3SwapCallback(amountZero, amountOne, data);
    }

    /// @dev There is an underlying assertion on uniswap pool logic which is there can't be a situation where both
    /// amounts are negative (which would be having to pay both token)
    function test_WhenAmount0IsNegative(int256 amountZero, int256 amountOne) external {
        amountZero = bound(amountZero, type(int256).min, -1);
        amountOne = bound(amountOne, 0, type(int256).max);

        ForTest_SwapTerminal(payable(swapTerminal)).forTest_forceAddPool(projectId, token, pool);

        vm.mockCall(token, abi.encodeCall(IERC20.transfer, (address(pool), uint256(amountOne))), abi.encode(true));
        bytes memory data = abi.encode(projectId, token);

        // it should send the amount1 of token to the pool
        vm.expectCall(token, abi.encodeCall(IERC20.transfer, (address(pool), uint256(amountOne))));

        vm.prank(address(pool));
        swapTerminal.uniswapV3SwapCallback(amountZero, amountOne, data);
    }

    function test_WhenBothAmountsAre0() external {
        ForTest_SwapTerminal(payable(swapTerminal)).forTest_forceAddPool(projectId, token, pool);

        vm.mockCall(token, abi.encodeCall(IERC20.transfer, (address(pool), 0)), abi.encode(true));
        bytes memory data = abi.encode(projectId, token);

        // it should not transfer anything
        vm.expectCall(token, abi.encodeCall(IERC20.transfer, (address(pool), 0)));

        vm.prank(address(pool));
        swapTerminal.uniswapV3SwapCallback(0, 0, data);
    }
}

contract ForTest_SwapTerminal is JBSwapTerminal {
    constructor(
        IJBProjects projects,
        IJBPermissions permissions,
        IJBDirectory directory,
        IPermit2 permit2,
        address owner,
        IWETH9 weth,
        address tokenOut,
        IUniswapV3Factory uniswapFactory
    )
        JBSwapTerminal(directory, permissions, projects, permit2, owner, weth, tokenOut, uniswapFactory, address(0))
    {}

    function forTest_forceAddPool(uint256 projectId, address token, IUniswapV3Pool pool) public {
        _poolFor[projectId][token] = pool;
    }
}
