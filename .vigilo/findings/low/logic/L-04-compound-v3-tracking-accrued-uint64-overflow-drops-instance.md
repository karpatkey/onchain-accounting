# L-04: CompoundV3CometLib._updateTrackingAccrued uint64 arithmetic overflow silently drops entire market's positions

## Summary

`CompoundV3CometLib._updateTrackingAccrued` returns `uint64` and sums `baseTrackingAccrued` (a `uint64` from the Comet protocol) with an accrual delta. For large positions over long elapsed time, both the intermediate `_accrue` indices and the final sum can overflow `uint64`. SafeCast's `toUint64()` reverts on overflow. Since the revert propagates all the way up through `CompoundV3CometsMetaBalanceAdapter._instancePositions`, it is caught by the per-instance `try/catch` in `MetaBalanceAdapter._positionsForInstances`, silently dropping that Compound V3 market's positions entirely. Large accounts with significant Compound V3 exposure may see their entire Compound V3 NAV contribution disappear.

## Vulnerability Detail

### Root Cause

```solidity
// @audit return type is uint64; overflow reverts via SafeCast
function _updateTrackingAccrued(
    address comet,
    uint64 baseTrackingAccrued,
    int104 principal,
    uint64 baseTrackingIndex,
    uint64 trackingSupplyIndex,
    uint64 trackingBorrowIndex,
    uint256 descale
) private view returns (uint64) {               // @audit uint64 return
    uint256 indexDelta;
    uint256 absPrincipal;
    if (principal >= 0) {
        indexDelta = uint256(trackingSupplyIndex - baseTrackingIndex);
        absPrincipal = SafeCast.toUint256(int256(principal));
    } else {
        indexDelta = uint256(trackingBorrowIndex - baseTrackingIndex);
        absPrincipal = SafeCast.toUint256(-int256(principal));
    }
    return baseTrackingAccrued
        + (absPrincipal * indexDelta / CometExtInterface(comet).trackingIndexScale() / descale).toUint64();
        // @audit SafeCast.toUint64() reverts if delta > type(uint64).max
        // @audit uint64 + uint64 addition also reverts in ^0.8 checked arithmetic if sum overflows
}
```

Additionally, in `_accrue`:

```solidity
// @audit trackingSupplyIndex is uint64; addition can overflow for high accrual rates * long elapsed time
trackingSupplyIndex += _divBaseWei(
    comet, CometExtInterface(comet).baseTrackingSupplySpeed() * timeElapsed, totalSupplyBase
).toUint64();    // @audit reverts if result > type(uint64).max - trackingSupplyIndex
```

Both overflows cause a revert inside `_accrue` or `_updateTrackingAccrued`. The call chain is:

```
MetaBalanceAdapter._positionsForInstances
  → try this.instancePositions(account, instance, assetFilter)
    → CompoundV3CometsMetaBalanceAdapter._instancePositions(account, instance, assetFilter)
      → CompoundV3CometLib.accountData(comet, rewards, rewardToken, account)
        → CompoundV3CometLib.rewardOwed(...)
          → CompoundV3CometLib._rewardAccrued(...)
            → CompoundV3CometLib._accrue(comet)
              → SafeCast.toUint64() REVERTS
        caught by the outer try/catch → entire instance dropped
```

### Code Location

- File: `src/balances/MetaBalanceAdapters/CompoundV3CometLib.sol`
- Functions: `_updateTrackingAccrued()`, `_accrue()`
- Lines: 287-307 (`_updateTrackingAccrued`), 207-219 (`_accrue` tracking index updates)

## Impact

- **Likelihood**: Low to Medium — Compound V3 markets with high `baseTrackingSupplySpeed` or large positions accrued over months can reach the uint64 boundary. The Comet protocol itself uses uint64 for tracking indices and would overflow in-protocol before this adapter does, so in practice the comet's own `accrueAccount` transaction would fail first. However, the adapter's off-chain view path can diverge from on-chain state if a comet operates with large intermediate values that fit the protocol's internal accounting but cause adapter-side overflow.
- **Impact**: Medium — when triggered, the entire Compound V3 market's positions (base, collateral, and rewards) are silently dropped from NAV for the affected account. No warning is emitted; NAV under-reports without indicating why.
- **Severity**: LOW

## Attack Scenario

### Preconditions

- A Compound V3 market has been running for an extended period with high `baseTrackingSupplySpeed` (e.g. large COMP incentive distribution).
- The tracked indices (`trackingSupplyIndex`) have grown sufficiently large that adding the per-block accrual pushes the value past `type(uint64).max`.

### Attack Steps

1. Account has a large supply position in a Compound V3 market.
2. `_accrue(comet)` is called; `trackingSupplyIndex += delta.toUint64()` reverts because the delta pushes `trackingSupplyIndex` past `type(uint64).max`.
3. Revert propagates through `accountData → rewardOwed → _rewardAccrued → _accrue`.
4. `_instancePositions` reverts; the per-instance `try/catch` in `_positionsForInstances` catches the revert.
5. The affected Compound V3 comet's positions (supply, collateral, rewards) are all returned as empty.
6. NAV for the account under-counts by the full USDC value of all Compound V3 positions in that market.

### Expected Impact

- Compound V3 positions silently disappear from NAV without any stale-price flag or error signal.
- The magnitude can be significant for large accounts with long-standing Compound V3 positions.

## Recommended Mitigation

Widen the return type and intermediate storage from `uint64` to `uint256` to match the safe arithmetic range:

```solidity
function _updateTrackingAccrued(
    // ...
) private view returns (uint256) {          // widened return type
    // ...
    return uint256(baseTrackingAccrued)
        + (absPrincipal * indexDelta / trackingIndexScale / descale);
        // no toUint64() call needed
}
```

Similarly, track `baseSupplyIndex`, `baseBorrowIndex`, `trackingSupplyIndex`, and `trackingBorrowIndex` as `uint256` within the `_accrue` function and only cast back to `uint64` when returning to callers that require it. This matches how Compound V3's own governance handles overflow-resistant accrual.
