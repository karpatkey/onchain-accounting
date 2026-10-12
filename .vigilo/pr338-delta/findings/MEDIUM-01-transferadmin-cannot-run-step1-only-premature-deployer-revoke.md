# MEDIUM-01: `07_TransferAdminToSecurityCouncil` cannot be run "step 1 only" — the runbook's staged plan is unenforceable, risking premature loss of the deployer's escape-hatch role

## Summary

`script/deploy/PR338_MIGRATION_RUNBOOK.md` instructs the operator to run only "step 1" of
`07_TransferAdminToSecurityCouncil.s.sol` (grant council `DEFAULT_ADMIN_ROLE`+`MANAGER`) during Phase 1, and
explicitly **not** to run its steps 2-3 (revoke/renounce the deployer's roles), because the deployer's
`MANAGER` is the required "escape hatch" for the EOA-only Phase 3 step (`RealignHeartbeats.s.sol`). But the
script has no such partial-execution mode: `run()` always performs all three steps atomically inside one
`vm.startBroadcast()`/`stopBroadcast()` pair. An operator who actually executes the script as named — rather
than as the runbook's prose implies — strips the deployer of `MANAGER` immediately, before Phase 3 has run,
breaking the deployer-only heartbeat-realignment step the runbook says depends on it.

## Vulnerability Detail

### Root Cause

The runbook's instruction:

```text
Finally, grant DEFAULT_ADMIN_ROLE and MANAGER on the NAV to the council Safe — step 1 only of
07_TransferAdminToSecurityCouncil (:81-92). **Do not run its steps 2-3** (:95-102): the deployer
must keep both roles as the escape hatch until every chain finishes Phase 3.
```

But the script's `_handoff` — the only entry point that performs the grant — executes grant, revoke, and
renounce unconditionally, in one broadcast, with no flag to stop after the grant:

```solidity
// script/deploy/07_TransferAdminToSecurityCouncil.s.sol:71-105
function _handoff(address target, string memory label, address deployer, address council) internal {
    ...
    vm.startBroadcast();

    // 1. Grant DEFAULT_ADMIN_ROLE + MANAGER to the council (while the deployer still holds admin).
    if (!IAccessControl(target).hasRole(DEFAULT_ADMIN_ROLE, council)) {
        IAccessControl(target).grantRole(DEFAULT_ADMIN_ROLE, council);
        ...
    }
    if (!IAccessControl(target).hasRole(MANAGER, council)) {
        IAccessControl(target).grantRole(MANAGER, council);
        ...
    }

    // 2. Revoke MANAGER from the deployer EOA.
    if (IAccessControl(target).hasRole(MANAGER, deployer)) {
        IAccessControl(target).revokeRole(MANAGER, deployer);
        // @audit no way to opt out of this step — runs unconditionally whenever run() is invoked
    }

    // 3. Renounce DEFAULT_ADMIN_ROLE from the deployer EOA (OZ v5: 2nd arg must equal msg.sender = deployer).
    IAccessControl(target).renounceRole(DEFAULT_ADMIN_ROLE, deployer);
    // @audit no way to opt out of this step either — the deployer's escape-hatch is gone the instant
    //        this script is broadcast, contradicting the runbook's "step 1 only" instruction

    vm.stopBroadcast();
    ...
}
```

`run()` calls `_handoff` unconditionally for the NAV proxy, the bridge proxy, and every deployed bridge
adapter (lines 45-64) — there is no env var, no `--sig` alternate entry point, and no way to invoke "grant
only." The script's own top-of-file docstring documents this as a single, indivisible three-step sequence
(lines 14-23: "1. grant ... 2. revoke ... 3. renounce ..."), which is internally consistent with the code but
directly contradicts the runbook's assumption that steps can be selectively executed.

### Code Location

- File: `script/deploy/07_TransferAdminToSecurityCouncil.s.sol`
- Function: `run()` / `_handoff()`
- Lines: 27-68 (`run()`), 71-105 (`_handoff()`)

- File: `script/deploy/PR338_MIGRATION_RUNBOOK.md`
- Lines: 113-115

## Impact

- **Likelihood**: Medium — this fires only if the operator invokes the script literally as its filename and
  `--sig` suggest (its documented invocation, `forge script ... --broadcast`, is exactly `run()`, which is the
  all-three-steps path); an operator who reads the runbook closely enough to notice the "step 1 only" caveat
  is likely to also notice the script offers no way to honor it, but the runbook gives no alternative
  procedure (e.g., a manual `cast send` for the grant only) to actually follow its own instruction.
- **Impact**: Medium — if run, the deployer immediately loses `MANAGER` (and admin) on the NAV proxy, the
  bridge proxy, and every bridge adapter, on that chain, before Phase 2/3 of the PR #338 migration complete.
  Phase 3's `RealignHeartbeats.s.sol` is documented as "EOA-only — no `writeSafeTx` path, so it needs the
  deployer's `MANAGER`" (runbook §5) — losing it early blocks that phase outright on the affected chain until
  the operator manually re-grants `MANAGER` to the deployer via the (now sole holder) council Safe, which is
  itself an unplanned, undocumented, manual privileged operation squeezed into the middle of a scripted
  migration.
- **Severity**: MEDIUM — temporary, chain-scoped DoS of the migration's Phase 3 step, recoverable only via an
  out-of-band privileged action not covered by any script or runbook text.

## Attack Scenario

This is an operational/process-safety gap rather than an externally-triggerable exploit — there is no
attacker distinct from the operator. The "attack" is the runbook and code disagreeing about what the script
does:

### Preconditions
- Operator is executing Phase 1 of the PR #338 migration runbook and reaches the "Finally, grant..." step.

### Attack Steps
1. Operator runs `forge script script/deploy/07_TransferAdminToSecurityCouncil.s.sol --rpc-url $RPC --account
   $DEPLOYER_NAME --broadcast`, following the script's own header docstring's documented invocation.
2. `_handoff` executes all three steps atomically: council is granted admin+MANAGER, deployer's MANAGER is
   revoked, deployer's admin is renounced — all in the same transaction batch, on the NAV proxy, the bridge
   proxy, and every deployed bridge adapter.
3. Operator proceeds to Phase 2 (meta-adapter swap batches) and Phase 3 (`RealignHeartbeats.s.sol`, which
   requires `--account kpk-deployer` to hold `MANAGER`).
4. `RealignHeartbeats.s.sol` reverts (`NotAuthorized`) on every call, because the deployer no longer holds
   `MANAGER` — Phase 3 cannot proceed on this chain via the documented EOA path.

### Expected Impact
- Phase 3 (heartbeat realignment) is blocked on the affected chain until an operator performs an
  out-of-band, undocumented `grantRole(MANAGER, deployer)` from the council Safe — extra manual privileged
  action, and extra risk surface, introduced purely by the runbook/script mismatch.

## Recommended Mitigation

Either (a) split `07_TransferAdminToSecurityCouncil.s.sol` into a grant-only entry point (e.g. a `--sig
'grantOnly()'` variant of `_handoff` that performs only step 1) that the runbook can actually invoke for Phase
1, and a separate revoke entry point for the final handoff; or (b) update the runbook to stop describing
"step 1 only" as achievable via this script and instead specify the exact `cast send grantRole(...)` calls
that must be run manually during Phase 1, with steps 2-3 of this script reserved for the real end-of-migration
handoff.
