# L-01: NexusMutualStakingPoolsBalanceAdapter — `getAdapterBalances` folds staking principal and rewards into one amount, diverging from `getAdapterPositions` which separates them

## Summary

`getAdapterBalances` returns a single entry `(NXM, staking + rewards, false)` for the full NXM balance, while `getAdapterPositions` emits separate `Staking` and `Rewards` legs per tokenId. The two methods therefore produce inconsistent per-account NXM totals when NAVCalculator aggregates via `getAdapterBalances` for the legacy balance path vs. `getAdapterPositions` for the positions path. No over-report occurs, but the staking + rewards total reported by `getAdapterBalances` aggregates to the same number as the sum of all Staking + Rewards legs from `getAdapterPositions`, so the concern is one of representation, not magnitude.

A separate, lower-severity risk: `_stakeAndRewards` (called from `getAdapterBalances`/`getAdapterBalanceForAsset`) uses `getAggregatedTokens`, while `getAdapterPositions` uses `getTokens`. If the StakingViewer's two methods return inconsistent totals (e.g., due to a viewer-level bug or rounding), the two interface paths report different values for the same account.

## Vulnerability Detail

### Root Cause

The adapter exposes two value-returning paths backed by two different viewer calls:
1. `getAdapterBalances` → `_stakeAndRewards` → `getAggregatedTokens(ids)` — returns aggregated `(totalActiveStake + totalExpiredStake, totalRewards)`.
2. `getAdapterPositions` → `getTokens(ids)` — returns per-token breakdown from which `staking = activeStake + expiredStake` and `rewards` are summed.

If `StakingViewer.getAggregatedTokens` and `getTokens` are consistent, the sums are equal. But they are separate calls on a mutable external contract; any divergence in their implementations or state atomicity is not guarded against.

### Code Location
- File: `src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsBalanceAdapter.sol`
- Function: `_stakeAndRewards` (lines 139–151) and `getAdapterPositions` (lines 215–269)

```solidity
// @audit path 1: uses getAggregatedTokens
function _stakeAndRewards(address account) internal view returns (uint256 staking, uint256 rewards) {
    uint256[] memory ids = _ownedTokenIds(account);
    if (ids.length == 0) return (0, 0);
    try INexusStakingViewer(STAKING_VIEWER).getAggregatedTokens(ids) returns (
        INexusStakingViewer.AggregatedTokens memory agg
    ) {
        staking = agg.totalActiveStake + agg.totalExpiredStake;
        rewards = agg.totalRewards;
    } catch { return (0, 0); }
}

// @audit path 2: uses getTokens — two separate external calls on same mutable contract
try INexusStakingViewer(STAKING_VIEWER).getTokens(ids) returns (INexusStakingViewer.Token[] memory t) {
    tokens = t;
} catch { return new INAVCalculator.PositionBalance[](0); }
```

## Impact
- **Likelihood**: Low — requires a state inconsistency or bug in the Nexus StakingViewer external contract.
- **Impact**: Low — if inconsistency exists, `getAdapterBalances` and `getAdapterPositions` diverge in reported NXM, which could confuse off-chain reconciliation but does not cause fund loss.
- **Severity**: LOW

## Attack Scenario

This is not an exploitable vulnerability; it is an internal consistency issue.

### Steps
1. At block N, account holds StakingNFT ids [1, 2, 3].
2. `getAdapterBalances(account)` calls `getAggregatedTokens([1,2,3])` → returns totalActiveStake X.
3. `getAdapterPositions(account, address(0))` calls `getTokens([1,2,3])` → returns per-token data summing to Y.
4. If X ≠ Y (e.g., due to rounding in one viewer path but not the other), the two NAVCalculator query paths report different totals for the same account at the same block.

### Expected Impact
- Off-chain reconciliation between `getAdapterBalances` and `getAdapterPositions` shows a discrepancy.
- No direct over-report from the adapter itself; the discrepancy is bounded by viewer rounding.

## Recommended Mitigation

Unify on a single viewer call. The simplest fix is to have `_stakeAndRewards` compute the totals by iterating the result of `getTokens` (which is already called in `getAdapterPositions`) rather than calling `getAggregatedTokens` separately. This eliminates the two-call inconsistency and ensures both interface paths are driven by the same data.
