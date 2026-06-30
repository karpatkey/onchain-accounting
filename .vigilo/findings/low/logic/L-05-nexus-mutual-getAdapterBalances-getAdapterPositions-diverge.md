# L-05: NexusMutualStakingPoolsBalanceAdapter — `getAdapterBalances` and `getAdapterPositions` return inconsistent totals when any StakingPool address fails to resolve

## Summary

`getAdapterBalances` (via `_stakeAndRewards`) calls `getAggregatedTokens` which aggregates stake and rewards across all owned tokenIds without per-token pool resolution. `getAdapterPositions` calls `getTokens` and then for each token calls `stakingPool(poolId)` — silently skipping tokens where this reverts or returns `address(0)`. The two paths can produce different totals for the same account.

## Vulnerability Detail

### Root Cause

The two code paths use different aggregation strategies:

- `_stakeAndRewards` path: `getAggregatedTokens(ids)` sums all tokens in one Viewer call (no `stakingPool()` resolution)
- `getAdapterPositions` path: `getTokens(ids)` then per-token `try stakingPool(poolId)` — skips tokens where pool lookup fails

When any of an account's tokenIds has a poolId that `STAKING_VIEWER.stakingPool()` cannot resolve (reverts or returns `address(0)`), `getAdapterPositions` silently omits those positions. The `getAdapterBalances` response still includes them in the sum.

### Code Location
- File: `src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsBalanceAdapter.sol`
- Functions: `getAdapterPositions` (lines 265–284), `_stakeAndRewards` (lines 353–364)

```solidity
// @audit getAdapterPositions: skips tokens where stakingPool() fails
try INexusStakingViewer(STAKING_VIEWER).stakingPool(tokens[i].poolId) returns (address p) {
    pool = p;
} catch {
    continue; // position dropped from getAdapterPositions output
}
if (pool == address(0)) continue;

// @audit _stakeAndRewards: uses aggregated call, never skips any token
try INexusStakingViewer(STAKING_VIEWER).getAggregatedTokens(ids) returns (
    INexusStakingViewer.AggregatedTokens memory agg
) {
    staking = agg.totalActiveStake + agg.totalExpiredStake;
    rewards = agg.totalRewards;
}
```

## Impact
- **Likelihood**: Low — requires the StakingViewer's `stakingPool()` to fail for some poolId, which would be unusual but possible after a Nexus Mutual upgrade or for deprecated pools
- **Impact**: Low — `getAdapterBalances` is not used by the NAV computation path (PriceFeedLib only calls `getAdapterPositions`); the discrepancy affects only off-chain tooling that queries `getAdapterBalances` directly for quick balance checks
- **Severity**: LOW — NAV computation is unaffected; the inconsistency is between two non-critical off-chain-facing view functions

## Attack Scenario

### Preconditions
- An account has NFT positions in two pools: pool A (resolves normally) and pool B (pool B's ID fails `stakingPool()`)
- Both pools have nonzero stake and rewards

### Steps
1. `getAdapterBalances(account)` calls `_stakeAndRewards` → `getAggregatedTokens([id_A, id_B])` → returns `staking = stakeA + stakeB, rewards = rewardA + rewardB`
2. `getAdapterPositions(account, address(0))` processes id_A successfully (emits Staking + Rewards legs), fails on pool B's `stakingPool()` and skips id_B
3. Off-chain tooling: `getAdapterBalances` reports total X, but summing positions gives total X − (stakeB + rewardB)
4. An off-chain system using the balance getter to cross-check position totals detects a phantom discrepancy

### Expected Impact
- Off-chain tooling receives different totals from the two entry points, potentially triggering false alerts or miscounting

## Recommended Mitigation

Align the two paths: in `_stakeAndRewards`, use `getTokens` (the same call as `getAdapterPositions`) and apply the same `stakingPool()` resolution filter before aggregating. This ensures both entry points produce the same total for the same account:

```solidity
function _stakeAndRewards(address account) internal view returns (uint256 staking, uint256 rewards) {
    uint256[] memory ids = _ownedCachedIds(account);
    if (ids.length == 0) return (0, 0);
    try INexusStakingViewer(STAKING_VIEWER).getTokens(ids) returns (INexusStakingViewer.Token[] memory tokens) {
        for (uint256 i; i < tokens.length; ++i) {
            try INexusStakingViewer(STAKING_VIEWER).stakingPool(tokens[i].poolId) returns (address p) {
                if (p == address(0)) continue;
                staking += tokens[i].activeStake + tokens[i].expiredStake;
                rewards += tokens[i].rewards;
            } catch {}
        }
    } catch {}
}
```

Alternatively, deprecate `getAdapterBalances`/`getAdapterBalanceForAsset` for this adapter and always direct callers to `getAdapterPositions`.
