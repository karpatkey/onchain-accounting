# MEDIUM-02: No automated, fleet-wide check confirms all 8 asset chains actually completed the PR #338 meta-adapter swap — per-chain "address unchanged, adapter did not move" is console-log only

## Summary
`SwapMetaAdapter.plan()` correctly *skips* an adapter pair it should not touch (successor not yet deployed,
predecessor already swapped, address unchanged, etc.) and logs the reason to the console
(`SwapMetaAdapter.s.sol:386-401`). That per-invocation skip logic is sound in isolation (confirmed by
INFO-01/prior pass), but nothing aggregates these per-chain, per-adapter outcomes across the 8 asset chains
(1, 10, 56, 100, 137, 8453, 42161, 5042) into a single "is the fleet migration actually complete and consistent"
signal. A chain that never had `04` re-run against it (so every adapter's address is unchanged) produces the
exact same "nothing to do" console output as a chain that correctly has nothing left to swap because it already
finished — the two states are indistinguishable without a human reading and correctly interpreting 7 separate
script runs' stdout.

## Vulnerability Detail

### Root Cause
- File: `script/manage/SwapMetaAdapter.s.sol`
- Function: `plan()`
- Lines: 382-401

```solidity
if (newA == address(0)) {
    console2.log("  skip (successor not in deployments record - 04 not run yet?):", names[i]);
    continue;
}
...
if (old == newA) {
    console2.log("  skip (address unchanged - adapter did not move):", names[i]);
    continue;
}
```

Both branches are silent with respect to any AUTOMATED downstream check: they `continue` the loop, and if every
adapter on a chain hits one of these branches, `swapped == 0` and the function reverts `NoMetaAdaptersToSwap`
(line 435) — which, on the FIRST run against a chain that genuinely has nothing to do (either because `04` was
never re-run, or because the swap already completed), looks identical to a correctly-finished chain. An operator
watching a batch script iterate over 8 chains has no single artifact to consult that says "chain 100 is done,
chain 137 is not."

The closest existing automated check, `bytecode_audit.py` / `.github/workflows/bytecode-drift.yml`, is a
**general-purpose STALE-address detector that runs daily on `main`**, not a migration-completion gate: per its
own documentation in `REDEPLOY_RUNBOOK.md` (§0.3b), *"anything deployed OUTSIDE a full redeploy never reaches
step 2.2"* unless it is separately wired into the accepted-drift baseline, and it answers "is this recorded
address's bytecode current" per already-recorded key — it does not answer "did every chain that needed a swap
actually get one," nor does it cross-reference `SwapMetaAdapter.plan()`'s skip reasons.

### Consequence for the 8-chain PR #338 rollout specifically
Because each of the 8 asset chains is migrated by an **independent** invocation of `04` + (clear) +
`SwapMetaAdapter.plan()`/execute, and because (per HIGH-01) the `plan()` path currently has an unresolved input
dependency that could cause it to silently no-op on a subset of chains, there is no single command or CI check an
operator can run at the END of the rollout to assert "all 8 chains have zero meta adapters still pointing at a
pre-#338 address." The fleet-wide correctness of this migration currently rests entirely on an operator manually
re-running `plan()` per chain and reading its console output correctly, 8 times, with no diff against an expected
"fully migrated" state.

## Impact
- **Likelihood**: Medium — the individual per-chain mechanics are sound (see INFO-01), but nothing forces the
  operator to notice a chain that was accidentally skipped (e.g. because the deploy-record clear step, per
  `reset_deployment_records.py`, was scoped to fewer than the full 8-chain list, or because `04` failed
  partway through one chain's broadcast and was not re-run).
- **Impact**: Medium — a chain left un-migrated stays on pre-#338 bytecode (whatever correctness/gas-metering
  improvement #338 delivers is absent there), which is a functional/consistency gap rather than a direct
  fund-loss vector on its own, but compounds with CRITICAL-02/HIGH-01: a half-migrated fleet is exactly the state
  in which an operator is most likely to reach for `06_Configure` on the "stuck" chain to try to fix it, walking
  directly into the double-registration path.
- **Severity**: MEDIUM.

## Attack Scenario
### Preconditions
- 7 of the 8 asset chains have completed `04` + `SwapMetaAdapter.plan()`/execute. One chain (say, chain 137)
  was accidentally left out of the deployment-record clearing step's chain scope.

### Attack Steps
1. `04_DeployBalanceAdapters` is re-run on chain 137, but because its record was never cleared, every
   `_deployIfEnabled` call early-returns ("Already deployed at: <OLD address>") — no new addresses are written.
2. `SwapMetaAdapter.plan()` on chain 137 finds `old == newA` for every adapter (the record was never updated) and
   logs "skip (address unchanged - adapter did not move)" for all of them, then reverts `NoMetaAdaptersToSwap`.
3. The operator, having just seen 7 chains complete successfully, interprets this revert as "chain 137 had
   nothing to swap" (a legitimate, common outcome for a chain with few meta adapters) rather than "chain 137's
   redeploy step never ran," and moves on.
4. Chain 137 is now the only chain still running pre-#338 `MetaBalanceAdapter` bytecode, with no artifact
   recording that fact anywhere in the repo, discoverable only by manually diffing chain 137's live adapter
   bytecode against the other 7 chains.

### Expected Impact
- Fleet inconsistency: one chain's NAV calculations run against stale meta-adapter logic (whatever bug or gas
  behavior #338 fixes) indefinitely, until a manual, ad hoc cross-chain audit catches it.

## Recommended Mitigation
1. Extend `bytecode_audit.py` (or a new preflight script) to also assert, per chain in the 8-chain asset scope,
   that every `balanceAdapters.<metaAdapterName>` address's on-chain bytecode hash matches the CURRENT
   `type(X).creationCode`-derived hash (not just "is it stale relative to some accepted-drift baseline") —
   i.e. a positive "this chain is fully on the new generation" assertion, not only a negative "this address
   drifted" one.
2. Have `SwapMetaAdapter.plan()` distinguish, in its revert/log output, between "nothing to swap because `04`
   was never re-run here" (successor absent) and "nothing to swap because migration already completed"
   (successor present and matches predecessor's former instance set) — these currently share the same
   `NoMetaAdaptersToSwap` outcome and console phrasing family.
3. Add a single fleet-wide summary command (or CI job) that runs `plan()`'s dry-run/logging phase across all 8
   chains and fails if any chain reports "successor not in deployments record" for an adapter enabled in that
   chain's `contracts-deployment-config/meta-balance-adapters/<chainId>.json`.
