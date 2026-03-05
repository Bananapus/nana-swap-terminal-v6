// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "../../src/JBSwapTerminal.sol";
import "../../src/JBSwapTerminalRegistry.sol";

/// @notice Deploy the swap terminal and create the mocks
contract UnitFixture is Test {
    // -- swap terminal dependencies --
    IJBProjects public mockJBProjects;
    IJBPermissions public mockJBPermissions;
    IJBDirectory public mockJBDirectory;

    IPermit2 public mockPermit2;
    IWETH9 public mockWETH;
    address public mockTokenOut;
    IUniswapV3Factory public mockUniswapFactory;

    address public terminalOwner;

    JBSwapTerminal public swapTerminal;
    JBSwapTerminalRegistry public swapTerminalRegistry;

    function setUp() public virtual {
        // -- create random addresses and etch code so vm.mockCall works --
        mockJBProjects = IJBProjects(makeAddr("mockJBProjects"));
        vm.etch(address(mockJBProjects), hex"00");
        mockJBPermissions = IJBPermissions(makeAddr("mockJBPermissions"));
        vm.etch(address(mockJBPermissions), hex"00");
        mockJBDirectory = IJBDirectory(makeAddr("mockJBDirectory"));
        vm.etch(address(mockJBDirectory), hex"00");

        mockPermit2 = IPermit2(makeAddr("mockPermit2"));
        vm.etch(address(mockPermit2), hex"00");
        mockWETH = IWETH9(makeAddr("mockWETH"));
        vm.etch(address(mockWETH), hex"00");
        mockTokenOut = makeAddr("tokenOut");

        mockUniswapFactory = IUniswapV3Factory(makeAddr("mockUniswapFactory"));
        vm.etch(address(mockUniswapFactory), hex"00");

        terminalOwner = makeAddr("terminalOwner");

        // -- deploy the swap terminal --
        swapTerminal = new JBSwapTerminal(
            mockJBDirectory,
            mockJBPermissions,
            mockJBProjects,
            mockPermit2,
            terminalOwner,
            mockWETH,
            mockTokenOut,
            mockUniswapFactory,
            address(0)
        );

        // -- deploy the swap terminal registry --
        swapTerminalRegistry =
            new JBSwapTerminalRegistry(mockJBPermissions, mockJBProjects, mockPermit2, terminalOwner, address(0));

        vm.prank(terminalOwner);
        swapTerminalRegistry.setDefaultTerminal(swapTerminal);
    }

    // test helpers:

    // mock and expect a call to a given address
    function mockExpectCall(address target, bytes memory callData, bytes memory returnedData) internal {
        vm.mockCall(target, callData, returnedData);
        vm.expectCall(target, callData);
    }

    // mock and expect a safe approval to a given token
    function mockExpectSafeApprove(address token, address owner, address spender, uint256 amount) internal {
        mockExpectCall(token, abi.encodeCall(IERC20.allowance, (owner, spender)), abi.encode(0));

        mockExpectCall(token, abi.encodeCall(IERC20.approve, (spender, amount)), abi.encode(true));
    }

    function mockExpectTransferFrom(address from, address to, address token, uint256 amount) internal {
        mockExpectCall(token, abi.encodeCall(IERC20.allowance, (from, to)), abi.encode(amount));

        mockExpectCall(token, abi.encodeCall(IERC20.transferFrom, (from, to, amount)), abi.encode(true));

        // Mock balanceOf for the leftover check (no expectation — _acceptFundsFor no longer calls balanceOf)
        vm.mockCall(token, abi.encodeCall(IERC20.balanceOf, to), abi.encode(amount));
    }

    // compare 2 uniswap v3 pool addresses
    function assertEq(IUniswapV3Pool a, IUniswapV3Pool b) internal pure {
        assertEq(address(a), address(b), "pool addresses are not equal");
    }

    // compare 2 arrays of accounting contexts
    function assertEq(JBAccountingContext[] memory a, JBAccountingContext[] memory b) internal pure {
        assertEq(a.length, b.length, "lengths are not equal");

        for (uint256 i; i < a.length; i++) {
            assertEq(a[i].token, b[i].token, "tokens are not equal");
            assertEq(a[i].decimals, b[i].decimals, "decimals are not equal");
            assertEq(a[i].currency, b[i].currency, "currencies are not equal");
        }
    }

    // check if a is included in b
    function assertIsIncluded(JBAccountingContext[] memory a, JBAccountingContext[] memory b) internal pure {
        for (uint256 i; i < a.length; i++) {
            bool _elementIsIncluded;
            for (uint256 j; j < b.length; j++) {
                if (a[i].token == b[j].token && a[i].decimals == b[j].decimals && a[i].currency == b[j].currency) {
                    _elementIsIncluded = true;
                    break;
                }
            }

            assertTrue(_elementIsIncluded, "left not included in right");
        }
    }

    // create a metadata based on a single entry
    function _createMetadata(bytes4 id, bytes memory data) internal pure returns (bytes memory) {
        return JBMetadataResolver.addToMetadata("", id, data);
    }
}
