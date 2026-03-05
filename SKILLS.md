# nana-swap-terminal-v5

## Purpose

Accept payments in any ERC-20 token (or native ETH), swap to a configured output token via Uniswap V3, and forward the proceeds to the project's primary terminal.

## Contracts

| Contract | Role |
|----------|------|
| `JBSwapTerminal` | Core terminal: accepts tokens, swaps via Uniswap V3, forwards to primary terminal. Implements `IJBTerminal`, `IJBPermitTerminal`, `IUniswapV3SwapCallback`. |
| `JBSwapTerminalRegistry` | Proxy terminal routing `pay`/`addToBalanceOf` to a per-project or default `JBSwapTerminal`. Implements `IJBTerminal`. |

## Key Functions

| Function | Contract | What it does |
|----------|----------|--------------|
| `pay(projectId, token, amount, beneficiary, minReturnedTokens, memo, metadata)` | `JBSwapTerminal` | Accept any token, swap to `TOKEN_OUT` via Uniswap V3, forward to the project's primary terminal. Returns project token count from the downstream terminal. |
| `addToBalanceOf(projectId, token, amount, shouldReturnHeldFees, memo, metadata)` | `JBSwapTerminal` | Same swap flow but calls `terminal.addToBalanceOf(...)` instead of `terminal.pay(...)`. |
| `addDefaultPool(projectId, token, pool)` | `JBSwapTerminal` | Set the default Uniswap V3 pool for a token pair. Validates pool was created by the configured factory. Creates accounting context. Project 0 acts as a global default. |
| `addTwapParamsFor(projectId, pool, twapWindow)` | `JBSwapTerminal` | Set the TWAP window (2 min to 2 days) for a project's pool. Used for automatic slippage calculation. |
| `uniswapV3SwapCallback(amount0Delta, amount1Delta, data)` | `JBSwapTerminal` | Uniswap V3 callback: validates caller is the expected pool, wraps native tokens if needed, transfers input tokens to the pool. |
| `setTerminalFor(projectId, terminal)` | `JBSwapTerminalRegistry` | Route a project to a specific allowed swap terminal. |
| `lockTerminalFor(projectId)` | `JBSwapTerminalRegistry` | Lock the terminal choice for a project (irreversible). |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `nana-core-v5` | `IJBDirectory`, `IJBTerminal`, `IJBProjects`, `IJBPermissions` | Directory lookups (`primaryTerminalOf`), project ownership, permission checks (`ADD_SWAP_TERMINAL_POOL`, `ADD_SWAP_TERMINAL_TWAP_PARAMS`) |
| `nana-core-v5` | `JBMetadataResolver` | Parsing `quoteForSwap` and `permit2` metadata from calldata |
| `nana-core-v5` | `JBAccountingContext`, `JBSingleAllowance` | Token accounting and Permit2 allowance structs |
| `nana-permission-ids-v5` | `JBPermissionIds` | Permission ID constants |
| `@uniswap/v3-core` | `IUniswapV3Pool`, `IUniswapV3Factory`, `TickMath` | Pool swaps, factory validation, tick math |
| `@uniswap/v3-periphery` | `OracleLibrary` | TWAP oracle consultation (`consult`, `getQuoteAtTick`, `getOldestObservationSecondsAgo`) |
| `@uniswap/permit2` | `IPermit2`, `IAllowanceTransfer` | Gasless token approvals |
| `@prb/math` | `mulDiv` | Safe fixed-point multiplication |
| `@openzeppelin/contracts` | `Ownable`, `ERC2771Context`, `SafeERC20`, `IERC20Metadata` | Access control, meta-transactions, safe transfers |

## Key Types

| Struct/Enum | Key Fields | Used In |
|-------------|------------|---------|
| `JBAccountingContext` | `token`, `decimals`, `currency` | Stored per project+token in `_accountingContextFor`. Created by `addDefaultPool`. |
| `JBSingleAllowance` | `sigDeadline`, `amount`, `expiration`, `nonce`, `signature` | Decoded from `permit2` metadata key in `_acceptFundsFor`. |

## Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `DEFAULT_PROJECT_ID` | `0` | Global fallback for pool and TWAP config |
| `MIN_TWAP_WINDOW` | `2 minutes` | Minimum TWAP oracle window |
| `MAX_TWAP_WINDOW` | `2 days` | Maximum TWAP oracle window |
| `SLIPPAGE_DENOMINATOR` | `10,000` | Basis points denominator for slippage |
| `UNCERTAIN_SLIPPAGE_TOLERANCE` | `1,050` | Default 10.5% slippage when impact is zero |
| `MIN_DEFAULT_POOL_CARDINALITY` | `10` | Minimum oracle observation slots for `addDefaultPool` |

## Gotchas

- The terminal never holds a token balance. After every swap, all output tokens are forwarded and leftover input tokens are returned to the payer.
- `TOKEN_OUT` is an immutable set at construction. Each `JBSwapTerminal` instance targets exactly one output token.
- When `TOKEN_OUT == JBConstants.NATIVE_TOKEN`, the terminal unwraps WETH after swapping and sends native ETH to the downstream terminal.
- The `receive()` function only accepts ETH from the WETH contract (during unwrap). All other senders revert.
- Pool validation uses `FACTORY.getPool()` rather than create2 address derivation, so the terminal works on chains where Uniswap V3 factory bytecode may differ.
- TWAP fallback: when no observations exist (`oldestObservation == 0`), the terminal falls back to the pool's current spot tick and liquidity rather than reverting.
- Slippage tolerance is dynamically calculated from the swap's estimated price impact using a stepped bracket system (ranging from ~100 bps for tiny swaps to 88% for massive ones).
- `addDefaultPool` calls `pool.increaseObservationCardinalityNext(10)` to proactively set up TWAP history. `_getQuote` also reverts if observations are missing as a safety net.
- The `JBSwapTerminalRegistry` forwards Permit2 data internally and handles token custody during delegation.
- Metadata keys: `"quoteForSwap"` for the minimum output amount, `"permit2"` for gasless approvals.
- `_msgSender()` (ERC-2771) is used instead of `msg.sender` for meta-transaction compatibility.

## Example Integration

```solidity
// Deploy a swap terminal that converts any token to ETH
JBSwapTerminal swapTerminal = new JBSwapTerminal(
    directory,
    permissions,
    projects,
    permit2,
    owner,
    weth,
    JBConstants.NATIVE_TOKEN, // TOKEN_OUT = native ETH
    uniswapV3Factory,
    trustedForwarder
);

// Set a default USDC->WETH pool for project 1
swapTerminal.addDefaultPool(1, usdc, usdcWethPool);

// Set TWAP params: 30-minute window
swapTerminal.addTwapParamsFor(1, usdcWethPool, 30 minutes);

// Now anyone can pay project 1 with USDC:
// The terminal swaps USDC -> ETH via Uniswap V3, then forwards
// ETH to the project's primary ETH terminal.
swapTerminal.pay{value: 0}(
    1,           // projectId
    usdc,        // token (USDC)
    1000e6,      // amount (1000 USDC)
    beneficiary, // who receives project tokens
    0,           // minReturnedTokens
    "Payment via swap",
    ""           // metadata (empty = use TWAP quote)
);
```
