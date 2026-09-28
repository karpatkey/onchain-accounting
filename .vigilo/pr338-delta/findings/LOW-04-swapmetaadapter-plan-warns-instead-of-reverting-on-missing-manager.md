# LOW-04: `SwapMetaAdapter.plan()` only warns (does not revert) when the stamped executor Safe lacks `MANAGER`, and defaults to `securityCouncil` when `OPS_SAFE` is unset

## Summary

`SwapMetaAdapter.s.sol::plan()` writes an executable Safe-transaction batch stamped for
`vm.envOr("OPS_SAFE", cfg.securityCouncil)`. If that Safe does not currently hold `MANAGER` on the NAV — e.g.
because the operator forgot to set `OPS_SAFE`, or ran `plan()` before the role-granting step in the runbook
completed on that chain, or ran it after the Timelock migration revoked the council Safe's direct roles — the
script only logs a `console2.log` warning and still writes the batch file. The on-chain `_requireManager()`
guard makes this fail-safe (the whole atomic MultiSend batch reverts, no state changes), but it means a batch
that is guaranteed to fail can still be signed and submitted, consuming a full multi-signer round before
failing.

## Vulnerability Detail

### Root Cause

```solidity
// script/manage/SwapMetaAdapter.s.sol:360
address safe = vm.envOr("OPS_SAFE", cfg.securityCouncil);
```
```solidity
// script/manage/SwapMetaAdapter.s.sol:446-450
// Not a revert: the MANAGER grant may be a later, separate step, and refusing here would block preparing
// the batch in advance.
if (!navAdmin.hasRole(keccak256("MANAGER"), safe)) {
    console2.log("WARNING: the Safe does NOT hold MANAGER yet - grant it before executing this batch");
}
// @audit warning only — the batch is written and can be signed/submitted regardless. A missed console
//        line (piped logs, CI capture, inattentive operator) means signers spend a round on a batch that
//        will revert atomically at its very first call.
```

The default (`cfg.securityCouncil`) is meaningful: per `script/deploy/PR338_MIGRATION_RUNBOOK.md` §2, the
council Safe is granted `DEFAULT_ADMIN_ROLE`+`MANAGER` in Phase 1 before Phase 2's `plan()` batches are meant
to be prepared, so defaulting to it (rather than, say, `address(0)`) matches the currently-documented
production flow. But nothing enforces that ordering: `plan()` can be run (and will happily emit a signable
file) on a chain where that Phase 1 step has not yet landed, or — after `11_DeployTimelockController.s.sol`'s
default `safeRetains = false` path revokes the council Safe's direct roles in favor of the Timelock — on a
chain where the council Safe can no longer execute anything directly at all.

### Code Location

- File: `script/manage/SwapMetaAdapter.s.sol`
- Function: `plan()`
- Lines: 356-464 (specifically 360, 446-464)

## Impact

- **Likelihood**: Low-Medium — requires a runbook-ordering mistake (running `plan()` before the Phase 1 grant,
  or an env var omission), which the extensive `PR338_MIGRATION_RUNBOOK.md` is designed to prevent, but the
  script itself does not enforce the ordering it depends on.
- **Impact**: Low — the on-chain `_requireManager()` check on every call in the batch makes this fail closed:
  no unauthorized execution is possible, and the Safe MultiSend either succeeds in full or reverts in full.
  The cost is wasted signer effort and confusion, not a security bypass.
- **Severity**: LOW.

## Attack Scenario

Not attacker-triggerable — this is an operational safety gap in tooling used by trusted operators across a
24-chain rollout.

### Preconditions
- Operator runs `forge script script/manage/SwapMetaAdapter.s.sol --sig 'plan()' --rpc-url $RPC` on a chain
  where the target Safe (`OPS_SAFE` if set, else `securityCouncil`) does not yet hold `MANAGER`.

### Attack Steps
1. `plan()` completes successfully, printing a `WARNING` line that is easy to miss in verbose `forge script`
   output (especially when redirected to a log file or CI artifact) and writing
   `safe-transactions/<chainId>-swap-meta-adapters.json`.
2. The file is imported into the Safe Transaction Builder and circulated to the Safe's signers, who sign it
   based on the script having "succeeded."
3. On submission, the first call (`removeMetaInstances` or `removeBalanceAdapters`) reverts
   `NotAuthorized` via `_requireManager()`, and the entire MultiSend reverts.
4. The signing round is wasted; the operator must diagnose why, re-run Phase 1's grant, and repeat.

### Expected Impact
- Wasted multi-signer coordination effort per occurrence; no unauthorized state change is possible. Repeated
  across a 24-chain rollout this is a meaningful operational cost, not a fund-loss vector.

## Recommended Mitigation

Fail loudly rather than merely logging: either revert `plan()` when the resolved Safe lacks `MANAGER` (with
an explicit `FORCE=true`-style override for the legitimate "prepare in advance" use case the current comment
defends), or have `writeSafeTx` embed the `hasRole` result into the emitted JSON/description so the
mismatch is visible to whoever reviews the batch in the Safe UI, not only in the `forge script` console
output.
