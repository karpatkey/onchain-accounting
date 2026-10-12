# CRITICAL-01: Throwaway ops-Safe's `MANAGER` grant is never revoked by any script — permanent unauthorized NAV control survives the "migration complete" state

## Summary

The PR #338 migration path lets the operator run the meta-adapter swap through a **throwaway 1/1 ops Safe**
that is granted `MANAGER` on `NAVCalculator` (via `SwapMetaAdapter.s.sol`'s `OPS_SAFE` env var). No script in
this repository ever revokes that grant. `11_DeployTimelockController.s.sol` — the step that is supposed to
finalize governance and strip every non-Timelock holder of `DEFAULT_ADMIN_ROLE`/`MANAGER` — only knows about
two addresses, `deployer` and `chainConfig.securityCouncil`. After the full migration (deploy Timelock → grant
Timelock → revoke deployer → revoke council) is declared complete, the ops Safe **still holds `MANAGER` on
every chain where it was used**, indefinitely, with no tripwire anywhere in the repo to detect it.

## Vulnerability Detail

### Root Cause

`SwapMetaAdapter.s.sol::plan()` supports stamping and (implicitly, once signed) executing the meta-adapter
swap batch through an ops Safe:

```solidity
// script/manage/SwapMetaAdapter.s.sol:360
address safe = vm.envOr("OPS_SAFE", cfg.securityCouncil);
```
```solidity
// script/manage/SwapMetaAdapter.s.sol:352-353
///      + `addMetaBalanceAdapter(new,set)`. Fails CLOSED on any pair-integrity doubt. Safe defaults to
///      `securityCouncil`; set `OPS_SAFE` to stamp the throwaway ops Safe instead.
```

For that Safe to be able to execute the emitted batch (`removeMetaInstances`/`removeBalanceAdapters`/
`addMetaBalanceAdapter`, all `_requireManager()`-gated on `NAVCalculator`), it must first be granted `MANAGER`
— by construction, outside any script this repo ships (there is no ops-Safe deployment/grant script; `grep`
for `OpsSafe`/`opsSafe`/`OPS_SAFE` across the whole repo returns **only** the two references above).

The governance finalization step, `11_DeployTimelockController.s.sol`, is the only place in the repo that
revokes `DEFAULT_ADMIN_ROLE`/`MANAGER` in bulk as part of "declare the migration done." Its revoke set is
hardcoded to exactly two addresses:

```solidity
// script/deploy/11_DeployTimelockController.s.sol:252-262
uint256 n = safeRetains ? 4 : 6;
SafeTxBuilder.Transaction[] memory batch = new SafeTxBuilder.Transaction[](n);

batch[0] = SafeTxBuilder.call(nav, 0, abi.encodeCall(IAccessControl.grantRole, (DEFAULT_ADMIN_ROLE, predicted)));
batch[1] = SafeTxBuilder.call(nav, 0, abi.encodeCall(IAccessControl.grantRole, (MANAGER, predicted)));
batch[2] = SafeTxBuilder.call(nav, 0, abi.encodeCall(IAccessControl.revokeRole, (MANAGER, deployer)));
batch[3] = SafeTxBuilder.call(nav, 0, abi.encodeCall(IAccessControl.revokeRole, (DEFAULT_ADMIN_ROLE, deployer)));
if (!safeRetains) {
    batch[4] = SafeTxBuilder.call(nav, 0, abi.encodeCall(IAccessControl.revokeRole, (MANAGER, safe)));
    batch[5] = SafeTxBuilder.call(nav, 0, abi.encodeCall(IAccessControl.revokeRole, (DEFAULT_ADMIN_ROLE, safe)));
}
```

`deployer` comes from `vm.envAddress("DEPLOYER_EOA")` and `safe` comes from `chainConfig.securityCouncil`
(line 129: `address safe = chainConfig.securityCouncil;`). **Neither variable, nor anything else in the
function, ever resolves or references the ops Safe used earlier in the migration.** The `// @audit` line
below marks the exact gap:

```solidity
// script/deploy/11_DeployTimelockController.s.sol:129
address safe = chainConfig.securityCouncil;
// @audit `safe` here is ALWAYS securityCouncil — the throwaway ops Safe that SwapMetaAdapter.plan()
//        may have granted MANAGER via OPS_SAFE is never named, never checked, and never revoked below.
```

The script's own exhaustive post-broadcast "verify on-chain" checklist (lines 280-284) confirms the blind
spot — it enumerates exactly `timelock`, `deployer`, and the timelock's own roles; the ops Safe is not
mentioned:

```solidity
// script/deploy/11_DeployTimelockController.s.sol:280-284
console2.log("\n--- verify ON-CHAIN after the batch executes (this script CANNOT) ---");
console2.log("NAV      hasRole(DEFAULT_ADMIN, timelock) == true, hasRole(MANAGER, timelock) == true");
console2.log("NAV      hasRole(DEFAULT_ADMIN, deployer) == false, hasRole(MANAGER, deployer) == false");
console2.log("timelock getMinDelay() == 0, PROPOSER+CANCELLER == safe, EXECUTOR == address(0)");
console2.log("then     rehearse one scheduleBatch -> executeBatch round trip before declaring done");
```

An operator who runs exactly the checklist the script prints will see every check pass while the ops Safe
still holds `MANAGER` — the state is invisible to the tooling that is supposed to prove the migration is
complete.

### Code Location

- File: `script/manage/SwapMetaAdapter.s.sol`
- Function: `plan()`
- Lines: 356-464 (specifically 360, 448-450)

- File: `script/deploy/11_DeployTimelockController.s.sol`
- Function: `run()`
- Lines: 123-286 (specifically 129, 132, 252-262, 280-284)

## Impact

- **Likelihood**: High — using the ops-Safe path is the documented production mechanism for exactly this
  reason (`SwapMetaAdapter.s.sol`'s own docstring at line 353 names it as the intended alternative to
  `securityCouncil`), and the finalization script has no mechanism to catch that it was used.
- **Impact**: High — `MANAGER` can register/deregister balance adapters (including meta-adapters carrying an
  arbitrary instance set), add/modify price feeds and monitor feeds, and adjust divergence/peg tolerances —
  i.e. fully control what the NAV reports for every account on that chain. A 1-of-1 Safe is a single EOA key;
  its compromise (or simple loss of operational discipline treating it as "done" and forgetting it exists)
  gives a single key indefinite, undetected, Timelock-bypassing control over NAV composition on every chain
  where it was used for the swap — with no delay, no council oversight, and no code path in this repo that
  will ever surface the discrepancy.
- **Severity**: CRITICAL — a persistent, silent, single-key bypass of the entire governance hardening this PR
  exists to install, capable of manipulating the NAV inputs that downstream consumers (share pricing, etc.)
  rely on.

## Attack Scenario

### Preconditions
- The operator used `OPS_SAFE=<throwaway 1/1 Safe>` when running `SwapMetaAdapter.s.sol --sig 'plan()'` on one
  or more chains (the documented mechanism for the meta-adapter swap), and that Safe was granted `MANAGER` on
  `NAVCalculator` (by whatever out-of-repo process provisioned it) so it could execute the emitted batch.
- The operator later runs `11_DeployTimelockController.s.sol` on that chain and follows its printed
  verification checklist, all of which passes.
- The operator declares the chain's migration complete.

### Attack Steps
1. The single signer of the throwaway ops Safe (or anyone who compromises that one EOA key — phishing, key
   leakage, insider) retains the ability to call `NAVCalculator.addMetaBalanceAdapter`,
   `removeBalanceAdapters`, `addMetaInstances`, `removeMetaInstances`, `registerAsset`,
   `addOrModifyPriceFeed`, `setDivergenceTolerance`, `setPegTolerance`, etc. — every `MANAGER`-gated function —
   because `hasRole(MANAGER, opsSafe)` is still `true`.
2. The attacker calls `addMetaBalanceAdapter(maliciousAdapter, instances)`, registering an adapter they control
   that reports fabricated `PositionBalance[]` entries for arbitrary accounts, or calls
   `removeBalanceAdapters([legitimateAdapter])` to silently zero out a real position.
3. `NAVCalculator.getAccountNav` / `getAccountNavVerbose` now includes the fabricated (or omits the real)
   position with no health flag — this route bypasses the `DEFAULT_ADMIN_ROLE`-gated `_authorizeUpgrade` and
   the Timelock entirely, since `MANAGER` never routed through the Timelock in the first place for this actor.
4. Any downstream system that prices shares, collateral, or reporting off this NAV consumes the manipulated
   value.

### Expected Impact
- Full, persistent, single-key control over NAV composition on every chain where the ops-Safe swap path was
  used, indistinguishable from a legitimate `MANAGER` action on-chain, and invisible to the migration's own
  documented verification checklist.

## Recommended Mitigation

`11_DeployTimelockController.s.sol` must accept and revoke an explicit, operator-supplied list of every
address that ever held `MANAGER`/`DEFAULT_ADMIN_ROLE` during the migration (at minimum an `OPS_SAFE` /
`EXTRA_REVOKES` env var mirroring `SwapMetaAdapter.s.sol`'s own `OPS_SAFE`), and the emitted batch — and its
printed verification checklist — must include a revoke + a `hasRole(...) == false` check for each. Failing
that, the script should at minimum assert `!hasRole(MANAGER, anyAddressOtherThanDeployerOrSafe)` is
unknowable and loudly document that any ops Safe used earlier in the migration requires a **separate, manual**
revoke that this tooling does not perform — today the risk is not documented at all in this file.
