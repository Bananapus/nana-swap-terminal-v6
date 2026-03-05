// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {stdJson} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {IJBSwapTerminal} from "../../src/interfaces/IJBSwapTerminal.sol";
import {IJBSwapTerminalRegistry} from "../../src/interfaces/IJBSwapTerminalRegistry.sol";

import {SphinxConstants, NetworkInfo} from "@sphinx-labs/contracts/SphinxConstants.sol";

struct SwapTerminalDeployment {
    IJBSwapTerminalRegistry native_registry;
    IJBSwapTerminalRegistry usdc_registry;
    /// @deprecated
    IJBSwapTerminal swap_terminal;
}

library SwapTerminalDeploymentLib {
    // Cheat code address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    function getDeployment(string memory path) internal returns (SwapTerminalDeployment memory deployment) {
        // get chainId for which we need to get the deployment.
        uint256 chainId = block.chainid;

        // Deploy to get the constants.
        // TODO: get constants without deploy.
        SphinxConstants sphinxConstants = new SphinxConstants();
        NetworkInfo[] memory networks = sphinxConstants.getNetworkInfoArray();

        for (uint256 _i; _i < networks.length; _i++) {
            if (networks[_i].chainId == chainId) {
                return getDeployment(path, networks[_i].name);
            }
        }

        revert("ChainID is not (currently) supported by Sphinx.");
    }

    function getDeployment(
        string memory path,
        string memory network_name
    )
        internal
        view
        returns (SwapTerminalDeployment memory deployment)
    {
        deployment.native_registry = IJBSwapTerminalRegistry(
            payable(_getDeploymentAddress(path, "nana-swap-terminal-v6", network_name, "JBSwapTerminalRegistry"))
        );

        deployment.usdc_registry = IJBSwapTerminalRegistry(
            payable(_getDeploymentAddress(path, "nana-swap-terminal-v6", network_name, "JBSwapTerminalUSDCRegistry"))
        );
    }

    /// @notice Get the address of a contract that was deployed by the Deploy script.
    /// @dev Reverts if the contract was not found.
    /// @param path The path to the deployment file.
    /// @param contractName The name of the contract to get the address of.
    /// @return The address of the contract.
    function _getDeploymentAddress(
        string memory path,
        string memory project_name,
        string memory network_name,
        string memory contractName
    )
        internal
        view
        returns (address)
    {
        string memory deploymentJson =
            vm.readFile(string.concat(path, project_name, "/", network_name, "/", contractName, ".json"));
        return stdJson.readAddress(deploymentJson, ".address");
    }
}
