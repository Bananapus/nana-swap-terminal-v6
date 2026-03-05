// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "../helper/UnitFixture.sol";

contract JBSwapTerminaladdTwapParamsFor is UnitFixture {
    address caller;
    address projectOwner;

    IUniswapV3Pool pool;

    uint256 projectId = 1337;

    function setUp() public override {
        super.setUp();

        caller = makeAddr("caller");
        projectOwner = makeAddr("projectOwner");
        pool = IUniswapV3Pool(makeAddr("pool"));
    }

    modifier givenTheCallerIsAProjectOwner() {
        vm.mockCall(address(mockJBProjects), abi.encodeCall(IERC721.ownerOf, (projectId)), abi.encode(caller));

        vm.startPrank(caller);
        _;
    }

    function test_WhenSettingTwapParamsOfItsProject(uint32 secondsAgo) external givenTheCallerIsAProjectOwner {
        vm.assume(secondsAgo > swapTerminal.MIN_TWAP_WINDOW() && secondsAgo < swapTerminal.MAX_TWAP_WINDOW());

        swapTerminal.addTwapParamsFor(projectId, pool, secondsAgo);

        // it should add the twap params to the project
        uint256 twapSecondsAgo = swapTerminal.twapWindowOf(projectId, pool); // implicit

        assertEq(twapSecondsAgo, secondsAgo);
    }

    function test_RevertWhen_SettingTwapParamsToAnotherProject() external givenTheCallerIsAProjectOwner {
        mockExpectCall(
            address(mockJBProjects), abi.encodeCall(IERC721.ownerOf, (projectId + 1)), abi.encode(projectOwner)
        );

        uint32 secondsAgo = uint32(swapTerminal.MIN_TWAP_WINDOW());

        // Do not give specific or generic permission to the caller
        mockExpectCall(
            address(mockJBPermissions),
            abi.encodeCall(
                IJBPermissions.hasPermission,
                (caller, projectOwner, projectId + 1, JBPermissionIds.ADD_SWAP_TERMINAL_TWAP_PARAMS, true, true)
            ),
            abi.encode(false)
        );

        // it should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector, projectOwner, caller, projectId + 1, 29
            )
        );
        swapTerminal.addTwapParamsFor(projectId + 1, pool, secondsAgo);
    }

    modifier givenTheCallerIsNotAProjectOwner() {
        mockExpectCall(address(mockJBProjects), abi.encodeCall(IERC721.ownerOf, (projectId)), abi.encode(projectOwner));
        _;
    }

    function test_WhenTheCallerHasTheRole(uint32 secondsAgo) external givenTheCallerIsNotAProjectOwner {
        vm.assume(secondsAgo > swapTerminal.MIN_TWAP_WINDOW() && secondsAgo < swapTerminal.MAX_TWAP_WINDOW());

        // Give the permission to the caller
        mockExpectCall(
            address(mockJBPermissions),
            abi.encodeCall(
                IJBPermissions.hasPermission,
                (caller, projectOwner, projectId, JBPermissionIds.ADD_SWAP_TERMINAL_TWAP_PARAMS, true, true)
            ),
            abi.encode(true)
        );

        // Add the  twap params as permissioned caller
        vm.prank(caller);
        swapTerminal.addTwapParamsFor(projectId, pool, secondsAgo);

        // it should add the twap params to the project
        uint256 twapSecondsAgo = swapTerminal.twapWindowOf(projectId, pool); // implicit

        // upcast
        assertEq(twapSecondsAgo, secondsAgo);
    }

    function test_RevertWhen_TheCallerHasNoRole() external givenTheCallerIsNotAProjectOwner {
        uint32 secondsAgo = 100;

        // Do not give specific or generic permission to the caller
        mockExpectCall(
            address(mockJBPermissions),
            abi.encodeCall(
                IJBPermissions.hasPermission,
                (caller, projectOwner, projectId, JBPermissionIds.ADD_SWAP_TERMINAL_TWAP_PARAMS, true, true)
            ),
            abi.encode(false)
        );

        // it should revert
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector, projectOwner, caller, projectId, 29
            )
        );
        swapTerminal.addTwapParamsFor(projectId, pool, secondsAgo);
    }

    modifier givenTheCallerIsTheTerminalOwner() {
        caller = swapTerminal.owner();
        vm.startPrank(caller);
        _;
    }

    function test_WhenAddingDefaultParamsForAPool(
        uint256 _projectId,
        uint32 secondsAgo
    )
        external
        givenTheCallerIsTheTerminalOwner
    {
        vm.assume(_projectId != 0 && _projectId != projectId);

        vm.assume(secondsAgo > swapTerminal.MIN_TWAP_WINDOW() && secondsAgo < swapTerminal.MAX_TWAP_WINDOW());

        // Add the twap params as the terminal owner
        swapTerminal.addTwapParamsFor(0, pool, secondsAgo);

        // Add twap params for a specific project, as the project owner
        mockExpectCall(address(mockJBProjects), abi.encodeCall(IERC721.ownerOf, (projectId)), abi.encode(projectOwner));

        vm.stopPrank();
        vm.prank(projectOwner);
        swapTerminal.addTwapParamsFor(projectId, pool, secondsAgo > 1 ? secondsAgo - 1 : 2);

        // it should not be used if a project has specific twap params
        uint256 twapSecondsAgo = swapTerminal.twapWindowOf(projectId, pool);
        assertEq(twapSecondsAgo, secondsAgo > 1 ? secondsAgo - 1 : 2);

        // it should add the twap params to the project
        twapSecondsAgo = swapTerminal.twapWindowOf(_projectId, pool); // implicit upcast
        assertEq(twapSecondsAgo, secondsAgo);
    }

    function test_RevertWhen_SettingTheParamsOfAProject() external givenTheCallerIsTheTerminalOwner {
        uint32 secondsAgo = 100;

        // Do not give specific or generic permission to the caller
        mockExpectCall(
            address(mockJBPermissions),
            abi.encodeCall(
                IJBPermissions.hasPermission,
                (caller, projectOwner, projectId, JBPermissionIds.ADD_SWAP_TERMINAL_TWAP_PARAMS, true, true)
            ),
            abi.encode(false)
        );

        mockExpectCall(address(mockJBProjects), abi.encodeCall(IERC721.ownerOf, (projectId)), abi.encode(projectOwner));

        // it should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector, projectOwner, caller, projectId, 29
            )
        );
        swapTerminal.addTwapParamsFor(projectId, pool, secondsAgo);
    }
}
