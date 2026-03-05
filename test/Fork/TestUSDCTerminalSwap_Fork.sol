// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "forge-std/Test.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBSwapTerminal, IUniswapV3Pool, IPermit2, IWETH9} from "src/JBSwapTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";

import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import "script/helpers/SwapTerminalDeploymentLib.sol";

contract TestUSDCTerminalSwap_Fork is Test {
    /// @notice tracks the deployment of the core contracts for the chain.
    CoreDeployment core;

    /// @notice tracks the deployment of the swap terminal contracts for the chain.
    JBSwapTerminal swapTerminal;

    // USDC contract address on base mainnet.
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // WETH contract address on base mainnet.
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // Uniswap factory on base mainnet.
    IUniswapV3Factory FACTORY = IUniswapV3Factory(0x33128a8fC17869897dcE68Ed026d694621f6FDfD);

    // USDC/ETH pool.
    IUniswapV3Pool constant POOL = IUniswapV3Pool(0xd0b53D9277642d899DF5C87A3966A349A798F224);

    // Main JBDAO multsig
    address manager = address(0x14293560A2dde4fFA136A647b7a2f927b0774AB6);

    IPermit2 permit2;

    uint256 projectId;

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        // Fork base sepolia.
        vm.createSelectFork("https://base.gateway.tenderly.co", 33_850_552);

        // Fetch the latest core deployments on this network.
        core = CoreDeploymentLib.getDeployment(
            vm.envOr("NANA_CORE_DEPLOYMENT_PATH", string("node_modules/@bananapus/core-v6/deployments/"))
        );

        // Get the permit2 that the multiterminal also makes use of.
        permit2 = core.terminal.PERMIT2();

        // Deploy a new swapTerminal that can take in ETH and output USDC.
        swapTerminal = new JBSwapTerminal({
            projects: core.projects,
            permissions: core.permissions,
            directory: core.directory,
            permit2: permit2,
            owner: address(manager),
            weth: IWETH9(WETH),
            tokenOut: USDC,
            factory: IUniswapV3Factory(FACTORY),
            trustedForwarder: address(0)
        });

        // Create a project that accepts USDC.
        projectId = _createProject();

        // Configure the pool
        vm.startPrank(manager);
        swapTerminal.addDefaultPool({projectId: 0, token: JBConstants.NATIVE_TOKEN, pool: POOL});
        swapTerminal.addTwapParamsFor({projectId: 0, pool: POOL, twapWindow: 2 minutes});
        vm.stopPrank();

        vm.label(address(USDC), "USDC");
        vm.label(address(WETH), "WETH");
        vm.label(address(this), "Pool");
    }

    function _createProject() internal returns (uint256 _projectId) {
        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: JBCurrencyIds.USD,
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            ownerMustSendPayouts: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: true,
            useDataHookForCashOut: true,
            dataHook: address(0),
            metadata: 0
        });

        // Package up ruleset configuration.
        JBRulesetConfig[] memory _rulesetConfig = new JBRulesetConfig[](1);
        _rulesetConfig[0].mustStartAtOrAfter = 0;
        _rulesetConfig[0].duration = 0;
        _rulesetConfig[0].weight = 10_000;
        _rulesetConfig[0].weightCutPercent = 0;
        _rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        _rulesetConfig[0].metadata = _metadata;
        _rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        _rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContext[] memory _tokensToAccept = new JBAccountingContext[](1);
        _tokensToAccept[0] = JBAccountingContext({token: USDC, decimals: 6, currency: uint32(uint160(USDC))});

        _terminalConfigurations[0] =
            JBTerminalConfig({terminal: core.terminal, accountingContextsToAccept: _tokensToAccept});

        _projectId = uint64(
            core.controller
                .launchProjectFor({
                    owner: address(manager),
                    projectUri: "myIPFSHash",
                    rulesetConfigurations: _rulesetConfig,
                    terminalConfigurations: _terminalConfigurations,
                    memo: ""
                })
        );
    }

    function testUSDCTerminalSwapPayment() public {
        vm.deal(0x289715fFBB2f4b482e2917D2f183FeAb564ec84F, 1 ether);
        vm.prank(0x289715fFBB2f4b482e2917D2f183FeAb564ec84F);
        IJBTerminal(address(swapTerminal)).pay{value: 1 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: 0x289715fFBB2f4b482e2917D2f183FeAb564ec84F,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }
}
