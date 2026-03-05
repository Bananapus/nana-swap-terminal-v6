// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {UniswapV3ForgeQuoter} from "@exhausted-pigeon/uniswap-v3-foundry-quote/src/UniswapV3ForgeQuoter.sol";

import {PoolTestHelper} from "@exhausted-pigeon/uniswap-v3-foundry-pool/src/PoolTestHelper.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../src/JBSwapTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

import {MetadataResolverHelper} from "@bananapus/core-v6/test/helpers/MetadataResolverHelper.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";

import {JBTokens} from "@bananapus/core-v6/src/JBTokens.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";

import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";

import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";

import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";

import {MockERC20} from "../helper/MockERC20.sol";

import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";

import "forge-std/Test.sol";

/// @notice Swap terminal test on a Sepolia fork
contract TestSwapTerminal_Fork is Test {
    using JBRulesetMetadataResolver for JBRuleset;

    /// @notice tracks the deployment of the core contracts for the chain.
    CoreDeployment core;

    IERC20 constant UNI = IERC20(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984);
    IWETH9 constant WETH = IWETH9(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14);
    IUniswapV3Pool constant POOL = IUniswapV3Pool(0x287B0e934ed0439E2a7b1d5F0FC25eA2c24b64f7);

    IUniswapV3Factory constant factory = IUniswapV3Factory(0x0227628f3F023bb0B980b67D528571c95c6DaC1c);

    IUniswapV3Pool internal _otherTokenPool;

    JBSwapTerminal internal _swapTerminal;
    JBMultiTerminal internal _projectTerminal;
    JBTokens internal _tokens;
    IJBProjects internal _projects;
    IJBPermissions internal _permissions;
    IJBDirectory internal _directory;
    IPermit2 internal _permit2;
    IJBController internal _controller;
    IJBTerminalStore internal _terminalStore;

    MetadataResolverHelper internal _metadataResolver;
    UniswapV3ForgeQuoter internal _uniswapV3ForgeQuoter;

    address internal _owner = makeAddr("owner");
    address internal _sender = makeAddr("sender");
    address internal _beneficiary = makeAddr("beneficiary");
    address internal _projectOwner;

    uint256 internal _projectId = 2;

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(vm.rpcUrl("ethereum_sepolia"), 7_638_426);

        vm.label(address(UNI), "UNI");
        vm.label(address(WETH), "WETH");
        vm.label(address(POOL), "POOL");

        // Fetch the latest core deployments on this network
        core = CoreDeploymentLib.getDeployment(
            vm.envOr("NANA_CORE_DEPLOYMENT_PATH", string("node_modules/@bananapus/core-v6/deployments/"))
        );

        _controller = core.controller;
        vm.label(address(_controller), "controller");

        _projects = core.projects;
        vm.label(address(_projects), "projects");

        _permissions = core.permissions;
        vm.label(address(_permissions), "permissions");

        _directory = core.directory;
        vm.label(address(_directory), "directory");

        _permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
        vm.label(address(_permit2), "permit2");

        _tokens = core.tokens;
        vm.label(address(_tokens), "tokens");

        _terminalStore = core.terminalStore;
        vm.label(address(_terminalStore), "terminalStore");

        _projectTerminal = core.terminal;
        vm.label(address(_projectTerminal), "projectTerminal");

        _projectOwner = _projects.ownerOf(_projectId);
        vm.label(_projectOwner, "projectOwner");

        _swapTerminal = new JBSwapTerminal(
            _directory, _permissions, _projects, _permit2, _owner, WETH, JBConstants.NATIVE_TOKEN, factory, address(0)
        );
        vm.label(address(_swapTerminal), "swapTerminal");

        _metadataResolver = new MetadataResolverHelper();
        vm.label(address(_metadataResolver), "metadataResolver");

        _uniswapV3ForgeQuoter = new UniswapV3ForgeQuoter();
        vm.label(address(_uniswapV3ForgeQuoter), "uniswapV3ForgeQuoter");
    }

    /// @notice Test paying a swap terminal in UNI to contribute to JuiceboxDAO project (in the eth terminal), using
    /// metadata
    /// @dev    Quote at the forked block 5022528 : 1 UNI = 1.33649 ETH with max slippage suggested (uni sdk): 0.5%
    function testPayUniSwapEthPayEth(uint256 _amountIn) external {
        _amountIn = bound(_amountIn, 1 ether, 10 ether);

        deal(address(UNI), address(_sender), _amountIn);

        uint256 _initialTerminalBalance =
            _terminalStore.balanceOf(address(_projectTerminal), _projectId, JBConstants.NATIVE_TOKEN);
        uint256 _initialBeneficiaryBalance = _tokens.totalBalanceOf(_beneficiary, _projectId);

        uint256 _minAmountOut = _uniswapV3ForgeQuoter.getAmountOut(POOL, _amountIn, address(UNI));

        vm.prank(_projectOwner);
        _swapTerminal.addDefaultPool(_projectId, address(UNI), POOL);

        // Build the metadata using the minimum amount out, the pool address and if it's a zero to one swap
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(_minAmountOut, address(POOL), address(UNI) < address(WETH));

        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = _metadataResolver.getId("quoteForSwap", address(_swapTerminal));

        bytes memory _metadata = _metadataResolver.createMetadata(_ids, _data);

        // Approve the transfer
        vm.startPrank(_sender);
        UNI.approve(address(_swapTerminal), _amountIn);

        // Make a payment.
        _swapTerminal.pay({
            projectId: _projectId,
            amount: _amountIn,
            token: address(UNI),
            beneficiary: _beneficiary,
            minReturnedTokens: 1,
            memo: "Take my money!",
            metadata: _metadata
        });

        // Make sure the beneficiary has a balance of project tokens
        uint256 _weight = _terminalStore.RULESETS().currentOf(_projectId).weight;
        uint256 _reservedRate = _terminalStore.RULESETS().currentOf(_projectId).reservedPercent();
        uint256 _totalMinted = _weight * _minAmountOut / 1 ether;
        uint256 _reservedToken = _totalMinted * _reservedRate / JBConstants.MAX_RESERVED_PERCENT;

        // 1 wei delta for rounding
        assertApproxEqAbs(
            _tokens.totalBalanceOf(_beneficiary, _projectId),
            _initialBeneficiaryBalance + _totalMinted - _reservedToken,
            1
        );

        // Make sure the native token balance in terminal is up to date.
        uint256 _terminalBalance = _minAmountOut + _initialTerminalBalance;
        assertEq(
            _terminalStore.balanceOf(address(_projectTerminal), _projectId, JBConstants.NATIVE_TOKEN), _terminalBalance
        );
    }

    /// @notice Test paying a swap terminal in UNI to contribute to JuiceboxDAO project (in the eth terminal), using
    /// a twap
    /// @dev    Quote at the forked block 5022528 : 1 UNI = 1.33649 ETH with max slippage suggested (uni sdk): 0.5%
    function testPayUniSwapEthPayEthTwap(uint256 _amountIn) external {
        _amountIn = bound(_amountIn, 0.01 ether, 1 ether);

        deal(address(UNI), address(_sender), _amountIn);

        uint256 _initialTerminalBalance =
            _terminalStore.balanceOf(address(_projectTerminal), _projectId, JBConstants.NATIVE_TOKEN);
        uint256 _initialBeneficiaryBalance = _tokens.totalBalanceOf(_beneficiary, _projectId);

        uint256 _minAmountOut = _uniswapV3ForgeQuoter.getAmountOut(POOL, _amountIn, address(UNI));

        vm.prank(_projectOwner);
        _swapTerminal.addDefaultPool(_projectId, address(UNI), POOL);

        vm.prank(_projectOwner);
        _swapTerminal.addTwapParamsFor({projectId: _projectId, pool: POOL, twapWindow: 120});

        bytes memory _metadata = "";

        // Approve the transfer
        vm.startPrank(_sender);
        UNI.approve(address(_swapTerminal), _amountIn);

        // Make a payment.
        _swapTerminal.pay({
            projectId: _projectId,
            amount: _amountIn,
            token: address(UNI),
            beneficiary: _beneficiary,
            minReturnedTokens: 1,
            memo: "Take my money!",
            metadata: _metadata
        });

        // Make sure the beneficiary has a balance of project tokens
        uint256 _weight = _terminalStore.RULESETS().currentOf(_projectId).weight;
        uint256 _reservedRate = _terminalStore.RULESETS().currentOf(_projectId).reservedPercent();
        uint256 _totalMinted = _weight * _minAmountOut / 1 ether;
        uint256 _reservedToken = _totalMinted * _reservedRate / JBConstants.MAX_RESERVED_PERCENT;

        // 1 wei delta for rounding
        assertApproxEqAbs(
            _tokens.totalBalanceOf(_beneficiary, _projectId),
            _initialBeneficiaryBalance + _totalMinted - _reservedToken,
            1
        );

        // Make sure the native token balance in terminal is up to date.
        uint256 _terminalBalance = _minAmountOut + _initialTerminalBalance;
        assertEq(
            _terminalStore.balanceOf(address(_projectTerminal), _projectId, JBConstants.NATIVE_TOKEN), _terminalBalance
        );
    }

    /// @notice Test paying a swap terminal in UNI to contribute to JuiceboxDAO project (in the eth terminal), using
    /// a twap
    /// @dev    Quote at the forked block 5022528 : 1 UNI = 1.33649 ETH with max slippage suggested (uni sdk): 0.5%
    function testPayUniSwapEthPayEthTwapRevert() external {
        uint256 _amountIn = 10 ether; // hyper inflate the price to create a high slippage

        deal(address(UNI), address(_sender), _amountIn);

        _uniswapV3ForgeQuoter.getAmountOut(POOL, _amountIn, address(UNI));

        vm.prank(_projectOwner);
        _swapTerminal.addDefaultPool(_projectId, address(UNI), POOL);

        vm.prank(_projectOwner);
        _swapTerminal.addTwapParamsFor({projectId: _projectId, pool: POOL, twapWindow: 120});

        bytes memory _metadata = "";

        // Approve the transfer
        vm.startPrank(_sender);
        UNI.approve(address(_swapTerminal), _amountIn);

        // Funny value
        vm.expectPartialRevert(JBSwapTerminal.JBSwapTerminal_SpecifiedSlippageExceeded.selector);

        // Make a payment.
        _swapTerminal.pay({
            projectId: _projectId,
            amount: _amountIn,
            token: address(UNI),
            beneficiary: _beneficiary,
            minReturnedTokens: 1,
            memo: "Take my money!",
            metadata: _metadata
        });
    }

    /* /// @notice Test paying a swap terminal in another token, which has an address either bigger or smaller than UNI
    ///         to test the opposite pool token ordering
    function testPayAndSwapOtherTokenOrder(uint256 _amountIn) external {
        //@TODO: Create another solution for this given PoolTestHelper is causing proptest error.
        _amountIn = bound(_amountIn, 1 ether, 10 ether);

        deal(address(_otherTokenIn), address(_sender), _amountIn);

        uint256 _initialTerminalBalance =
            _terminalStore.balanceOf(address(_projectTerminal), _projectId, JBConstants.NATIVE_TOKEN);
        uint256 _initialBeneficiaryBalance = _tokens.totalBalanceOf(_beneficiary, _projectId);

    uint256 _minAmountOut = _uniswapV3ForgeQuoter.getAmountOut(_otherTokenPool, _amountIn, address(_otherTokenIn));

        vm.prank(_projectOwner);
        _swapTerminal.addDefaultPool(_projectId, address(_otherTokenIn), _otherTokenPool);

        // Build the metadata using the minimum amount out, the pool address and the token out address
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(_minAmountOut, address(_otherTokenPool), address(_otherTokenIn) < address(WETH));

        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = _metadataResolver.getId("quoteForSwap", address(_swapTerminal));

        bytes memory _metadata = _metadataResolver.createMetadata(_ids, _data);

        // Approve the transfer
        vm.startPrank(_sender);
        _otherTokenIn.approve(address(_swapTerminal), _amountIn);

        // Make a payment.
        _swapTerminal.pay({
            projectId: _projectId,
            amount: _amountIn,
            token: address(_otherTokenIn),
            beneficiary: _beneficiary,
            minReturnedTokens: 1,
            memo: "Take my money!",
            metadata: _metadata
        });

        // Make sure the beneficiary has a balance of project tokens
        uint256 _weight = _terminalStore.RULESETS().currentOf(_projectId).weight;
        uint256 _reservedRate = _terminalStore.RULESETS().currentOf(_projectId).reservedPercent();
        uint256 _totalMinted = _weight * _minAmountOut / 1 ether;
        uint256 _reservedToken = _totalMinted * _reservedRate / JBConstants.MAX_RESERVED_PERCENT;

        // 1 wei delta for rounding
        assertApproxEqAbs(
            _tokens.totalBalanceOf(_beneficiary, _projectId),
            _initialBeneficiaryBalance + _totalMinted - _reservedToken,
            1
        );

        // Make sure the native token balance in terminal is up to date.
        uint256 _terminalBalance = _minAmountOut + _initialTerminalBalance;
        assertEq(
    _terminalStore.balanceOf(address(_projectTerminal), _projectId, JBConstants.NATIVE_TOKEN), _terminalBalance
        );
    } */

    /// @notice Test paying a swap terminal in UNI to contribute to JuiceboxDAO project (in the eth terminal), using
    /// metadata
    /// @dev    Quote at the forked block 5022528 : 1 UNI = 1.33649 ETH with max slippage suggested (uni sdk): 0.5%
    function testAddToBalanceOfUniSwapEthPayEth(uint256 _amountIn) external {
        _amountIn = bound(_amountIn, 1 ether, 10 ether);

        deal(address(UNI), address(_sender), _amountIn);

        uint256 _minAmountOut = _uniswapV3ForgeQuoter.getAmountOut(POOL, _amountIn, address(UNI));

        vm.prank(_projectOwner);
        _swapTerminal.addDefaultPool(_projectId, address(UNI), POOL);

        // Build the metadata using the minimum amount out, the pool address and if it's a zero to one swap
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(_minAmountOut, address(POOL), address(UNI) < address(WETH));

        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = _metadataResolver.getId("quoteForSwap", address(_swapTerminal));

        bytes memory _metadata = _metadataResolver.createMetadata(_ids, _data);

        // Approve the transfer
        vm.startPrank(_sender);
        UNI.approve(address(_swapTerminal), _amountIn);

        uint256 _previousTotalSupply = _tokens.totalSupplyOf(_projectId);

        // Make a payment.
        _swapTerminal.addToBalanceOf({
            projectId: _projectId,
            amount: _amountIn,
            token: address(UNI),
            shouldReturnHeldFees: false,
            memo: "Take my money!",
            metadata: _metadata
        });

        // Make sure the project token total supply hasn't changed
        assertEq(_previousTotalSupply, _tokens.totalSupplyOf(_projectId));

        /* // Make sure the native token balance in terminal is up to date.
        uint256 _terminalBalance = _minAmountOut + _initialTerminalBalance;
        assertEq(
        _terminalStore.balanceOf(address(_projectTerminal), _projectId, JBConstants.NATIVE_TOKEN), _terminalBalance
        ); */
    }

    /// @notice Test setting a new pool for a project using the protocol owner address or the project owner address
    function testProtocolOwnerSetsNewPool() external {
        vm.prank(_swapTerminal.owner());
        _swapTerminal.addDefaultPool(0, address(UNI), POOL);

        (IUniswapV3Pool pool, bool zeroToOne) = _swapTerminal.getPoolFor(_projectId, address(UNI));

        assertEq(address(pool), address(POOL));
        assertEq(zeroToOne, address(UNI) < address(WETH));

        // Use another fee tier
        address newPool = factory.getPool(address(UNI), address(WETH), 500);
        vm.prank(_projects.ownerOf(_projectId));
        _swapTerminal.addDefaultPool(_projectId, address(UNI), IUniswapV3Pool(newPool));

        (pool, zeroToOne) = _swapTerminal.getPoolFor(_projectId, address(UNI));

        assertEq(address(pool), newPool);
        assertEq(zeroToOne, address(UNI) < address(WETH));

        emit log_address(address(_permissions));

        // Old deploy is used so we'll just allow this
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector, _projectOwner, address(12_345), _projectId, 28
            )
        );
        vm.prank(address(12_345));
        _swapTerminal.addDefaultPool(_projectId, address(UNI), IUniswapV3Pool(address(5432)));
    }
}
