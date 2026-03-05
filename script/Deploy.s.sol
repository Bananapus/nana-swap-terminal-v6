// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Sphinx} from "@sphinx-labs/contracts/SphinxPlugin.sol";

import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {Script} from "forge-std/Script.sol";

import {JBSwapTerminal, IPermit2, IWETH9} from "./../src/JBSwapTerminal.sol";
import {JBSwapTerminalRegistry} from "./../src/JBSwapTerminalRegistry.sol";

contract DeployScript is Script, Sphinx {
    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;

    /// @notice tracks the addresses that are required for the chain we are deploying to.
    address manager = address(0x80a8F7a4bD75b539CE26937016Df607fdC9ABeb5); // `nana-core-v6` multisig.
    address weth;
    address factory;
    address trustedForwarder;
    IPermit2 permit2;

    /// @notice the salts that are used to deploy the contracts.
    bytes32 SWAP_TERMINAL = "JBSwapTerminalV6";

    function configureSphinx() public override {
        sphinxConfig.projectName = "nana-swap-terminal-v6";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];
        sphinxConfig.testnets = ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia"];
    }

    function run() public {
        // Get the deployment addresses for the nana CORE for this chain.
        // We want to do this outside of the `sphinx` modifier.
        core = CoreDeploymentLib.getDeployment(
            vm.envOr("NANA_CORE_DEPLOYMENT_PATH", string("node_modules/@bananapus/core-v6/deployments/"))
        );

        // Get the permit2 that the multiterminal also makes use of.
        permit2 = core.terminal.PERMIT2();

        // We use the same trusted forwarder as the core deployment.
        trustedForwarder = core.permissions.trustedForwarder();

        // Ethereum Mainnet
        if (block.chainid == 1) {
            weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
            factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
            // Ethereum Sepolia
        } else if (block.chainid == 11_155_111) {
            weth = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
            factory = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
            // Optimism Mainnet
        } else if (block.chainid == 10) {
            weth = 0x4200000000000000000000000000000000000006;
            factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
            // Base Mainnet
        } else if (block.chainid == 8453) {
            weth = 0x4200000000000000000000000000000000000006;
            factory = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
            // Optimism Sepolia
        } else if (block.chainid == 11_155_420) {
            weth = 0x4200000000000000000000000000000000000006;
            factory = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
            // Base sepolia
        } else if (block.chainid == 84_532) {
            weth = 0x4200000000000000000000000000000000000006;
            factory = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
            // Arbitrum Mainnet
        } else if (block.chainid == 42_161) {
            weth = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
            factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
            // Arbitrum Sepolia
        } else if (block.chainid == 421_614) {
            weth = 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73;
            factory = 0x248AB79Bbb9bC29bB72f7Cd42F17e054Fc40188e;
        } else {
            revert("Invalid RPC / no juice contracts deployed on this network");
        }

        // Perform the deployment transactions.
        deploy();
    }

    function deploy() public sphinx {
        JBSwapTerminalRegistry registry = new JBSwapTerminalRegistry{salt: SWAP_TERMINAL}(
            core.permissions, core.projects, permit2, safeAddress(), trustedForwarder
        );

        // Perform the deployment.
        JBSwapTerminal nativeTerminal = new JBSwapTerminal{salt: SWAP_TERMINAL}({
            projects: core.projects,
            permissions: core.permissions,
            directory: core.directory,
            permit2: permit2,
            owner: address(manager),
            weth: IWETH9(weth),
            tokenOut: JBConstants.NATIVE_TOKEN,
            factory: IUniswapV3Factory(factory),
            trustedForwarder: trustedForwarder
        });

        // Set the terminal as the default in the registry.
        registry.setDefaultTerminal(nativeTerminal);
    }

    function _isDeployed(bytes32 salt, bytes memory creationCode, bytes memory arguments) internal view returns (bool) {
        address _deployedTo = vm.computeCreate2Address({
            salt: salt,
            initCodeHash: keccak256(abi.encodePacked(creationCode, arguments)),
            // Arachnid/deterministic-deployment-proxy address.
            deployer: address(0x4e59b44847b379578588920cA78FbF26c0B4956C)
        });

        // Return if code is already present at this address.
        return address(_deployedTo).code.length != 0;
    }
}
