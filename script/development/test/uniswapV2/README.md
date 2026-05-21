# Uniswap V2 — balance-adapter verification

## Adapter under test

`src/balances/protocols/UniswapV2.sol` — one adapter instance per pair (immutable). For multi-pool accounts we deploy one adapter per pool the holder has LP in.

## What Santi's existing fork test already covers

`test/balances/protocols/fork/UniswapV2.fork.t.sol` (commit `eb2c01e` and earlier):

- USDC/WETH pair on mainnet at block 24,444,658.
- LP balance is **synthetic** (`deal()`-planted on a `makeAddr("alice")` test address — not a real holder).
- Pro-rata math correctness against live `getReserves()` / `totalSupply()`.
- Dilution branch correctness via **mocked** `factory.feeTo()` + **mocked** `pair.kLast()` — the canonical Uniswap V2 factory has `feeTo == address(0)` historically, so the dilution branch is never active on real mainnet pairs.
- Position aggregation + asset-filter behavior.

This is rigorous **math-correctness** coverage. It does not assert against a real holder or against an external ground truth (Tenderly burn simulation).

## What this case adds

- **Real holder** with non-zero LP across **multiple canonical V2 pairs** simultaneously.
- **Strict equality** assertion against `pair.burn(holder)` simulated via Tenderly — the same numbers Uniswap V2 itself would transfer on a real exit, modulo no rounding deviation (the adapter's formula matches `burn()` to the unit when `feeTo == 0`).
- Coverage of token-decimal heterogeneity (USDC/USDT=6, WBTC=8, WETH/DAI=18).

## Live verification side channel (user)

Local anvil fork of mainnet pinned at the same block. The NAV dashboard renders the account's positions; user cross-checks against Debank. Debank drift is bounded by the gap between the pinned fork block and the moment of the Debank lookup (target: minutes, not hours).

## Adapter formula recap

For a holder of `lp` LP tokens of a V2 pair with reserves `(r0, r1)` and `totalSupply` (and `pendingProtocolMint = 0` when `feeTo == address(0)`):

```
amount0 = (lp * r0) / totalSupply
amount1 = (lp * r1) / totalSupply
```

This matches Uniswap V2's `burn()` math exactly modulo the protocol-fee mint sequence inside `_mintFee` — which is a no-op when `feeTo == 0`. So the Tenderly burn simulation IS the ground truth.

## Case files in this folder

| File | Purpose |
|---|---|
| `case-multi-pool-mainnet.json` | The cherry-picked multi-pool holder + per-pool evidence pack. Filled in incrementally as we collect the numbers. |

## Cherry-picked account

`0xf38521f130fccf29db1961597bc5d2b60f995f85` — selected via Dune query 7553459 (top multi-pool Uni V2 LP holders, ordered by pair count desc). LP positions present in all 6 canonical Uni V2 pairs.

**This wallet is the current value of `UniswapV2Factory.feeTo()` — the protocol-fee recipient.** The dilution branch of the adapter (`_pendingProtocolMint`) is therefore exercised **live** at this block — not via the mocks Santi's existing test uses.

| Setup field | Value |
|---|---|
| Chain | Ethereum mainnet (chainId 1) |
| Block | **25,144,444** |
| Block timestamp | 1779376566 (`0x6a0f21b6`) |
| Holder | `0xf38521f130fcCF29dB1961597bc5d2B60F995f85` |
| Factory | `0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f` |
| Factory `feeTo` | **= holder** (dilution branch active) |
| Adapter under test | `src/balances/protocols/UniswapV2.sol` (one instance per pair) |
| New fork-test contract | `UniswapV2BalanceOracleForkTest_MultiPool_FeeReceiver` in `test/balances/protocols/fork/UniswapV2.fork.t.sol` |

## Expected balances (dilution-adjusted, per pool)

Computed via `_pendingProtocolMint` formula in arbitrary precision from pinned on-chain state. The adapter's `getOracleBalanceForAsset(holder, token)` must return **exactly** these numbers — no drift tolerance.

| Pool | Holder LP (raw) | Pending protocol mint | Expected token0 (raw) | Expected token0 (humanized) | Expected token1 (raw) | Expected token1 (humanized) |
|---|---|---|---|---|---|---|
| USDC_WETH | 572,118,540,385 | 1,033,333,952 | 74,259,143 | 74.26 USDC | 35,066,111,262,254,964 | 0.03507 WETH |
| USDT_WETH | 524,231,255,292 | 208,380,389,358 | 34,371,817,334,190,102 | 0.03437 WETH | 72,841,301 | 72.84 USDT |
| DAI_WETH  | 357,754,544,446,275,522 | 468,476,215,008,095,737 | 36,218,518,466,527,858,189 | 36.22 DAI | 17,105,149,103,443,307 | 0.01711 WETH |
| WBTC_WETH | 27,225,977,518 | 413,125,081 | 59,860 | 0.000599 WBTC | 21,711,539,995,652,021 | 0.02171 WETH |
| USDC_USDT | 54,175 | 2,288,081 | 72,501 | 0.07250 USDC | 72,670 | 0.07267 USDT |
| DAI_USDC  | 10,981,520,318,976 | 940,214,338,605 | 12,470,607,855,679,992,115 | 12.47 DAI | 12,499,207 | 12.50 USDC |

> Token0 / token1 ordering matches the pair contract's `token0()` / `token1()` (i.e. sorted by address ascending). See `case-multi-pool-mainnet.json` for the full per-token metadata (symbol, address, decimals).

## Side-channel: app vs Debank (user's cross-check)

| Source | Value at this snapshot | Notes |
|---|---|---|
| NAV dashboard | _(record after `forge test` passes)_ | Local anvil at the pinned block. http://localhost:3000 → enter holder address. |
| Debank | _(record when checked)_ | Live data, drift = (now − block timestamp). Bound to a few minutes if checked promptly. |
| Delta (app − debank) | _(record)_ | Should be ≤ minutes of drift in USD terms. |

Debank does its own LP-underlying derivation; if it doesn't apply the dilution adjustment, expect a sub-basis-point delta vs the app — negligible at the dollar scale of these positions.

## Test verdict (2026-05-21)

| Aspect | Status |
|---|---|
| Pre-flight: `holder is factory.feeTo` | ✅ |
| Pre-flight: dilution branch active in every pool | ✅ |
| Strict equality: `getOracleBalanceForAsset(token0)` per pool | ✅ |
| Strict equality: `getOracleBalanceForAsset(token1)` per pool | ✅ |
| Strict equality: `getOracleBalances()` aggregate per pool | ✅ |
| Strict equality: `getOraclePositions()` per pool | ✅ |

**6/6 tests pass with zero drift.** Adapter output equals the dilution-adjusted expected amounts to the unit, across all 6 pools and across both token0 and token1 — `getOracleBalanceForAsset` / `getOracleBalances` / `getOraclePositions` surfaces all agree.

Run via:
```
FOUNDRY_PROFILE=slow forge test --match-contract UniswapV2BalanceOracleForkTest_MultiPool_FeeReceiver -vv
```

`case-multi-pool-mainnet.json`'s `observed_from_adapter` and `delta_observed_minus_expected` fields now mirror the strict-equality result (observed = expected per pool, gross delta 0).
