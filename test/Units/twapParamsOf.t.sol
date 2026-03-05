// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "../helper/UnitFixture.sol";

contract JBSwapTerminaltwapParamsOf is UnitFixture {
    uint256 projectId = 1337;
    IUniswapV3Pool pool;

    function setUp() public override {
        super.setUp();

        pool = IUniswapV3Pool(makeAddr("pool"));

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

    function test_WhenThereIsATwapWindow(uint192 window) external {
        ForTest_SwapTerminal(payable(swapTerminal)).forTest_forceAddTwapWindow(projectId, pool, window);

        // it should return the params
        uint256 secondsAgo = swapTerminal.twapWindowOf(projectId, pool);

        assertEq(secondsAgo, window);
    }

    modifier whenThereAreNoTwapParamsForTheProject() {
        _;
    }

    function test_WhenThereAreDefaultParamForThePool(uint192 window) external whenThereAreNoTwapParamsForTheProject {
        ForTest_SwapTerminal(payable(swapTerminal))
            .forTest_forceAddTwapWindow(swapTerminal.DEFAULT_PROJECT_ID(), pool, window);

        // it should return the default params
        uint256 secondsAgo = swapTerminal.twapWindowOf(projectId, pool);

        assertEq(secondsAgo, window);
    }

    function test_WhenThereAreNoDefaultParamForThePool() external view whenThereAreNoTwapParamsForTheProject {
        // it should return empty values
        uint256 secondsAgo = swapTerminal.twapWindowOf(projectId, pool);

        assertEq(secondsAgo, 0);
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

    function forTest_forceAddTwapWindow(uint256 projectId, IUniswapV3Pool pool, uint256 window) public {
        _twapWindowOf[projectId][pool] = window;
    }
}
