# CRITICAL-02: `06_Configure`'s meta-adapter path is ADD-ONLY with no predecessor cross-check — running it (instead of/after `SwapMetaAdapter`) during the PR #338 fleet migration double-registers old+new generation and over-reports every governed position, on any of the 8 asset chains

## Summary
`06_Configure.s.sol`'s meta-adapter registration loop only ever *adds* the address currently on record; it has
no path to discover or deregister a **different address** that is still live-registered for the same protocol.
`script/manage/SwapMetaAdapter.s.sol`'s own docstring already states this in plain words — *"`06_Configure`
cannot do it: ... it has no notion of superseding a meta adapter at all"* — but nothing in `06_Configure`, and
nothing at the on-chain registration layer (`NAVRegistryLib`), actually **stops** an operator from running it
against a chain that is mid-migration. Because PR #338 requires *every* meta adapter on *every* one of the 8
asset chains (1, 10, 56, 100, 137, 8453, 42161, 5042) to move to a new CREATE2 address, and the ordinary,
muscle-memory post-deploy step every prior redeploy runbook invokes is `06_Configure` (not the newer, PR
#338-specific `SwapMetaAdapter.plan()`), the fleet-wide blast radius of this gap is the entire meta-adapter set
on any chain where an operator reaches for the familiar script instead of the new one.

## Vulnerability Detail

### Root Cause
`06_Configure`'s meta-adapter loop resolves the adapter to register purely from the **current** deployment
record (post-`04`, i.e. the NEW-generation address) and only checks whether *that exact address* is already
registered — it never asks "is there an OLD address already registered for this protocol that I should retire
first?":

- File: `script/deploy/06_Configure.s.sol`
- Function: `_configureBalanceAdapters`
- Lines: 148-197

```solidity
// META balance adapters → addMetaBalanceAdapter (atomic register + seed), then reconcile the instance set.
string[] memory meta = ConfigReader.getEnabledAdapters(vm, currentChainId, "navMetaBalanceAdapters");
for (uint256 i = 0; i < meta.length; i++) {
    if (!ConfigReader.isAdapterEnabled(vm, currentChainId, "navMetaBalanceAdapters", meta[i])) continue;
    address deployed = _readAdapterDeployed("balanceAdapters", meta[i]); // @audit reads the NEW address 04 just wrote
    if (deployed == address(0)) continue;

    bytes32[] memory desired = _readMetaInstances(meta[i]);
    if (!IBalances(navProxy).isAdapterRegistered(deployed)) {
        // @audit ADD-ONLY: no check for a *different*, still-registered address for this same protocol.
        (bool ok, bytes memory data) = navProxy.call(
            abi.encodeWithSignature("addMetaBalanceAdapter(address,bytes32[])", deployed, desired)
        );
        ...
        console2.log("[OK] Added meta balance adapter:", meta[i], deployed);
        added++;
    } else {
        console2.log("[SKIP] Already registered:", meta[i], deployed);
    }
    // ... instance reconciliation for `deployed` only; never touches any OTHER registered address.
}
```

Compare with the PLAIN-adapter loop immediately above it (lines 88-146), which at least has an explicit,
operator-declared deregistration path (`"deregister": true` in nav-config → `removeBalanceAdapters`). **No
equivalent exists for meta adapters anywhere in this file.**

On the receiving end, `NAVRegistryLib.addMetaBalanceAdapter` registers purely by **address**, with no
protocol-identity uniqueness check:

- File: `src/nav/NAVRegistryLib.sol`
- Function: `addMetaBalanceAdapter`
- Lines: 153-186

```solidity
function addMetaBalanceAdapter(..., address adapter, bytes32[] memory instances, ...) external returns (uint256 added) {
    _registerAdapter(isAdapterRegistered, globalAdapters, adapterTypes, adapter, true);
    // @audit registers by ADDRESS only — nothing here asks "is a different address already registered
    // for the same protocolId/protocolBrand?" A brand-new address for the SAME protocol registers cleanly
    // alongside an already-live predecessor.
    emit IBalances.BalanceAdapterAdded(address(0), adapter, IBalances.AdapterType.Custom);
    _releaseInstances(claimant, metaInstances, adapter, erc20DefaultBalanceAdapter);
    added = _appendInstances(claimant, metaInstances, adapter, instances, erc20DefaultBalanceAdapter);
}
```

`_appendInstances` seeds the NEW adapter with the **full** `desired` instance set read straight from
`nav-config/meta-balance-adapters/<chainId>.json` — i.e. the complete governed coordinate list — while the OLD
adapter, still registered under its own (different) address, keeps whatever instance set it already held. Both
are now live, independently reachable via `IBalances.getRegisteredAdapters()`/NAV's position-enumeration path,
and both enumerate the **same underlying protocol positions** for every account.

### Why this is specific to the PR #338 migration
Before #338, `06_Configure` running twice was safe because a re-run resolves the **same** address both times
(idempotent). PR #338 changes that invariant: after `04_DeployBalanceAdapters` redeploys under the new shared
`MetaBalanceAdapter` base bytecode, the deployment record's `balanceAdapters.<name>` key points at a **new**
address while the **old** address is still the one actually registered on the live NAV (nothing deregistered it
yet — that is `SwapMetaAdapter`'s job, and only its job). Any invocation of `06_Configure` in that window adds
the new address without ever knowing the old one exists.

## Impact
- **Likelihood**: Medium — requires an operator to run `06_Configure` (the long-standing, every-runbook-step
  script) instead of, or in addition to, `SwapMetaAdapter.plan()`/`run()` during the migration window on one of
  the 8 chains. Given `06_Configure` is also the *only* script documented for `navMetaBalanceAdapters` in its own
  header comment, and the redeploy runbook (`REDEPLOY_RUNBOOK.md`) predates `SwapMetaAdapter.plan()`'s "PR #338
  Phase 2" role and does not mention it, this is a plausible operational sequencing error, not a contrived one.
- **Impact**: High — every meta adapter accidentally handled this way double-reports its **entire** governed
  instance set (all Aave V3 instances, all Morpho vaults/markets, all Curve/Convex/Balancer pools+gauges, etc,
  per `nav-config/meta-balance-adapters/<chainId>.json`) for **every account** with a position there, on
  whichever chain the mistake occurs. This is exactly the "cardinal sin" over-report the migration must avoid,
  and it produces no revert, no health flag, and no on-chain signal distinguishing it from a correct read.
- **Severity**: CRITICAL — direct, silent, fleet-scale over-report of NAV with no code-level circuit breaker;
  only manual operator discipline (reading `SwapMetaAdapter`'s docstring rather than reaching for `06_Configure`)
  currently prevents it.

## Attack Scenario
(Operational/process scenario, not an external attacker — but the audit brief treats over-report as the
cardinal sin regardless of actor.)

### Preconditions
- Chain X (any of 1, 10, 56, 100, 137, 8453, 42161, 5042 that already had a live NAV pre-#338 — Arc/5042 is
  exempt, since it has no predecessor generation) has an already-registered `CurvePoolsMeta` (or any other meta
  adapter) at OLD_ADDR.
- The chain's deployment record for `CurvePoolsMeta` has been cleared (per `reset_deployment_records.py`) and
  `04_DeployBalanceAdapters` has been re-run, writing NEW_ADDR into `deployments/<chainId>.json`.

### Attack Steps
1. An operator, following the familiar post-deploy checklist, runs
   `forge script script/deploy/06_Configure.s.sol --broadcast` against chain X instead of
   `SwapMetaAdapter.plan()`/`run()`.
2. `_configureBalanceAdapters` reads `deployed = NEW_ADDR` from the deployment record for `CurvePoolsMeta`.
3. `IBalances(navProxy).isAdapterRegistered(NEW_ADDR)` is `false` (never registered before), so the script calls
   `addMetaBalanceAdapter(NEW_ADDR, desired)` with `desired` = the full pool set from
   `nav-config/meta-balance-adapters/<chainId>.json`.
4. `NAVRegistryLib.addMetaBalanceAdapter` registers NEW_ADDR and seeds it with every configured pool coordinate.
   OLD_ADDR remains registered from before this script ran — nothing in this call path touches it.
5. Both OLD_ADDR and NEW_ADDR are now live, registered meta adapters, each independently enumerating the same
   Curve pool set for every account holding LP positions. A subsequent `getAccountNav` call sums both.

### Expected Impact
- Every account's Curve-pool-derived NAV component on chain X is reported at roughly double its true value,
  silently, with no reverting health check — repeated for any other meta adapter an operator similarly
  mis-migrates via `06_Configure` on any of the 8 chains.

## Recommended Mitigation
1. Add a hard guard in `06_Configure`'s meta-adapter loop: before calling `addMetaBalanceAdapter`, check whether
   any OTHER currently-registered adapter answers the same `protocolBrand`/`protocolId`/`protocolSubId` as
   `deployed` (e.g. via a view that lists registered adapters and calls their identity getters) and `revert` if
   one is found, forcing the operator onto `SwapMetaAdapter` instead.
2. Alternatively (cheaper, and consistent with the plain-adapter pattern already in this file), maintain an
   explicit `predecessor` field per meta adapter in `contracts-deployment-config/meta-balance-adapters/<chainId>.json`
   during a migration window, and have `06_Configure` refuse to `addMetaBalanceAdapter` for any entry whose
   declared predecessor is still `isAdapterRegistered` — mirroring the "declared, not derived" removal-set
   philosophy this file already uses for plain adapters (lines 98-104).
3. Document, in `06_Configure`'s own header (not only in `SwapMetaAdapter`'s), that it must **never** be run
   against a chain with a pending meta-adapter migration, and have it print a loud warning (not just a `[SKIP]`)
   whenever `getMetaInstances` reconciliation is about to add a brand-new adapter address for a protocol that
   already has *a* registered meta adapter of the same on-chain-declared identity.
