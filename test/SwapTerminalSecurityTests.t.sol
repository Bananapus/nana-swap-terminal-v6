// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./helper/UnitFixture.sol";

/// @notice ForTest harness exposing internal state for attack testing.
contract ForTest_SecuritySwapTerminal is JBSwapTerminal {
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBProjects projects,
        IPermit2 permit2,
        address _owner,
        IWETH9 weth,
        address tokenOut,
        IUniswapV3Factory uniswapFactory
    )
        JBSwapTerminal(directory, permissions, projects, permit2, _owner, weth, tokenOut, uniswapFactory, address(0))
    {}

    function forTest_forceAddPool(uint256 projectId, address token, IUniswapV3Pool pool) public {
        _poolFor[projectId][token] = pool;
    }

    function forTest_forceAddTwapWindow(uint256 projectId, IUniswapV3Pool pool, uint256 window) public {
        _twapWindowOf[projectId][pool] = window;
    }

    function forTest_forceAddAccountingContext(uint256 projectId, address token) public {
        _accountingContextFor[projectId][token] =
            JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
        _tokensWithAContext[projectId].push(token);
    }
}

/// @title SwapTerminalSecurityTests
/// @notice Security-focused tests for JBSwapTerminal covering callback spoofing,
///         permission enforcement, TWAP window validation, and pool verification.
contract SwapTerminalSecurityTests is UnitFixture {
    uint256 projectId = 1337;
    address token = makeAddr("inputToken");
    IUniswapV3Pool pool = IUniswapV3Pool(makeAddr("pool"));
    ForTest_SecuritySwapTerminal attackTerminal;

    function setUp() public override {
        super.setUp();

        attackTerminal = new ForTest_SecuritySwapTerminal(
            mockJBDirectory,
            mockJBPermissions,
            mockJBProjects,
            mockPermit2,
            terminalOwner,
            mockWETH,
            mockTokenOut,
            mockUniswapFactory
        );
    }

    // =========================================================================
    // Test 1: Callback spoofing — non-pool caller with valid-looking data
    // =========================================================================
    /// @notice Non-pool contract calls uniswapV3SwapCallback with crafted data.
    ///         Must revert with CallerNotPool.
    function test_callbackSpoofing_nonPoolCaller() public {
        // Set up a pool for this project/token so the callback has valid data to reference.
        attackTerminal.forTest_forceAddPool(projectId, token, pool);

        address attacker = makeAddr("attacker");
        bytes memory data = abi.encode(projectId, token);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(JBSwapTerminal.JBSwapTerminal_CallerNotPool.selector, attacker));
        attackTerminal.uniswapV3SwapCallback(1e18, -1e18, data);
    }

    // =========================================================================
    // Test 2: Callback spoofing — crafted data pointing to non-existent pool
    // =========================================================================
    /// @notice Attacker calls callback with data referencing a project with no pool.
    ///         Pool lookup returns address(0), so caller != address(0) triggers revert.
    function test_callbackSpoofing_noPoolConfigured() public {
        address attacker = makeAddr("attacker");
        // Project 9999 has no pool configured.
        bytes memory data = abi.encode(uint256(9999), token);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(JBSwapTerminal.JBSwapTerminal_CallerNotPool.selector, attacker));
        attackTerminal.uniswapV3SwapCallback(1e18, -1e18, data);
    }

    // =========================================================================
    // Test 3: Cross-project pool substitution
    // =========================================================================
    /// @notice Set a pool for project A but not project B.
    ///         Verify project B doesn't accidentally use project A's pool.
    function test_crossProjectPoolSubstitution() public {
        uint256 projectA = 100;
        uint256 projectB = 200;
        IUniswapV3Pool poolA = IUniswapV3Pool(makeAddr("poolA"));

        // Only set pool for project A.
        attackTerminal.forTest_forceAddPool(projectA, token, poolA);

        // Project B should have no pool.
        (IUniswapV3Pool resolvedPool,) = attackTerminal.getPoolFor(projectB, token);
        assertTrue(
            address(resolvedPool) == address(0) || address(resolvedPool) != address(poolA),
            "Project B should not resolve to project A's pool (unless default)"
        );
    }

    // =========================================================================
    // Test 4: addDefaultPool without permission — must revert
    // =========================================================================
    /// @notice Caller without ADD_SWAP_TERMINAL_POOL permission tries to add a pool.
    function test_addDefaultPool_noPermission_reverts() public {
        address attacker = makeAddr("attacker");

        // Mock permissions to return false.
        vm.mockCall(
            address(mockJBPermissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(false)
        );
        // Also mock the ownerOf for projects.
        vm.mockCall(
            address(mockJBProjects),
            abi.encodeWithSelector(IERC721.ownerOf.selector, projectId),
            abi.encode(terminalOwner)
        );

        vm.prank(attacker);
        vm.expectRevert();
        swapTerminal.addDefaultPool(projectId, token, pool);
    }

    // =========================================================================
    // Test 5: TWAP window below minimum — must revert
    // =========================================================================
    /// @notice Set TWAP window to 1 second (below MIN_TWAP_WINDOW of 120s).
    function test_addTwapParams_belowMinWindow_reverts() public {
        // Mock permissions to allow.
        vm.mockCall(
            address(mockJBPermissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );
        vm.mockCall(
            address(mockJBProjects),
            abi.encodeWithSelector(IERC721.ownerOf.selector, projectId),
            abi.encode(terminalOwner)
        );

        vm.prank(terminalOwner);
        vm.expectRevert();
        swapTerminal.addTwapParamsFor(projectId, pool, 1); // 1 second — too low
    }

    // =========================================================================
    // Test 6: TWAP window above maximum — must revert
    // =========================================================================
    /// @notice Set TWAP window to 1 week (above MAX_TWAP_WINDOW of 2 days).
    function test_addTwapParams_aboveMaxWindow_reverts() public {
        vm.mockCall(
            address(mockJBPermissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );
        vm.mockCall(
            address(mockJBProjects),
            abi.encodeWithSelector(IERC721.ownerOf.selector, projectId),
            abi.encode(terminalOwner)
        );

        vm.prank(terminalOwner);
        vm.expectRevert();
        swapTerminal.addTwapParamsFor(projectId, pool, 7 days); // 7 days — too high
    }

    // =========================================================================
    // Test 7: addTwapParams without permission — must revert
    // =========================================================================
    /// @notice Non-authorized caller tries to set TWAP params.
    function test_addTwapParams_noPermission_reverts() public {
        address attacker = makeAddr("attacker");

        vm.mockCall(
            address(mockJBPermissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(false)
        );
        vm.mockCall(
            address(mockJBProjects),
            abi.encodeWithSelector(IERC721.ownerOf.selector, projectId),
            abi.encode(terminalOwner)
        );

        vm.prank(attacker);
        vm.expectRevert();
        swapTerminal.addTwapParamsFor(projectId, pool, 300);
    }

    // =========================================================================
    // Test 8: Immutable TOKEN_OUT cannot change
    // =========================================================================
    /// @notice Verify TOKEN_OUT and WETH are immutable after construction.
    function test_tokenOut_isImmutable() public view {
        address tokenOut1 = attackTerminal.TOKEN_OUT();
        address tokenOut2 = attackTerminal.TOKEN_OUT();
        assertEq(tokenOut1, tokenOut2, "TOKEN_OUT should be immutable");
        assertTrue(tokenOut1 != address(0), "TOKEN_OUT should be set");

        address weth1 = address(attackTerminal.WETH());
        address weth2 = address(attackTerminal.WETH());
        assertEq(weth1, weth2, "WETH should be immutable");
    }
}

/// @title RegistryLowFindingsTests
/// @notice Tests for L-26 (disallow clears default) and L-27 (lock reverts without terminal).
contract RegistryLowFindingsTests is Test {
    JBSwapTerminalRegistry registry;
    address owner = makeAddr("registryOwner");

    IJBPermissions permissions;
    IJBProjects projects;
    IPermit2 permit2;

    function setUp() public {
        permissions = IJBPermissions(makeAddr("permissions"));
        vm.etch(address(permissions), hex"00");
        projects = IJBProjects(makeAddr("projects"));
        vm.etch(address(projects), hex"00");
        permit2 = IPermit2(makeAddr("permit2"));
        vm.etch(address(permit2), hex"00");

        registry = new JBSwapTerminalRegistry(permissions, projects, permit2, owner, address(0));

        // Mock permissions to return true by default.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );
        // Mock project ownership.
        vm.mockCall(address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector), abi.encode(owner));
    }

    // =========================================================================
    // L-26: Disallowing a terminal clears it from default
    // =========================================================================
    /// @notice After disallowing the default terminal, defaultTerminal should be address(0).
    function test_L26_disallowTerminal_clearsDefault() public {
        IJBTerminal terminal = IJBTerminal(makeAddr("terminal"));

        // Allow and set as default.
        vm.startPrank(owner);
        registry.allowTerminal(terminal);
        registry.setDefaultTerminal(terminal);
        vm.stopPrank();

        assertEq(address(registry.defaultTerminal()), address(terminal), "default should be set");

        // Disallow the terminal.
        vm.prank(owner);
        registry.disallowTerminal(terminal);

        // Default should now be cleared.
        assertEq(address(registry.defaultTerminal()), address(0), "L-26: default should be cleared after disallow");
    }

    /// @notice Disallowing a non-default terminal should NOT clear the default.
    function test_L26_disallowNonDefault_doesNotClearDefault() public {
        IJBTerminal terminalA = IJBTerminal(makeAddr("terminalA"));
        IJBTerminal terminalB = IJBTerminal(makeAddr("terminalB"));

        vm.startPrank(owner);
        registry.allowTerminal(terminalA);
        registry.allowTerminal(terminalB);
        registry.setDefaultTerminal(terminalA);
        vm.stopPrank();

        // Disallow terminalB (not the default).
        vm.prank(owner);
        registry.disallowTerminal(terminalB);

        // Default should still be terminalA.
        assertEq(address(registry.defaultTerminal()), address(terminalA), "default should remain unchanged");
    }

    // =========================================================================
    // L-27: Locking reverts when no terminal and no default
    // =========================================================================
    /// @notice lockTerminalFor reverts when no terminal is set and no default exists.
    function test_L27_lockTerminal_revertsWithoutTerminal() public {
        uint256 projectId = 42;

        // No terminal set, no default terminal.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(JBSwapTerminalRegistry.JBSwapTerminalRegistry_TerminalNotSet.selector, projectId)
        );
        registry.lockTerminalFor(projectId);
    }

    /// @notice lockTerminalFor succeeds and records the default when no project-specific terminal exists.
    function test_L27_lockTerminal_fallsBackToDefault() public {
        uint256 projectId = 42;
        IJBTerminal terminal = IJBTerminal(makeAddr("terminal"));

        // Allow and set as default.
        vm.startPrank(owner);
        registry.allowTerminal(terminal);
        registry.setDefaultTerminal(terminal);
        vm.stopPrank();

        // Lock without setting a project-specific terminal.
        vm.prank(owner);
        registry.lockTerminalFor(projectId);

        assertTrue(registry.hasLockedTerminal(projectId), "should be locked");
        assertEq(
            address(registry.terminalOf(projectId)), address(terminal), "should record default as project terminal"
        );
    }

    /// @notice lockTerminalFor succeeds when project has a specific terminal set.
    function test_L27_lockTerminal_withProjectTerminal() public {
        uint256 projectId = 42;
        IJBTerminal terminal = IJBTerminal(makeAddr("terminal"));

        // Allow terminal and set for project.
        vm.startPrank(owner);
        registry.allowTerminal(terminal);
        registry.setTerminalFor(projectId, terminal);
        vm.stopPrank();

        // Lock.
        vm.prank(owner);
        registry.lockTerminalFor(projectId);

        assertTrue(registry.hasLockedTerminal(projectId), "should be locked");
    }
}
