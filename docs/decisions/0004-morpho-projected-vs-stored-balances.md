# 0004 — Morpho Blue: project pending interest into NAV (vs use stored values)

**Status:** accepted

## Context

`MorphoMarketBalanceOracle` (`src/balances/protocols/MorphoMarket.sol`) reads a user's lending position in a Morpho Blue market by:

1. Calling `MORPHO.position(marketId, account)` to get the user's `supplyShares` / `borrowShares` / `collateral`.
2. Calling `MORPHO.expectedMarketBalances(marketParams)` (from `morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol`) to get the *projected* `totalSupplyAssets` / `totalSupplyShares` / `totalBorrowAssets` / `totalBorrowShares` *after accruing interest forward to `block.timestamp`*.
3. Computing `suppliedAssets = totalSupplyAssets × supplyShares / totalSupplyShares` (rounded down) and the analogous borrow side (rounded up).

`expectedMarketBalances` differs from a raw `MORPHO.market(id)` read in one respect: it folds the IRM-implied accrual between `lastUpdate` and `block.timestamp` into both `totalBorrowAssets` and `totalSupplyAssets` before returning. For a market that hasn't been touched recently, this can amount to a large delta — especially at high utilization, where Morpho's Adaptive Curve IRM produces aggressive borrow rates.

This choice came up empirically during the integration-test Debank cross-check (PR #19 workflow). At one point, ACCOUNT_1 on Mainnet showed a ~3% drift between our NAV and Debank's portfolio total. Tracing it line by line landed on a single position: a small USDC supply in the **wstUSR/USDC** Morpho Blue market. At that moment the market was ~24 days past its last touch and at 100% utilization, so the projection inflated supply assets by ~53% over the stored value. Stored value: $10.34. Projected value: $15.83. Debank reports the stored value.

## Decision

Continue using `expectedMarketBalances` (projected). Do **not** switch to `market(id)` (stored).

The user's economic claim on a Morpho market includes *all* accrued-but-not-yet-poked interest: when they next interact (deposit / withdraw / liquidation / anyone else trades), Morpho's `_accrueInterest` mints supply assets to the cumulative supply pool and the user's share fraction redeems against the larger total. The projection is what they would actually receive if a withdrawal *could* happen this instant.

Morpho's own UI and the `MorphoBalancesLib` library — both maintained by Morpho Labs — adopt the same convention. Borrowing the published library here keeps us consistent with the protocol's authoritative view.

## Consequences

**Positive:**

- NAV reflects the user's economic claim, not just the on-chain audit-stable state. For long-elapsed, high-utilization markets, the difference is non-trivial; using stored values would systematically under-state NAV.
- Behavior matches Morpho's UI and on-chain `accrueInterest` semantics — a user who pokes the market via any operation immediately realizes the projected number, so the projection is not "imaginary," it's "uncrystallized."
- One less special case: every other adapter we have (Aave V3, Compound III, etc.) reports realtime balances that include uncrystallized interest accrual; using projected values for Morpho keeps that pattern consistent.

**Negative / things to watch:**

- **Persistent drift against Debank for affected positions.** Debank uses stored values, so accounts holding Morpho Blue positions in markets with stale `lastUpdate` and high utilization will show NAV > Debank by the projection delta. This is *expected* and not a bug. The integration-test Debank cross-check workflow (`script/test/refresh-integration-snapshot.sh`) will surface this as a tolerance violation; reviewers should triage with this ADR in mind. See `docs/howto/refresh-integration-test-blocks.md` "Tolerance failures — how to triage" for the standard workflow.
- **Projection is not realizable while utilization is at 100%.** The projected supply value reflects what the user *would* receive if a withdrawal happened, but if the market is fully utilized, withdrawals revert until borrowers repay. NAV technically over-states immediately liquid value in those cases. Acceptable: NAV is a portfolio valuation, not a liquidity metric.
- **Projection is sensitive to IRM behavior.** A future Morpho upgrade that changes the IRM math, or a new market with an unusual IRM, could produce surprising projections. If we ever see a multi-percent drift from a Morpho position with no obvious cause, double-check the IRM rate at the last update vs now.

## Alternatives considered

1. **Use `market(id)` (stored values).** Rejected: matches Debank but systematically under-states NAV during long-elapsed accrual periods, and diverges from Morpho's own UI and library convention. Would also introduce a per-protocol valuation policy split (every other adapter projects accrual; only Morpho would not).
2. **Use `expectedMarketBalances` but cap supplied assets at `totalSupplyAssets − totalBorrowAssets`** (i.e., what's withdrawable now). Rejected: makes valuation non-monotonic in utilization and breaks the "fractional claim on the pool" mental model. We don't cap any other adapter at "currently withdrawable," and shouldn't here.
3. **Switch protocols' projection on/off via config.** Rejected: configuration surface for a single edge case; future contributors would never know about the toggle. A single explicit policy with a documented rationale is simpler.

## Reference

- Adapter: `src/balances/protocols/MorphoMarket.sol`, especially `_calculateBalance` (the share-to-assets conversion).
- Morpho library used: `lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol`, function `expectedMarketBalances`.
- Triage workflow when this surfaces in cron CI: `docs/howto/refresh-integration-test-blocks.md` § "Tolerance failures".
- Empirical case study: ACCOUNT_1 on Mainnet, `MorphoMarket_wstUSR_USDC` market id `0xd9e34b1eed46d123ac1b69b224de1881dbc88798bc7b70f504920f62f58f28cc`, surfaced via the first cron run of the refresh workflow (commit `3cb1d71` on main, `2026-05-01T23:11Z`).
