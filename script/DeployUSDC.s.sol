// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Sphinx} from "@sphinx-labs/contracts/SphinxPlugin.sol";

import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {Script} from "forge-std/Script.sol";

import {
    IJBSwapTerminal,
    JBSwapTerminal,
    IUniswapV3Pool,
    IPermit2,
    IWETH9,
    IJBTerminal
} from "./../src/JBSwapTerminal.sol";

import {JBSwapTerminalRegistry} from "./../src/JBSwapTerminalRegistry.sol";

contract DeployUSDCScript is Script, Sphinx {
    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;

    /// @notice tracks the addresses that are required for the chain we are deploying to.
    address manager = address(0x80a8F7a4bD75b539CE26937016Df607fdC9ABeb5); // `nana-core-v6` multisig.
    address weth;
    address usdc;
    address factory;
    IPermit2 permit2;
    address trustedForwarder;

    uint256 constant ETHEREUM_MAINNET = 1;
    uint256 constant OPTIMISM_MAINNET = 10;
    uint256 constant BASE_MAINNET = 8453;
    uint256 constant ARBITRUM_MAINNET = 42_161;

    uint256 constant ETHEREUM_SEPOLIA = 11_155_111;
    uint256 constant OPTIMISM_SEPOLIA = 11_155_420;
    uint256 constant BASE_SEPOLIA = 84_532;
    uint256 constant ARBITRUM_SEPOLIA = 421_614;

    IJBSwapTerminal swapTerminal;

    /// @notice the salts that are used to deploy the contracts.
    bytes32 SWAP_TERMINAL = "JBSwapTerminalV6_";

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

        trustedForwarder = core.permissions.trustedForwarder();

        // Ethereum Mainnet
        if (block.chainid == 1) {
            usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
            weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
            factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
            // Ethereum Sepolia
        } else if (block.chainid == 11_155_111) {
            usdc = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
            weth = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
            factory = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
            // Optimism Mainnet
        } else if (block.chainid == 10) {
            usdc = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
            weth = 0x4200000000000000000000000000000000000006;
            factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
            // Base Mainnet
        } else if (block.chainid == 8453) {
            usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
            weth = 0x4200000000000000000000000000000000000006;
            factory = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
            // Optimism Sepolia
        } else if (block.chainid == 11_155_420) {
            usdc = 0x5fd84259d66Cd46123540766Be93DFE6D43130D7;
            weth = 0x4200000000000000000000000000000000000006;
            factory = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
            // Base sepolia
        } else if (block.chainid == 84_532) {
            usdc = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
            weth = 0x4200000000000000000000000000000000000006;
            factory = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
            // Arbitrum Mainnet
        } else if (block.chainid == 42_161) {
            usdc = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
            weth = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
            factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
            // Arbitrum Sepolia
        } else if (block.chainid == 421_614) {
            usdc = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
            weth = 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73;
            factory = 0x248AB79Bbb9bC29bB72f7Cd42F17e054Fc40188e;
        } else {
            revert("Invalid RPC / no juice contracts deployed on this network");
        }

        if (weth.code.length == 0) {
            // If the WETH contract is not deployed, we cannot continue.
            revert("WETH contract not deployed on this network, or invalid address.");
        }

        if (usdc.code.length == 0) {
            // If the USDC contract is not deployed, we cannot continue.
            revert("USDC contract not deployed on this network, or invalid address.");
        }

        // Perform the deployment transactions.
        deploy();
    }

    function deploy() public sphinx {
        JBSwapTerminalRegistry registry = new JBSwapTerminalRegistry{salt: SWAP_TERMINAL}(
            core.permissions, core.projects, permit2, safeAddress(), trustedForwarder
        );

        // Perform the deployment.
        swapTerminal = new JBSwapTerminal{salt: SWAP_TERMINAL}({
            projects: core.projects,
            permissions: core.permissions,
            directory: core.directory,
            permit2: permit2,
            owner: address(manager),
            weth: IWETH9(weth),
            tokenOut: usdc,
            factory: IUniswapV3Factory(factory),
            trustedForwarder: trustedForwarder
        });

        // Set the terminal as the default in the registry.
        registry.setDefaultTerminal(IJBTerminal(address(swapTerminal)));

        // USDC/ETH (0.05%)
        configurePairFor({
            chainId: ETHEREUM_MAINNET,
            token: JBConstants.NATIVE_TOKEN,
            pool: IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640),
            twapWindow: 2 minutes
        });

        // DAI/USDC (0.01%)
        configurePairFor({
            chainId: ETHEREUM_MAINNET,
            // DAI
            token: address(0x6B175474E89094C44Da98b954EedeAC495271d0F),
            pool: IUniswapV3Pool(0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168),
            twapWindow: 2 minutes
        });

        // USDC/USDT (0.01%)
        configurePairFor({
            chainId: ETHEREUM_MAINNET,
            // USDT
            token: address(0xdAC17F958D2ee523a2206206994597C13D831ec7),
            pool: IUniswapV3Pool(0x3416cF6C708Da44DB2624D63ea0AAef7113527C6),
            twapWindow: 30 minutes
        });

        // // USDe/USDC (0.01%)
        // configurePairFor({
        //     chainId: ETHEREUM_MAINNET,
        //     // USDe
        //     token: address(0x4c9EDD5852cd905f086C759E8383e09bff1E68B3),
        //     pool: IUniswapV3Pool(0xE6D7EbB9f1a9519dc06D557e03C522d53520e76A),
        //     twapWindow: 30 minutes,
        // });

        // USDC/ETH (0.05%)
        configurePairFor({
            chainId: ARBITRUM_MAINNET,
            token: JBConstants.NATIVE_TOKEN,
            pool: IUniswapV3Pool(0xC6962004f452bE9203591991D15f6b388e09E8D0),
            twapWindow: 2 minutes
        });

        // USDC/USDT (0.01%)
        configurePairFor({
            chainId: ARBITRUM_MAINNET,
            token: address(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9),
            pool: IUniswapV3Pool(0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6),
            twapWindow: 2 minutes
        });

        // USDC/ETH (0.05%)
        configurePairFor({
            chainId: BASE_MAINNET,
            token: JBConstants.NATIVE_TOKEN,
            pool: IUniswapV3Pool(0xd0b53D9277642d899DF5C87A3966A349A798F224),
            twapWindow: 2 minutes
        });

        // USDC/ETH (0.05%)
        configurePairFor({
            chainId: OPTIMISM_MAINNET,
            token: JBConstants.NATIVE_TOKEN,
            pool: IUniswapV3Pool(0x1fb3cf6e48F1E7B10213E7b6d87D4c073C7Fdb7b),
            twapWindow: 2 minutes
        });

        // Testnet pairs.
        // USDC/ETH (0.3%)
        configurePairFor({
            chainId: ETHEREUM_SEPOLIA,
            token: JBConstants.NATIVE_TOKEN,
            pool: IUniswapV3Pool(0xC31a3878E3B0739866F8fC52b97Ae9611aBe427c),
            twapWindow: 2 minutes
        });

        // USDC/ETH (0.3%)
        configurePairFor({
            chainId: BASE_SEPOLIA,
            token: JBConstants.NATIVE_TOKEN,
            pool: IUniswapV3Pool(0x46880b404CD35c165EDdefF7421019F8dD25F4Ad),
            twapWindow: 2 minutes
        });

        configurePairFor({
            chainId: OPTIMISM_SEPOLIA,
            token: JBConstants.NATIVE_TOKEN,
            pool: IUniswapV3Pool(0x8955C97261722d87D83D00708Bbe5f6B5b4477d6),
            twapWindow: 2 minutes
        });

        configurePairFor({
            chainId: ARBITRUM_SEPOLIA,
            token: JBConstants.NATIVE_TOKEN,
            pool: IUniswapV3Pool(0x66EEAB70aC52459Dd74C6AD50D578Ef76a441bbf),
            twapWindow: 2 minutes
        });
    }

    function configurePairFor(uint256 chainId, address token, IUniswapV3Pool pool, uint256 twapWindow) private {
        // No-op if the chainId does not match the current chain.
        if (block.chainid != chainId) {
            return;
        }

        // // Sanity check that the token is a deployed contract.
        // if (token.code.length == 0) {
        //     revert("Token address is not a contract.");
        // }

        // Sanity check that the pool is a deployed contract.
        if (address(pool).code.length == 0) {
            revert("Pool address is not a contract.");
        }

        // Add the pair to the swap terminal.
        swapTerminal.addDefaultPool({projectId: 0, token: token, pool: pool});
        swapTerminal.addTwapParamsFor({projectId: 0, pool: pool, twapWindow: twapWindow});
    }
}
