// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {JBSwapTerminalRegistry} from "../../../src/JBSwapTerminalRegistry.sol";

/// @notice Invariant handler for JBSwapTerminalRegistry.
contract RegistryHandler is CommonBase, StdCheats, StdUtils {
    JBSwapTerminalRegistry public immutable REGISTRY;
    address public immutable OWNER;

    // Terminals tracked by the handler.
    IJBTerminal[] public terminals;
    uint256[] public projectIds;

    // Ghost variables.
    uint256 public lockCount;
    mapping(uint256 => bool) public ghostLocked;

    constructor(
        JBSwapTerminalRegistry registry,
        address owner,
        IJBTerminal[] memory _terminals,
        uint256[] memory _projectIds
    ) {
        REGISTRY = registry;
        OWNER = owner;
        for (uint256 i; i < _terminals.length; i++) {
            terminals.push(_terminals[i]);
        }
        for (uint256 i; i < _projectIds.length; i++) {
            projectIds.push(_projectIds[i]);
        }
    }

    function allowTerminal(uint256 terminalSeed) public {
        IJBTerminal terminal = terminals[bound(terminalSeed, 0, terminals.length - 1)];
        vm.prank(OWNER);
        REGISTRY.allowTerminal(terminal);
    }

    function disallowTerminal(uint256 terminalSeed) public {
        IJBTerminal terminal = terminals[bound(terminalSeed, 0, terminals.length - 1)];
        vm.prank(OWNER);
        REGISTRY.disallowTerminal(terminal);
    }

    function setDefaultTerminal(uint256 terminalSeed) public {
        IJBTerminal terminal = terminals[bound(terminalSeed, 0, terminals.length - 1)];
        vm.prank(OWNER);
        REGISTRY.setDefaultTerminal(terminal);
    }

    function setTerminalFor(uint256 projectSeed, uint256 terminalSeed) public {
        uint256 projectId = projectIds[bound(projectSeed, 0, projectIds.length - 1)];
        IJBTerminal terminal = terminals[bound(terminalSeed, 0, terminals.length - 1)];

        // Only try if not locked.
        if (REGISTRY.hasLockedTerminal(projectId)) return;
        // Only try if terminal is allowed.
        if (!REGISTRY.isTerminalAllowed(terminal)) return;

        vm.prank(OWNER); // Owner has permission.
        try REGISTRY.setTerminalFor(projectId, terminal) {} catch {}
    }

    function lockTerminalFor(uint256 projectSeed) public {
        uint256 projectId = projectIds[bound(projectSeed, 0, projectIds.length - 1)];

        if (REGISTRY.hasLockedTerminal(projectId)) return;

        vm.prank(OWNER);
        try REGISTRY.lockTerminalFor(projectId) {
            ghostLocked[projectId] = true;
            lockCount++;
        } catch {}
    }
}
