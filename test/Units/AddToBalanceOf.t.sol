// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "../helper/UnitFixture.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {
    IUniswapV3PoolActions,
    IUniswapV3PoolImmutables,
    IUniswapV3PoolDerivedState
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {JBSwapLib} from "src/libraries/JBSwapLib.sol";

contract JBSwapTerminaladdToBalanceOf is UnitFixture {
    address caller;
    address projectOwner;

    address beneficiary;
    address tokenIn;
    address tokenOut;
    IUniswapV3Pool pool;

    address nextTerminal;

    uint256 projectId = 1337;

    function setUp() public override {
        super.setUp();

        caller = makeAddr("caller");
        beneficiary = makeAddr("beneficiary");
        tokenIn = makeAddr("tokenIn");
        pool = IUniswapV3Pool(makeAddr("pool"));
        nextTerminal = makeAddr("nextTerminal");

        tokenOut = swapTerminal.TOKEN_OUT();
    }

    function test_WhenTokenInIsTheNativeToken(uint256 msgValue, uint256 amountIn, uint256 amountOut) public {
        amountOut = bound(amountOut, 1, type(uint160).max);
        vm.deal(caller, msgValue);

        tokenIn = JBConstants.NATIVE_TOKEN;

        // Add a default pool
        projectOwner = makeAddr("projectOwner");

        // Set the project owner
        mockExpectCall(address(mockJBProjects), abi.encodeCall(IERC721.ownerOf, (projectId)), abi.encode(projectOwner));

        // decimals() call while setting the accounting context
        mockExpectCall(address(mockWETH), abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(18));

        // fee() call when swapping
        mockExpectCall(address(pool), abi.encodeCall(IUniswapV3PoolImmutables.fee, ()), abi.encode(1000));

        // getPool() call when swapping
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenOut, address(mockWETH), 1000)),
            abi.encode(address(pool))
        );

        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (address(mockWETH), tokenIn, 1000)),
            abi.encode(address(pool))
        );

        // Add the pool as the project owner
        vm.startPrank(projectOwner);
        swapTerminal.addDefaultPool(projectId, address(mockWETH), pool);

        // Add default twap params
        swapTerminal.addTwapParamsFor(projectId, pool, swapTerminal.MIN_TWAP_WINDOW());
        vm.stopPrank();

        bytes memory quoteMetadata = _createMetadata(
            JBMetadataResolver.getId("quoteForSwap", address(swapTerminal)), abi.encode(amountOut, pool)
        );

        // Mock the swap - this is where we make most of the tests
        mockExpectCall(
            address(pool),
            abi.encodeCall(
                IUniswapV3PoolActions.swap,
                (
                    address(swapTerminal),
                    address(mockWETH) < tokenOut,
                    // it should use msg value as amountIn
                    int256(msgValue),
                    JBSwapLib.sqrtPriceLimitFromAmounts(msgValue, amountOut, address(mockWETH) < tokenOut),
                    // it should use weth as tokenIn
                    // it should set inIsNativeToken to true
                    abi.encode(projectId, tokenIn)
                )
            ),
            // 0 for 1 => amount0 is the token in (positive), amount1 is the token out (negative/owed to the pool), and
            // vice versa
            address(mockWETH) < tokenOut
                ? abi.encode(msgValue, -int256(amountOut))
                : abi.encode(-int256(amountOut), msgValue)
        );

        mockExpectCall(
            address(mockJBDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenOut)),
            abi.encode(nextTerminal)
        );

        mockExpectSafeApprove(tokenOut, address(swapTerminal), nextTerminal, amountOut);

        // it should pass the benefiaciary as beneficiary for the next terminal
        mockExpectCall(
            nextTerminal,
            abi.encodeCall(IJBTerminal.addToBalanceOf, (projectId, tokenOut, amountOut, false, "", quoteMetadata)),
            abi.encode(1337)
        );

        // it should not have any leftover
        mockExpectCall(address(mockWETH), abi.encodeCall(IERC20.balanceOf, (address(swapTerminal))), abi.encode(0));

        // minReturnedTokens is used for the next terminal minAmountOut (where tokenOut is actually becoming the
        // tokenIn,meaning the minReturned insure a min 1:1 token ratio is the next terminal)
        vm.prank(caller);
        swapTerminal.addToBalanceOf{value: msgValue}({
            projectId: projectId,
            token: tokenIn,
            amount: amountIn, // should be discarded
            shouldReturnHeldFees: false,
            memo: "",
            metadata: quoteMetadata
        });
    }

    modifier whenTokenInIsAnErc20Token() {
        _;
    }

    function test_WhenTokenInIsAnErc20Token(uint256 amountIn, uint256 amountOut) public whenTokenInIsAnErc20Token {
        amountOut = bound(amountOut, 1, type(uint248).max);

        _addDefaultPoolAndParams(uint32(swapTerminal.MIN_TWAP_WINDOW()));

        // Should transfer the token in from the caller to the swap terminal
        mockExpectTransferFrom(caller, address(swapTerminal), tokenIn, amountIn);

        bytes memory quoteMetadata = _createMetadata(
            JBMetadataResolver.getId("quoteForSwap", address(swapTerminal)), abi.encode(amountOut, pool)
        );

        // Mock the swap - this is where we make most of the tests
        mockExpectCall(
            address(pool),
            abi.encodeCall(
                IUniswapV3PoolActions.swap,
                (
                    address(swapTerminal),
                    tokenIn < tokenOut,
                    // it should use amountIn as amount in
                    int256(amountIn),
                    JBSwapLib.sqrtPriceLimitFromAmounts(amountIn, amountOut, tokenIn < tokenOut),
                    // it should use tokenIn as tokenIn
                    abi.encode(projectId, tokenIn)
                )
            ),
            // 0 for 1 => amount0 is the token in (positive), amount1 is the token out (negative/owed to the pool), and
            // vice versa
            tokenIn < tokenOut ? abi.encode(amountIn, -int256(amountOut)) : abi.encode(-int256(amountOut), amountIn)
        );

        mockExpectCall(
            address(mockJBDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenOut)),
            abi.encode(nextTerminal)
        );

        mockExpectSafeApprove(tokenOut, address(swapTerminal), nextTerminal, amountOut);

        // Mock the call to the next terminal, using the token out as new token in
        mockExpectCall(
            nextTerminal,
            abi.encodeCall(IJBTerminal.addToBalanceOf, (projectId, tokenOut, amountOut, false, "", quoteMetadata)),
            abi.encode(1337)
        );

        // Expect the second call to balanceOf, checking for leftover
        // cannot be mocked as 0 yet tho (cf https://github.com/foundry-rs/foundry/issues/7467)
        vm.expectCall(address(tokenIn), abi.encodeCall(IERC20.balanceOf, (address(swapTerminal))));

        // // it should not have any leftover
        // vm.mockCall(
        //     address(tokenIn),
        //     abi.encodeCall(
        //         IERC20.balanceOf,
        //         (address(swapTerminal))
        //     ),
        //     abi.encode(0)
        // );

        // minReturnedTokens is used for the next terminal minAmountOut (where tokenOut is actually becoming the
        // tokenIn, meaning the minReturned insure a min 1:1 token ratio is the next terminal)
        vm.prank(caller);
        swapTerminal.addToBalanceOf{value: 0}({
            projectId: projectId,
            token: tokenIn,
            amount: amountIn, // should be discarded
            shouldReturnHeldFees: false,
            memo: "",
            metadata: quoteMetadata
        });
    }

    function test_RevertWhen_AMsgValueIsPassedAlongAnErc20Token(
        uint256 msgValue,
        uint256 amountIn,
        uint256 amountOut
    )
        public
        whenTokenInIsAnErc20Token
    {
        msgValue = bound(msgValue, 1, type(uint256).max);
        vm.deal(caller, msgValue);

        bytes memory quoteMetadata = _createMetadata(
            JBMetadataResolver.getId("quoteForSwap", address(swapTerminal)), abi.encode(amountOut, pool)
        );

        mockExpectCall(
            address(mockJBDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenOut)),
            abi.encode(nextTerminal)
        );

        // it should revert
        vm.expectRevert(abi.encodeWithSelector(JBSwapTerminal.JBSwapTerminal_NoMsgValueAllowed.selector, msgValue));

        vm.prank(caller);
        swapTerminal.addToBalanceOf{value: msgValue}({
            projectId: projectId,
            token: tokenIn,
            amount: amountIn,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: quoteMetadata
        });
    }

    function test_WhenTokenInUsesAnErc20Approval(uint256 amountIn, uint256 amountOut) public whenTokenInIsAnErc20Token {
        // it should use the token transferFrom
        test_WhenTokenInIsAnErc20Token(amountIn, amountOut);
    }

    modifier whenPermit2DataArePassed() {
        _;
    }

    function test_WhenPermit2DataArePassed(
        uint256 amountIn,
        uint256 amountOut
    )
        public
        whenTokenInIsAnErc20Token
        whenPermit2DataArePassed
    {
        amountOut = bound(amountOut, 1, type(uint248).max);
        // 0 amountIn will not trigger a permit2 use
        amountIn = bound(amountIn, 1, type(uint160).max);

        _addDefaultPoolAndParams(uint32(swapTerminal.MIN_TWAP_WINDOW()));

        // add the permit2 data to the metadata
        bytes memory payMetadata = _createMetadata(
            JBMetadataResolver.getId("quoteForSwap", address(swapTerminal)), abi.encode(amountOut, pool)
        );

        JBSingleAllowance memory context =
            JBSingleAllowance({sigDeadline: 0, amount: uint160(amountIn), expiration: 0, nonce: 0, signature: ""});

        payMetadata = JBMetadataResolver.addToMetadata(
            payMetadata, JBMetadataResolver.getId("permit2", address(swapTerminal)), abi.encode(context)
        );

        // it should use the permit2 call
        mockExpectCall(
            address(mockPermit2),
            abi.encodeWithSelector(
                bytes4(keccak256("permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)")),
                caller,
                IAllowanceTransfer.PermitSingle({
                    details: IAllowanceTransfer.PermitDetails({
                        token: tokenIn, amount: uint160(amountIn), expiration: 0, nonce: 0
                    }),
                    spender: address(swapTerminal),
                    sigDeadline: 0
                }),
                ""
            ),
            ""
        );

        mockExpectCall(
            address(mockPermit2),
            abi.encodeWithSelector(
                bytes4(keccak256("transferFrom(address,address,uint160,address)")),
                caller,
                address(swapTerminal),
                uint160(amountIn),
                tokenIn
            ),
            ""
        );

        // no allowance granted outside of permit2
        mockExpectCall(tokenIn, abi.encodeCall(IERC20.allowance, (caller, address(swapTerminal))), abi.encode(0));

        vm.mockCall(tokenIn, abi.encodeCall(IERC20.balanceOf, (address(swapTerminal))), abi.encode(amountIn));

        // Mock the swap - this is where we make most of the tests
        mockExpectCall(
            address(pool),
            abi.encodeCall(
                IUniswapV3PoolActions.swap,
                (
                    address(swapTerminal),
                    tokenIn < tokenOut,
                    // it should use amountIn as amount in
                    int256(amountIn),
                    JBSwapLib.sqrtPriceLimitFromAmounts(amountIn, amountOut, tokenIn < tokenOut),
                    // it should use tokenIn
                    // it should set inIsNativeToken to false
                    abi.encode(projectId, tokenIn)
                )
            ),
            // 0 for 1 => amount0 is the token in (positive), amount1 is the token out (negative/owed to the pool), and
            // vice versa
            tokenIn < tokenOut ? abi.encode(amountIn, -int256(amountOut)) : abi.encode(-int256(amountOut), amountIn)
        );

        mockExpectCall(
            address(mockJBDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenOut)),
            abi.encode(nextTerminal)
        );

        mockExpectSafeApprove(tokenOut, address(swapTerminal), nextTerminal, amountOut);
        // Mock the call to the next terminal, using the token out as new token in
        mockExpectCall(
            nextTerminal,
            abi.encodeCall(IJBTerminal.pay, (projectId, tokenOut, amountOut, beneficiary, amountOut, "", payMetadata)),
            abi.encode(1337)
        );

        // minReturnedTokens is used for the next terminal minAmountOut (where tokenOut is actually becoming the
        // tokenIn, meaning the minReturned insure a min 1:1 token ratio is the next terminal)
        vm.prank(caller);
        swapTerminal.pay{value: 0}({
            projectId: projectId,
            token: tokenIn,
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: amountOut,
            memo: "",
            metadata: payMetadata
        });
    }

    function test_RevertWhen_ThePermit2AllowanceIsLessThanTheAmountIn(uint256 amountIn)
        public
        whenTokenInIsAnErc20Token
        whenPermit2DataArePassed
    {
        uint256 amountOut = 1337;

        // 0 amountIn will not trigger a permit2 use
        amountIn = bound(amountIn, 1, type(uint160).max);

        // add the permit2 data to the metadata
        bytes memory payMetadata = _createMetadata(
            JBMetadataResolver.getId("quoteForSwap", address(swapTerminal)), abi.encode(amountOut, pool)
        );

        JBSingleAllowance memory context =
            JBSingleAllowance({sigDeadline: 0, amount: uint160(amountIn) - 1, expiration: 0, nonce: 0, signature: ""});

        payMetadata = JBMetadataResolver.addToMetadata(
            payMetadata, JBMetadataResolver.getId("permit2", address(swapTerminal)), abi.encode(context)
        );

        mockExpectCall(
            address(mockJBDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenOut)),
            abi.encode(nextTerminal)
        );

        // it should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                JBSwapTerminal.JBSwapTerminal_PermitAllowanceNotEnough.selector, amountIn, amountIn - 1
            )
        );
        vm.prank(caller);
        swapTerminal.pay{value: 0}({
            projectId: projectId,
            token: tokenIn,
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: amountOut,
            memo: "",
            metadata: payMetadata
        });
    }

    modifier whenAQuoteIsProvided() {
        _;
    }

    function test_WhenAQuoteIsProvided(
        uint256 msgValue,
        uint256 amountIn,
        uint256 amountOut
    )
        public
        whenAQuoteIsProvided
    {
        // it should use the quote as amountOutMin
        // it should use the pool passed
        // it should use the token passed as tokenOut
        test_WhenTokenInIsTheNativeToken(msgValue, amountIn, amountOut);
    }

    function test_RevertWhen_TheAmountReceivedIsLessThanTheAmountOutMin(
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 amountReceived
    )
        public
        whenAQuoteIsProvided
    {
        minAmountOut = bound(minAmountOut, 1, type(uint248).max);
        amountReceived = bound(amountReceived, 0, minAmountOut - 1);

        vm.assume(amountIn > 0);

        _addDefaultPoolAndParams(uint32(swapTerminal.MIN_TWAP_WINDOW()));

        bytes memory quoteMetadata = _createMetadata(
            JBMetadataResolver.getId("quoteForSwap", address(swapTerminal)), abi.encode(minAmountOut, pool)
        );
        mockExpectTransferFrom(caller, address(swapTerminal), tokenIn, amountIn);

        // Mock the swap - this is where we make most of the tests
        mockExpectCall(
            address(pool),
            abi.encodeCall(
                IUniswapV3PoolActions.swap,
                (
                    address(swapTerminal),
                    tokenIn < tokenOut,
                    // it should amountIn
                    int256(amountIn),
                    JBSwapLib.sqrtPriceLimitFromAmounts(amountIn, minAmountOut, tokenIn < tokenOut),
                    // it should use tokenIn
                    abi.encode(projectId, tokenIn)
                )
            ),
            // 0 for 1 => amount0 is the token in (positive), amount1 is the token out (negative/owed to the pool), and
            // vice versa
            tokenIn < tokenOut
                ? abi.encode(amountIn, -int256(amountReceived))
                : abi.encode(-int256(amountReceived), amountIn)
        );

        mockExpectCall(
            address(mockJBDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenOut)),
            abi.encode(nextTerminal)
        );

        // it should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                JBSwapTerminal.JBSwapTerminal_SpecifiedSlippageExceeded.selector, amountReceived, minAmountOut
            )
        );

        vm.prank(caller);
        swapTerminal.pay({
            projectId: projectId,
            token: tokenIn,
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: amountReceived,
            memo: "",
            metadata: quoteMetadata
        });
    }

    modifier whenNoQuoteIsPassed() {
        _;
    }

    function test_WhenNoQuoteIsPassed() public whenNoQuoteIsPassed {
        tokenIn = makeAddr("tokenIn");

        tokenOut = mockTokenOut;
        uint256 amountIn = 10;
        uint256 amountOut = 1337;

        bytes memory quoteMetadata = "";

        uint32 secondsAgo = uint32(swapTerminal.MIN_TWAP_WINDOW());

        // it should use the default pool
        // it should take the other pool token as tokenOut
        _addDefaultPoolAndParams(secondsAgo);

        uint32[] memory timeframeArray = new uint32[](2);
        timeframeArray[0] = secondsAgo;
        timeframeArray[1] = 0;

        uint56[] memory tickCumulatives = new uint56[](2);
        tickCumulatives[0] = 100;
        tickCumulatives[1] = 1000;

        uint160[] memory secondsPerLiquidityCumulativeX128s = new uint160[](2);
        secondsPerLiquidityCumulativeX128s[0] = 100;
        secondsPerLiquidityCumulativeX128s[1] = 1000;

        // Mock the pool being unlocked.
        mockExpectCall(address(pool), abi.encodeCall(pool.slot0, ()), abi.encode(0, 0, 0, 1, 0, 0, true));

        // Return the observationTimestamp
        mockExpectCall(
            address(pool), abi.encodeCall(pool.observations, (0)), abi.encode(block.timestamp - secondsAgo, 0, 0, true)
        );

        // it should get a twap and compute a min amount
        mockExpectCall(
            address(pool),
            abi.encodeCall(IUniswapV3PoolDerivedState.observe, (timeframeArray)),
            abi.encode(tickCumulatives, secondsPerLiquidityCumulativeX128s)
        );

        // Should transfer the token in from the caller to the swap terminal
        mockExpectTransferFrom(caller, address(swapTerminal), tokenIn, amountIn);

        // Mock the swap - this is where we make most of the tests
        {
            // For TWAP-based swaps, the sqrtPriceLimit depends on internal sigmoid computation.
            // Use partial calldata matching (selector + first 3 params) to avoid replicating that logic.
            bool zeroForOne = tokenIn < tokenOut;
            bytes memory partialSwapCalldata = abi.encodeWithSelector(
                IUniswapV3PoolActions.swap.selector, address(swapTerminal), zeroForOne, int256(amountIn)
            );
            vm.mockCall(
                address(pool),
                partialSwapCalldata,
                zeroForOne ? abi.encode(amountIn, -int256(amountOut)) : abi.encode(-int256(amountOut), amountIn)
            );
            vm.expectCall(address(pool), partialSwapCalldata);
        }

        mockExpectCall(
            address(mockJBDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenOut)),
            abi.encode(nextTerminal)
        );

        mockExpectSafeApprove(tokenOut, address(swapTerminal), nextTerminal, amountOut);

        // Mock the call to the next terminal, using the token out as new token in
        mockExpectCall(
            nextTerminal,
            abi.encodeCall(IJBTerminal.addToBalanceOf, (projectId, tokenOut, amountOut, false, "", quoteMetadata)),
            abi.encode(1337)
        );

        // minReturnedTokens is used for the next terminal minAmountOut (where tokenOut is actually becoming the
        // tokenIn,
        // meaning the minReturned insure a min 1:1 token ratio is the next terminal)
        vm.prank(caller);
        swapTerminal.addToBalanceOf{value: 0}({
            projectId: projectId,
            token: tokenIn,
            amount: amountIn, // should be discarded
            shouldReturnHeldFees: false,
            memo: "",
            metadata: quoteMetadata
        });
    }

    function test_RevertWhen_NoDefaultPoolIsDefined() public whenNoQuoteIsPassed {
        tokenIn = makeAddr("tokenIn");

        tokenOut = mockTokenOut;
        uint256 amountIn = 10;

        bytes memory quoteMetadata = "";

        mockExpectCall(
            address(mockJBDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenOut)),
            abi.encode(nextTerminal)
        );
        mockExpectTransferFrom(caller, address(swapTerminal), tokenIn, amountIn);

        // it should revert
        vm.expectRevert(
            abi.encodeWithSelector(JBSwapTerminal.JBSwapTerminal_NoDefaultPoolDefined.selector, projectId, tokenIn)
        );
        vm.prank(caller);
        swapTerminal.addToBalanceOf{value: 0}({
            projectId: projectId,
            token: tokenIn,
            amount: amountIn, // should be discarded
            shouldReturnHeldFees: false,
            memo: "",
            metadata: quoteMetadata
        });
    }

    function test_RevertWhen_TheAmountReceivedIsLessThanTheTwapAmountOutMin() public whenNoQuoteIsPassed {
        tokenIn = makeAddr("tokenIn");

        tokenOut = mockTokenOut;
        uint256 amountIn = 10;

        bytes memory quoteMetadata = "";

        uint32 secondsAgo = uint32(swapTerminal.MIN_TWAP_WINDOW());

        // it should use the default pool
        _addDefaultPoolAndParams(secondsAgo);

        uint32[] memory timeframeArray = new uint32[](2);
        timeframeArray[0] = secondsAgo;
        timeframeArray[1] = 0;

        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 100;
        tickCumulatives[1] = 1000;

        uint160[] memory secondsPerLiquidityCumulativeX128s = new uint160[](2);
        secondsPerLiquidityCumulativeX128s[0] = 100;
        secondsPerLiquidityCumulativeX128s[1] = 1000;

        uint256 minAmountOut = _computeTwapAmountOut(amountIn, secondsAgo, tickCumulatives);

        // Mock the pool being unlocked.
        mockExpectCall(address(pool), abi.encodeCall(pool.slot0, ()), abi.encode(0, 0, 0, 1, 0, 0, true));

        // Return the observationTimestamp
        mockExpectCall(
            address(pool), abi.encodeCall(pool.observations, (0)), abi.encode(block.timestamp - secondsAgo, 0, 0, true)
        );

        // it should get a twap and compute a min amount
        mockExpectCall(
            address(pool),
            abi.encodeCall(IUniswapV3PoolDerivedState.observe, (timeframeArray)),
            abi.encode(tickCumulatives, secondsPerLiquidityCumulativeX128s)
        );

        // Should transfer the token in from the caller to the swap terminal
        mockExpectTransferFrom(caller, address(swapTerminal), tokenIn, amountIn);

        // Mock the swap - this is where we make most of the tests
        {
            // For TWAP-based swaps, the sqrtPriceLimit depends on internal sigmoid computation.
            // Use partial calldata matching (selector + first 3 params) to avoid replicating that logic.
            bool zeroForOne = tokenIn < tokenOut;
            bytes memory partialSwapCalldata = abi.encodeWithSelector(
                IUniswapV3PoolActions.swap.selector, address(swapTerminal), zeroForOne, int256(amountIn)
            );
            vm.mockCall(
                address(pool),
                partialSwapCalldata,
                zeroForOne
                    ? abi.encode(amountIn, -int256(minAmountOut - 1))
                    : abi.encode(-int256(minAmountOut - 1), amountIn)
            );
            vm.expectCall(address(pool), partialSwapCalldata);
        }

        mockExpectCall(
            address(mockJBDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenOut)),
            abi.encode(nextTerminal)
        );

        // it should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                JBSwapTerminal.JBSwapTerminal_SpecifiedSlippageExceeded.selector, minAmountOut - 1, minAmountOut
            )
        );

        vm.prank(caller);
        swapTerminal.addToBalanceOf{value: 0}({
            projectId: projectId,
            token: tokenIn,
            amount: amountIn, // should be discarded
            shouldReturnHeldFees: false,
            memo: "",
            metadata: quoteMetadata
        });
    }

    function test_WhenTheTokenOutIsTheNativeToken(
        uint256 amountIn,
        uint256 amountOut
    )
        public
        whenAQuoteIsProvided
        whenTokenInIsAnErc20Token
    {
        amountOut = bound(amountOut, 1, type(uint248).max);

        // Set the token out as native token
        tokenOut = JBConstants.NATIVE_TOKEN;

        swapTerminal = new JBSwapTerminal(
            mockJBDirectory,
            mockJBPermissions,
            mockJBProjects,
            mockPermit2,
            terminalOwner,
            mockWETH,
            tokenOut,
            mockUniswapFactory,
            address(0)
        );

        // Add a default pool
        projectOwner = terminalOwner;

        // decimals() call while setting the accounting context
        mockExpectCall(tokenIn, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(18));

        // fee() call when swapping
        mockExpectCall(address(pool), abi.encodeCall(IUniswapV3PoolImmutables.fee, ()), abi.encode(1000));

        // getPool() call when swapping
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, address(mockWETH), 1000)),
            abi.encode(address(pool))
        );

        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenOut, address(swapTerminal.WETH()), 1000)),
            abi.encode(address(pool))
        );

        // Add the pool as the project owner
        vm.startPrank(projectOwner);
        swapTerminal.addDefaultPool(0, tokenIn, pool);

        // Add default twap params
        swapTerminal.addTwapParamsFor(0, pool, swapTerminal.MIN_TWAP_WINDOW());
        vm.stopPrank();

        // Should transfer the token in from the caller to the swap terminal
        mockExpectTransferFrom(caller, address(swapTerminal), tokenIn, amountIn);

        bytes memory quoteMetadata = _createMetadata(
            JBMetadataResolver.getId("quoteForSwap", address(swapTerminal)), abi.encode(amountOut, pool)
        );

        // Mock the swap - this is where we make most of the tests
        mockExpectCall(
            address(pool),
            abi.encodeCall(
                IUniswapV3PoolActions.swap,
                (
                    address(swapTerminal),
                    tokenIn < address(mockWETH),
                    // it should use amountIn as amount in
                    int256(amountIn),
                    JBSwapLib.sqrtPriceLimitFromAmounts(amountIn, amountOut, tokenIn < address(mockWETH)),
                    // it should use tokenIn
                    // it should set inIsNativeToken to false
                    abi.encode(projectId, tokenIn)
                )
            ),
            // 0 for 1 => amount0 is the token in (positive), amount1 is the token out (negative/owed to the pool), and
            // vice versa
            tokenIn < address(mockWETH)
                ? abi.encode(amountIn, -int256(amountOut))
                : abi.encode(-int256(amountOut), amountIn)
        );

        // it should use the native token for the next terminal pay()
        mockExpectCall(
            address(mockJBDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenOut)),
            abi.encode(nextTerminal)
        );

        // Mock the call to the next terminal, using the token out as new token in
        mockExpectCall(
            nextTerminal,
            abi.encodeCall(IJBTerminal.addToBalanceOf, (projectId, tokenOut, amountOut, false, "", quoteMetadata)),
            abi.encode(1337)
        );

        // it should use weth as tokenOut
        // it should unwrap the tokenOut after swapping
        mockExpectCall(address(mockWETH), abi.encodeCall(IWETH9.withdraw, (amountOut)), abi.encode(true));
        vm.deal(address(swapTerminal), amountOut);

        // minReturnedTokens is used for the next terminal minAmountOut (where tokenOut is actually becoming the
        // tokenIn,
        // meaning the minReturned insure a min 1:1 token ratio is the next terminal)
        vm.prank(caller);
        swapTerminal.addToBalanceOf{value: 0}({
            projectId: projectId,
            token: tokenIn,
            amount: amountIn, // should be discarded
            shouldReturnHeldFees: false,
            memo: "",
            metadata: quoteMetadata
        });
    }

    function test_WhenTheTokenOutIsAnErc20Token(uint256 amountIn, uint256 amountOut) public whenTokenInIsAnErc20Token {
        test_WhenTokenInIsAnErc20Token(amountIn, amountOut);
    }

    function test_RevertWhen_TheTokenOutHasNoTerminalDefined() public {
        tokenIn = makeAddr("tokenIn");
        tokenOut = mockTokenOut;
        uint256 amountIn = 10;

        bytes memory quoteMetadata = "";

        mockExpectCall(
            address(mockJBDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenOut)),
            abi.encode(address(0))
        );

        // it should revert
        vm.expectRevert(
            abi.encodeWithSelector(JBSwapTerminal.JBSwapTerminal_TokenNotAccepted.selector, projectId, tokenOut)
        );
        vm.prank(caller);
        swapTerminal.addToBalanceOf{value: 0}({
            projectId: projectId,
            token: tokenIn,
            amount: amountIn, // should be discarded
            shouldReturnHeldFees: false,
            memo: "",
            metadata: quoteMetadata
        });
    }

    function test_WhenNotAllTokenInAreSwapped(uint256 amountIn, uint256 amountOut) external whenTokenInIsAnErc20Token {
        amountIn = bound(amountIn, 1, type(uint160).max);
        amountOut = bound(amountOut, 1, type(uint160).max);

        _addDefaultPoolAndParams(uint32(swapTerminal.MIN_TWAP_WINDOW()));

        // Should transfer the token in from the caller to the swap terminal
        mockExpectTransferFrom(caller, address(swapTerminal), tokenIn, amountIn);

        bytes memory quoteMetadata = _createMetadata(
            JBMetadataResolver.getId("quoteForSwap", address(swapTerminal)), abi.encode(amountOut, pool)
        );

        // Mock the swap - this is where we make most of the tests
        mockExpectCall(
            address(pool),
            abi.encodeCall(
                IUniswapV3PoolActions.swap,
                (
                    address(swapTerminal),
                    tokenIn < tokenOut,
                    // it should use amountIn as amount in
                    int256(amountIn),
                    JBSwapLib.sqrtPriceLimitFromAmounts(amountIn, amountOut, tokenIn < tokenOut),
                    // it should use tokenIn as tokenIn
                    abi.encode(projectId, tokenIn)
                )
            ),
            // 0 for 1 => amount0 is the token in (positive), amount1 is the token out (negative/owed to the pool), and
            // vice versa
            tokenIn < tokenOut ? abi.encode(amountIn, -int256(amountOut)) : abi.encode(-int256(amountOut), amountIn)
        );

        mockExpectCall(
            address(mockJBDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenOut)),
            abi.encode(nextTerminal)
        );

        mockExpectSafeApprove(tokenOut, address(swapTerminal), nextTerminal, amountOut);

        // Mock the call to the next terminal, using the token out as new token in
        mockExpectCall(
            nextTerminal,
            abi.encodeCall(IJBTerminal.addToBalanceOf, (projectId, tokenOut, amountOut, false, "", quoteMetadata)),
            abi.encode(1337)
        );

        // Expect the second call to balanceOf, checking for leftover
        // cannot be mocked as 0 yet tho (cf https://github.com/foundry-rs/foundry/issues/7467)
        vm.expectCall(address(tokenIn), abi.encodeCall(IERC20.balanceOf, (address(swapTerminal))));

        // it should send the difference back to the caller
        // this should be the amountIn - swapped, but the balanceOf is mocked to always return amountIn...
        mockExpectCall(address(tokenIn), abi.encodeCall(IERC20.transfer, (caller, amountIn)), abi.encode(true));

        // it should not keep any token in swap terminal - not being tested, cf supra, only single returned value for a
        // mock
        // vm.mockCall(
        //     address(tokenIn),
        //     abi.encodeCall(
        //         IERC20.balanceOf,
        //         (address(swapTerminal))
        //     ),
        //     abi.encode(0)
        // );

        // minReturnedTokens is used for the next terminal minAmountOut (where tokenOut is actually becoming the
        // tokenIn, meaning the minReturned insure a min 1:1 token ratio is the next terminal)
        vm.prank(caller);
        swapTerminal.addToBalanceOf{value: 0}({
            projectId: projectId,
            token: tokenIn,
            amount: amountIn, // should be discarded
            shouldReturnHeldFees: false,
            memo: "",
            metadata: quoteMetadata
        });
    }

    function _addDefaultPoolAndParams(uint32 secondsAgo) internal {
        // Add a default pool
        projectOwner = makeAddr("projectOwner");

        // Set the project owner
        mockExpectCall(address(mockJBProjects), abi.encodeCall(IERC721.ownerOf, (projectId)), abi.encode(projectOwner));

        // decimals() call while setting the accounting context
        mockExpectCall(address(tokenIn), abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(18));

        // fee() call when swapping
        mockExpectCall(address(pool), abi.encodeCall(IUniswapV3PoolImmutables.fee, ()), abi.encode(1000));

        // getPool() call when swapping
        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, tokenOut, 1000)),
            abi.encode(address(pool))
        );

        vm.mockCall(
            address(mockUniswapFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenOut, tokenIn, 1000)),
            abi.encode(address(pool))
        );

        // Add the pool as the project owner
        vm.prank(projectOwner);
        swapTerminal.addDefaultPool(projectId, tokenIn, pool);

        // Add default twap params
        vm.prank(projectOwner);
        swapTerminal.addTwapParamsFor(projectId, pool, secondsAgo);
    }

    function _computeTwapAmountOut(
        uint256 amountIn,
        uint32 secondsAgo,
        int56[] memory tickCumulatives
    )
        internal
        view
        returns (uint256)
    {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo;
        secondsAgos[1] = 0;

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        int24 arithmeticMeanTick = int24(tickCumulativesDelta / int56(uint56(secondsAgo)));
        // Always round to negative infinity
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(uint56(secondsAgo)) != 0)) arithmeticMeanTick--;

        uint256 minAmountOut = OracleLibrary.getQuoteAtTick({
            tick: arithmeticMeanTick, baseAmount: uint128(amountIn), baseToken: tokenIn, quoteToken: tokenOut
        });

        return minAmountOut;
    }
}
