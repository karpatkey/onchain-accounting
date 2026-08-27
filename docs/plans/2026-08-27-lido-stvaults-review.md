# Review plan — Lido stVaults meta adapter (PR #330)

**Question:** what does a pre-merge review of PR #330 need to cover that a diff-scoped review structurally cannot?
**Date:** 2026-08-27. **Produced by** the Fable planner via `/fable-review` against head `f344b909`.
**This file is a condensation of that plan plus the adjudications made when implementing it** — the rulings are
recorded here, not the full prose.

## The plan's core insight

Treat this as a **pre-freeze audit of an immutable artifact plus a divergence audit of its off-chain gate**, not a
re-derivation of the Lido measurements. Merge is the real freeze point: the adapter is immutable and
`_deployIfEnabled` is skip-if-deployed, so anything not fixed before merge needs a redeploy.

Rejected alternatives, with reasons: re-verifying the mainnet measurements (already triangulated three ways —
chain, Lido's spec, Lido's UI); expanding the fork suite per-vault (per-vault figures rot at every block bump,
and the durable claims are already asserted as identities); re-litigating the adjudicated set.

## Findings and what was done

| # | Finding | Ruling |
|---|---|---|
| C1 | Fixed-stipend probes: a starved read drops the instance silently, and `InstanceGasExhausted` can never fire because the adapter absorbs its own OOG | **ADJUDICATED, not fixed.** Euler uses metered probes because *its* starvation is an over-report; here the credit leg drops with the debt legs, so the direction is under-report. Metering would trade a tolerated failure for an availability one. Written up on the adapter; the preflight gate now eth_calls every hub selector per instance so the silence is *detectable*, and the adjudication names that gate as the channel it depends on. |
| C3 | `_feeObligation` skipped `accruedFee()` when `account == owner`, on a stated reason the PR's own evidence refutes | **FIXED** — probed on both paths. Over-report closed. |
| C4 | Preflight masked a non-address instance coordinate instead of rejecting it | **FIXED** — ERRORs. |
| C9 | Constructor accepted aliased arguments | **FIXED**. |
| C2 | No liveness signal for selector drift | **FIXED** — the gate probes `totalValue`/`liabilityShares`/`obligations` per instance. |
| C6 | The gate shipped untested and inert | **FIXED** — six `--self-test` arms (CI runs `--self-test`). |
| C7 | Hand-rolled gas literal | **FIXED** — symbolic `PROBE_GAS`. |
| C8 | Docs lag: `(22)`, missing matrix rows, `Fees`-as-debt undocumented | **FIXED**. |
| C5 | A wrong-but-successful value from an upgraded Lido contract is consumed silently | **ACCEPTED.** No on-chain instrument exists; bounded by Lido governance + MANAGER curation of instances. |
| C10 | `vaultConnection` struct layout drift | **ACCEPTED** — covered by the fork test at block-bump time. |

## Termination condition

Closed when C1 carries its written adjudication, C3/C4/C9 are fixed with revert-probed regression tests, the gate
has self-test arms, and the docs match. **Reached at `a8cc424b`.**

## Residual risk, knowingly accepted

- A wrong-but-successful value from an upgraded Lido contract is consumed silently (C5).
- Integration exercises only the inert path until karpatkey holds a stVault, so the fork test plus the
  (now live-probing) preflight gate are the whole of real coverage.
- Fee and value reads lag the true figures between oracle reports, **under-reporting** net equity, bounded by
  accrual-since-report — measured up to 7.46% of one vault.
- The multi-admin double-count is narrowed by the gate but not closed: roles are mutable, so a second admin
  granted after the gate runs re-opens it. Mitigation is governance.
