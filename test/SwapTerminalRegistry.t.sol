// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "forge-std/Test.sol";

import "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import "src/JBSwapTerminalRegistry.sol";

/// @notice Unit tests for `JBSwapTerminalRegistry`.
contract Test_SwapTerminalRegistry_Unit is Test {
    JBSwapTerminalRegistry registry;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IPermit2 permit2 = IPermit2(makeAddr("permit2"));
    address owner = makeAddr("owner");
    address trustedForwarder = makeAddr("forwarder");

    address dude = makeAddr("dude");
    address projectOwner = makeAddr("projectOwner");

    uint256 projectId = 42;

    // Two mock terminals.
    IJBTerminal terminalA = IJBTerminal(makeAddr("terminalA"));
    IJBTerminal terminalB = IJBTerminal(makeAddr("terminalB"));

    // Events (from IJBSwapTerminalRegistry).
    event JBSwapTerminalRegistry_AllowTerminal(IJBTerminal terminal);
    event JBSwapTerminalRegistry_DisallowTerminal(IJBTerminal terminal);
    event JBSwapTerminalRegistry_SetDefaultTerminal(IJBTerminal terminal);
    event JBSwapTerminalRegistry_SetTerminal(uint256 indexed projectId, IJBTerminal terminal);
    event JBSwapTerminalRegistry_LockTerminal(uint256 indexed projectId);

    function setUp() public {
        registry = new JBSwapTerminalRegistry(permissions, projects, permit2, owner, trustedForwarder);

        // Mock PROJECTS.ownerOf to return projectOwner for the test project.
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, projectId), abi.encode(projectOwner)
        );

        // Mock permissions to return true by default (for authorized calls).
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );
    }

    //*********************************************************************//
    // --- Constructor --------------------------------------------------- //
    //*********************************************************************//

    function test_constructor() public view {
        assertEq(address(registry.PROJECTS()), address(projects), "PROJECTS should be set");
        assertEq(registry.owner(), owner, "owner should be set");
    }

    //*********************************************************************//
    // --- allowTerminal ------------------------------------------------- //
    //*********************************************************************//

    function test_allowTerminal_setsAllowed() public {
        assertFalse(registry.isTerminalAllowed(terminalA), "terminalA should not be allowed initially");

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit JBSwapTerminalRegistry_AllowTerminal(terminalA);
        registry.allowTerminal(terminalA);

        assertTrue(registry.isTerminalAllowed(terminalA), "terminalA should be allowed");
    }

    function test_allowTerminal_revertsIfNotOwner() public {
        vm.prank(dude);
        vm.expectRevert();
        registry.allowTerminal(terminalA);
    }

    //*********************************************************************//
    // --- disallowTerminal ---------------------------------------------- //
    //*********************************************************************//

    function test_disallowTerminal_clearsAllowed() public {
        vm.prank(owner);
        registry.allowTerminal(terminalA);
        assertTrue(registry.isTerminalAllowed(terminalA));

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit JBSwapTerminalRegistry_DisallowTerminal(terminalA);
        registry.disallowTerminal(terminalA);

        assertFalse(registry.isTerminalAllowed(terminalA), "terminalA should be disallowed");
    }

    //*********************************************************************//
    // --- setDefaultTerminal -------------------------------------------- //
    //*********************************************************************//

    function test_setDefaultTerminal() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit JBSwapTerminalRegistry_SetDefaultTerminal(terminalA);
        registry.setDefaultTerminal(terminalA);

        assertEq(address(registry.defaultTerminal()), address(terminalA), "defaultTerminal should be terminalA");
        assertTrue(registry.isTerminalAllowed(terminalA), "setDefaultTerminal should also allow the terminal");
    }

    function test_setDefaultTerminal_revertsIfNotOwner() public {
        vm.prank(dude);
        vm.expectRevert();
        registry.setDefaultTerminal(terminalA);
    }

    //*********************************************************************//
    // --- setTerminalFor ------------------------------------------------ //
    //*********************************************************************//

    function test_setTerminalFor() public {
        vm.prank(owner);
        registry.allowTerminal(terminalA);

        vm.prank(projectOwner);
        vm.expectEmit(true, false, false, true);
        emit JBSwapTerminalRegistry_SetTerminal(projectId, terminalA);
        registry.setTerminalFor(projectId, terminalA);

        assertEq(address(registry.terminalOf(projectId)), address(terminalA), "terminalOf should be terminalA");
    }

    function test_setTerminalFor_revertsIfLocked() public {
        vm.prank(owner);
        registry.allowTerminal(terminalA);
        vm.prank(projectOwner);
        registry.setTerminalFor(projectId, terminalA);

        vm.prank(projectOwner);
        registry.lockTerminalFor(projectId);

        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(JBSwapTerminalRegistry.JBSwapTerminalRegistry_TerminalLocked.selector, projectId)
        );
        registry.setTerminalFor(projectId, terminalB);
    }

    function test_setTerminalFor_revertsIfNotAllowed() public {
        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(JBSwapTerminalRegistry.JBSwapTerminalRegistry_TerminalNotAllowed.selector, terminalA)
        );
        registry.setTerminalFor(projectId, terminalA);
    }

    //*********************************************************************//
    // --- lockTerminalFor ----------------------------------------------- //
    //*********************************************************************//

    function test_lockTerminalFor() public {
        vm.prank(owner);
        registry.allowTerminal(terminalA);
        vm.prank(projectOwner);
        registry.setTerminalFor(projectId, terminalA);

        assertFalse(registry.hasLockedTerminal(projectId), "should not be locked initially");

        vm.prank(projectOwner);
        registry.lockTerminalFor(projectId);

        assertTrue(registry.hasLockedTerminal(projectId), "should be locked");
    }

    function test_lockTerminalFor_locksInDefault() public {
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        // No project-specific terminal set. terminalOf should already return the default.
        assertEq(
            address(registry.terminalOf(projectId)), address(terminalA), "terminalOf should return default before lock"
        );

        vm.prank(projectOwner);
        registry.lockTerminalFor(projectId);

        assertEq(address(registry.terminalOf(projectId)), address(terminalA), "lockTerminalFor should copy default");
        assertTrue(registry.hasLockedTerminal(projectId), "should be locked");
    }

    //*********************************************************************//
    // --- terminalOf default fallback ----------------------------------- //
    //*********************************************************************//

    function test_terminalOf_returnsDefaultWhenNoProjectTerminal() public {
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        // No project-specific terminal set — terminalOf should return the default.
        assertEq(
            address(registry.terminalOf(projectId)), address(terminalA), "terminalOf should return defaultTerminal"
        );
    }

    function test_terminalOf_returnsProjectTerminalOverDefault() public {
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        vm.prank(owner);
        registry.allowTerminal(terminalB);
        vm.prank(projectOwner);
        registry.setTerminalFor(projectId, terminalB);

        assertEq(
            address(registry.terminalOf(projectId)), address(terminalB), "terminalOf should prefer project terminal"
        );
    }

    function test_terminalOf_returnsZeroWhenNoDefaultAndNoProjectTerminal() public view {
        // No default, no project terminal → address(0).
        assertEq(
            address(registry.terminalOf(projectId)), address(0), "terminalOf should be address(0) with no terminals"
        );
    }

    //*********************************************************************//
    // --- Terminal Switching --------------------------------------------- //
    //*********************************************************************//

    function test_switchTerminal() public {
        vm.startPrank(owner);
        registry.allowTerminal(terminalA);
        registry.allowTerminal(terminalB);
        vm.stopPrank();

        vm.prank(projectOwner);
        registry.setTerminalFor(projectId, terminalA);
        assertEq(address(registry.terminalOf(projectId)), address(terminalA));

        vm.prank(projectOwner);
        registry.setTerminalFor(projectId, terminalB);
        assertEq(address(registry.terminalOf(projectId)), address(terminalB));
    }

    //*********************************************************************//
    // --- supportsInterface --------------------------------------------- //
    //*********************************************************************//

    function test_supportsInterface() public view {
        assertTrue(registry.supportsInterface(type(IJBTerminal).interfaceId), "should support IJBTerminal");
        assertTrue(registry.supportsInterface(type(IERC165).interfaceId), "should support IERC165");
    }
}
