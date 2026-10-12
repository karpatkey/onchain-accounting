# LOW-01: `_assertSameProtocol` silently passes a transposed pair when both adapters answer empty

## Summary
`SwapMetaAdapter._assertSameProtocol` is designed to catch a transposed predecessor/successor pair (wrong protocol
paired under one config name) by comparing `underlyingAssetsSupportedForInstances(instances)` between `old` and
`new`. It has one detected escape hatch (the "wallet-yield family" vacuous case, gated behind
`SWAP_IDENTITY_CONFIRMED`), but there is a **second, undetected** escape: when the carried instance set resolves to
an **empty asset list on both sides**, the length check trivially passes and the vacuous-detection branch does not
fire either, so a genuinely wrong pairing is accepted with no revert and no operator confirmation required.

## Vulnerability Detail

### Root Cause
`MetaBalanceAdapter._assetsForInstances` (`src/balances/MetaBalanceAdapter.sol:398-442`) fail-opens **per instance**
to an empty sub-list whenever the per-instance `instanceAssets` call reverts without exhausting its gas stipend —
explicitly documented as reachable for ordinary protocol-state reasons, e.g. "Curve's `getPool -> address(0)`"
(`MetaBalanceAdapter.sol:181-182` referenced from the comment in `SwapMetaAdapter.s.sol:180-184`). If **every**
instance in the carried set fails to resolve against `old`'s current on-chain state (e.g. all the carried Curve
pools have since been delisted, or the vaults have been fully redeemed/deprecated such that the read that used to
succeed no longer does), `underlyingAssetsSupportedForInstances(old, instances)` returns `address[](0)`.

### Code Location
- File: `script/manage/SwapMetaAdapter.s.sol`
- Function: `_assertSameProtocol`
- Lines: 165-196

```solidity
function _assertSameProtocol(address old, address newAdapter, bytes32[] memory instances) internal {
    if (instances.length == 0) return;
    address[] memory oldAssets = IMetaAdapterAssets(old).underlyingAssetsSupportedForInstances(instances);
    address[] memory newAssets = IMetaAdapterAssets(newAdapter).underlyingAssetsSupportedForInstances(instances);
    // @audit if BOTH oldAssets and newAssets are length 0 (every instance failed to resolve on both sides,
    // e.g. old's protocol state has drifted since the coordinates were added, and newAdapter is a genuinely
    // wrong/transposed protocol that also can't resolve them), this passes trivially: 0 == 0, loop body never runs.
    if (oldAssets.length != newAssets.length) revert AdapterMismatch(old, newAdapter);
    for (uint256 i = 0; i < oldAssets.length; i++) {
        if (oldAssets[i] != newAssets[i]) revert AdapterMismatch(old, newAdapter);
    }

    // @audit the vacuous-detection gate below only fires when `oldAssets.length == instances.length` — i.e. it
    // was built to catch the wallet-yield family's "answers == coordinates" shape. It does NOT fire when
    // oldAssets is empty and instances.length > 0, which is exactly the degenerate case above. So the one case
    // that bypasses the real comparison entirely is also the one case that bypasses the "confirm by eye" gate.
    bool vacuous = oldAssets.length == instances.length;
    for (uint256 i = 0; vacuous && i < oldAssets.length; i++) {
        if (bytes32(uint256(uint160(oldAssets[i]))) != instances[i]) vacuous = false;
    }
    if (vacuous && !vm.envOr("SWAP_IDENTITY_CONFIRMED", false)) {
        revert IdentityCheckVacuous(old, newAdapter);
    }
}
```

## Impact
- **Likelihood**: Low — requires either (a) the carried instance set having drifted to the point every coordinate
  fails to resolve against `old`'s live protocol state (plausible for a long-dormant vault/pool set, e.g. delisted
  Curve pools, fully-redeemed vaults), combined with (b) `OLD_ADAPTER`/`NEW_ADAPTER` (or a `.pre-swap.json` /
  `deployments.json` name-key) being mismatched so `newAdapter` is a genuinely different protocol's meta-adapter.
  Both `run()` and `plan()` still print `protocolName()` for both sides to the console
  (`SwapMetaAdapter.s.sol:226-227`, `426-427`) as an independent manual check, which partially mitigates operator
  error.
- **Impact**: Low-to-Medium if triggered — the wrong `newAdapter` gets registered governing `instances` it does not
  actually understand. Per-instance decode of a foreign coordinate under the wrong protocol's ABI most often reverts
  and is caught by `MetaBalanceAdapter`'s per-instance fan-out (`_positionsForInstances`,
  `MetaBalanceAdapter.sol:363-395`), which is an **under-report** (safe direction), not a double-count. An
  over-report would additionally require the mis-decoded coordinate to coincidentally resolve to a live, queryable
  contract under the wrong adapter's ABI with a non-zero balance for the tracked account — an extreme coincidence,
  not a realistic path on its own. The primary, realistic damage is **protocol misattribution** (wrong
  `protocolBrand`/`protocolId` and, if it doesn't revert, a wrong-adapter valuation) surviving the transposition
  guard undetected.
- **Severity**: LOW

## Attack Scenario

### Preconditions
- A meta-adapter `old` (e.g. `CurvePoolsMeta`) is being swapped for a redeployed successor via `plan()`.
- Every instance currently in `old`'s governed set fails `old.instanceAssets(instance)` (reverts without gas
  exhaustion) — e.g. because the pools were fully withdrawn/delisted since being added, a state Curve pools can
  reach organically (`getPool -> address(0)`, per the comment this file itself cites).
- `NEW_ADAPTER` is accidentally pointed at a meta-adapter for a **different** protocol (e.g. a mis-copied address
  from a sibling `.pre-swap.json`/`deployments.json` entry, or a hand-edited env var).

### Attack Steps
1. Operator runs `plan()` (or `run()`) with `OLD_ADAPTER` = the drifted `CurvePoolsMeta` and `NEW_ADAPTER` =
   a wrongly-paired adapter for an unrelated protocol.
2. `_assertSameProtocol` calls `old.underlyingAssetsSupportedForInstances(instances)` → every per-instance call
   reverts on `old`'s current (drifted) state → `oldAssets = []`.
3. `_assertSameProtocol` calls `newAdapter.underlyingAssetsSupportedForInstances(instances)` → every per-instance
   call also reverts (wrong protocol, coordinates don't decode meaningfully) → `newAssets = []`.
4. `oldAssets.length == newAssets.length` (`0 == 0`) → no `AdapterMismatch` revert. The per-element loop never
   executes. `vacuous = (0 == instances.length)` is `false` (since `instances.length > 0`) → the
   `SWAP_IDENTITY_CONFIRMED` gate never fires either.
5. The script proceeds to emit/broadcast `removeMetaInstances(old,set)` + `removeBalanceAdapters([old])` +
   `addMetaBalanceAdapter(newAdapter,set)` with no further checks on the pairing.
6. The wrong `newAdapter` is now registered governing `old`'s former instance coordinates. Depending on what those
   coordinates decode to under `newAdapter`'s ABI, positions for the tracked accounts are either silently dropped
   (most likely) or reported under the wrong protocol identity/valuation.

### Expected Impact
- Best case: silent, complete loss of coverage for the swapped instances (under-report, caught eventually by
  drift/reconciliation tooling).
- Worst case (narrow): a misattributed or mis-valued position for the tracked accounts, undetected by this script's
  own integrity check, requiring the operator's separate manual read of the printed `protocolName()` lines to catch.

## Recommended Mitigation
Treat "both sides answered empty for a non-empty instance set" as vacuous too — require `SWAP_IDENTITY_CONFIRMED`
(or revert unconditionally, since an unreadable predecessor is itself worth stopping on) whenever
`oldAssets.length == 0 && instances.length > 0`, not only when `oldAssets.length == instances.length`:

```solidity
bool vacuous = oldAssets.length == 0 || oldAssets.length == instances.length;
for (uint256 i = 0; vacuous && oldAssets.length == instances.length && i < oldAssets.length; i++) {
    if (bytes32(uint256(uint160(oldAssets[i]))) != instances[i]) vacuous = false;
}
```
