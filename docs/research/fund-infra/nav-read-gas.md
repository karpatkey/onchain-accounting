# NAV-read gas on a mainnet fork

Block 26,500,000 (chain 1). EIP-7825 per-tx cap: 16,777,216 gas.
Test: `test/poc/fundconfig/FundConfigNavGas.fork.t.sol`. Data: `gas-nav-read.json`.

Command: `FOUNDRY_PROFILE=slow forge test --match-path test/poc/fundconfig/FundConfigNavGas.fork.t.sol -vv`
Result: 7 passed, 0 failed (last run, exit 0, 204 s).

## Method

- **Cold:** `vm.cool` on FundConfig, Safe, NAV proxy, Morpho/Aave/Curve adapters, USDC, CRV, and the declared vaults/gauge. Feeds are not cooled. First read in the test.
- **Warm:** the identical call repeated immediately.
- **Production:** `getAccountNav(account, address(0))` on a fresh fork per account. Cold = first call, warm = repeat.
- A single tx starts cold, so cold is the per-tx figure. Warm applies only to later reads inside the same tx.
- The production block is 26,500,000, not 25,735,412. The NAV proxy `0x54EaD2A1…6214` is absent at 25,735,412. Account values differ from the 25.7M numbers in earlier notes.

## Production accounts: `getAccountNav` today

| Account | Cold gas | Warm gas | Over cap (cold) | Value (USD, 8dp) |
|---|---|---|---|---|
| ACCOUNT_2 | 17,470,450 | 9,521,950 | +693,234 | 58,094,797,709,493 (≈$0.58M) |
| ACCOUNT_9 | 18,075,592 | 9,976,092 | +1,298,376 | 1,698,251,351,540,557 (≈$16.98M) |
| ACCOUNT_10 | 18,922,229 | 10,313,229 | +2,145,013 | 8,112,344,709,219,076 (≈$81.12M) |

No stale price assets, and `quoteAssetStale` is false for all three. All three exceed the cap cold.

## fundNav per type (USDC quote, one fund per row)

| Case | Cold | Warm | Value / stale |
|---|---|---|---|
| Empty fund (no positions) | 3,633 | 1,633 | 0, not stale |
| Morpho, zero balance (N=1) | 301,281 | 124,281 | 0 |
| Morpho, funded (100k USDC) | 298,337 | 213,337 | 100,000 USDC, not stale |
| Aave V3 USDC, funded (100k) | 1,143,239 | 534,739 | 100,000 USDC, not stale |
| Curve gauge, zero balance | 58,222 | 34,722 | 0 |

Aave funded cold is about 1.14M for a single position. Its per-position marginal is much larger than Morpho's.

## fundNav scaling, zero-balance Morpho positions

| N | Cold | Warm |
|---|---|---|
| 0 | 3,633 | 1,633 |
| 1 | 301,281 | 124,281 |
| 2 | 273,999 | 181,499 |
| 4 | 815,272 | 443,772 |
| 8 | 1,141,036 | 694,036 |
| 12 | 1,579,499 | 986,499 |

Fits (`gas = a + b·N`):
- **Warm**, N ∈ {1,2,4,8,12}: a = 62,198, b = 78,485 per position. Max N under cap: **213**.
- **Cold**, N ∈ {2,4,8,12}: a = 167,205, b = 120,807 per position. Max N under cap: **137**. N=1 cold (301k) is a first-touch outlier and is excluded.

## CRV staleness control

| Test | Before warp | After +1 day |
|---|---|---|
| CRV held, gauge declared | stale = false | stale = true |
| USDC held, Morpho declared | stale = false | stale = true |

The +1 day warp stales the USDC path too. The held-CRV result therefore does not isolate CRV. The staleness is time-driven: the 24h-heartbeat feeds go stale after a 1-day warp.
`findings-curve-crv.md` §2 is consistent with that, but CRV-specific staleness is not confirmed.

## Subscription: can the NAV be used on subscription?

Verdict: **sync (1) works for small funds only. Async (2) has the same per-tx ceiling. Oracle (3) is the fallback, and is not optimal.**

1. **Sync (NAV computed inside each subscription/redemption tx).**
   - Works for a FundConfig fund up to about **137 cold** Morpho-type positions (213 warm). The subscription tx adds mint/deposit gas on top, so budget with headroom.
   - Does not work today for the production accounts: `getAccountNav` is 17.5–18.9M cold for ACCOUNT_2/9/10, all over the cap.
   - Aave-heavy funds reach the cap much sooner: one funded Aave position costs 1.14M cold.
2. **Async (ERC-7540-style, one NAV per settlement tx for a batch).**
   - Batching amortizes the NAV cost across requests. It does not raise the per-tx ceiling, and the settlement tx itself must fit.
   - Needed when the user-paid sync NAV gas per subscription is too high. Not needed when the cap binds, because batching does not help there.
   - Production accounts 2/9/10 still do not fit in one settlement tx.
3. **Oracle (pushed NAV, e.g. ERC-8330 snapshot or keeper-posted value).**
   - Feasible, **not optimal**. Costs: keeper update txs paid on a cadence, plus computing the NAV to post it (off-chain or on-chain).
   - Lags: the price is as old as the last push, which opens NAV-timing arbitrage. Bound it with staleness checks.
   - Fallback when the cap binds (large production accounts).

## fundNav inefficiency (noted, not fixed; fixes in [fundconfig-poc.md § Ideas to improve](fundconfig-poc.md#ideas-to-improve))

- One `NAV_CALCULATOR.calculateValue` call per leg and per wallet token.
- `_walletTokens` is O(N²).
- `_moduleAt(i)` re-resolves through `REGISTRY.moduleOf` on each pass.
- `_balances` goes through `module.accounting` on each call.

## Caveats

- Feed contracts are not cooled. Their warmth is whatever the fork gives them, so cold may understate the feed component. Not measured separately.
- Fail-open stipends mean a failing adapter adds a stipend-capped cost, not a revert. Not separately measured.
- [INFERENCE] Price-feed reads likely dominate the production totals; not measured. The per-type costs above are not a production composition.
- Unmeasured: EtherFi, UniswapV3 LP, funded Curve pool/gauge, Aave borrow, and the other meta families. Production composition at 26.5M was not broken down by type.
- The `subscription` verdict uses the fit values and the production totals above. Per-position costs for production mixes are not derived.
