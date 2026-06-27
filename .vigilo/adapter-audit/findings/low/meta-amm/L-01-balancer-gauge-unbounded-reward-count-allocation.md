# L-01: Balancer V2/V3 Gauge Adapters — Unbounded `rewardCount` Array Allocation from Gauge

## Summary

`BalancerV2GaugesMetaBalanceAdapter._instancePositions` and `BalancerV3GaugesMetaBalanceAdapter._instancePositions` pre-allocate `temp` with `tokens.length + rewardCount + 1` entries, where `rewardCount` is taken directly from the gauge's `reward_count()` return value. A gauge returning an unreasonably large value causes the `new INAVCalculator.PositionBalance[]` allocation to exhaust all available gas, reverting the per-instance staticcall. The per-instance try/catch in the base `MetaBalanceAdapter._positionsForInstances` catches the revert and silently emits an empty array for that gauge — so the effect is the entire gauge's staked principal and rewards are dropped from NAV.

## Vulnerability Detail

### Root Cause

`_rewardCount` wraps `gauge.reward_count()` in a try/catch that returns 0 on revert, but returns the raw return value unchanged on success. There is no upper-bound clamp on that value before it is used to size a dynamic array.

### Code Locations

**BalancerV2GaugesMetaBalanceAdapter:**
- File: `src/balances/MetaBalanceAdapters/balancer/BalancerV2GaugesMetaBalanceAdapter.sol`
- Function: `_instancePositions`
- Lines: 80–81

```solidity
// @audit rewardCount comes from gauge.reward_count() with no upper-bound clamp
INAVCalculator.PositionBalance[] memory temp =
    new INAVCalculator.PositionBalance[](tokens.length + rewardCount + 1);
```

- Lines: 294–299 (`_rewardCount` helper — returns raw value, no cap):
```solidity
function _rewardCount(IGaugeV3 gauge) private view returns (uint256) {
    try gauge.reward_count() returns (uint256 c) {
        return c; // @audit no upper bound
    } catch {
        return 0;
    }
}
```

**BalancerV3GaugesMetaBalanceAdapter:**
- File: `src/balances/MetaBalanceAdapters/balancer/BalancerV3GaugesMetaBalanceAdapter.sol`
- Function: `_instancePositions`
- Lines: 67–69

```solidity
// @audit same pattern — rewardCount uncapped before array allocation
uint256 rewardCount = _rewardCount(gauge);
INAVCalculator.PositionBalance[] memory temp =
    new INAVCalculator.PositionBalance[](tokens.length + rewardCount + 1);
```

## Impact

- **Likelihood**: Low — requires a gauge with a pathological `reward_count()` return (malicious or severely misconfigured instance registered via MANAGER). Real Balancer gauges cap reward tokens at 8.
- **Impact**: Low — the per-instance try/catch in `MetaBalanceAdapter._positionsForInstances` isolates the OOM revert to that single gauge instance; all other instances continue normally. The affected gauge's staked principal and claimable rewards are silently omitted from NAV (under-report only, consistent with the protocol invariant of prefer-under over prefer-over).
- **Severity**: LOW

## Attack Scenario

### Preconditions

- A gauge instance is registered via `addMetaInstances` (requires MANAGER role).
- That gauge's `reward_count()` returns a value large enough to exhaust gas during `new INAVCalculator.PositionBalance[]` allocation (e.g., `1e9`).

### Attack Steps

1. MANAGER registers a gauge address whose `reward_count()` returns `1e9`.
2. At NAV read time, `_positionsForInstances` calls `this.instancePositions(account, instance, assetFilter)` for that gauge as a staticcall.
3. Inside `_instancePositions`, `_rewardCount(gauge)` returns `1e9`.
4. `new INAVCalculator.PositionBalance[](tokens.length + 1e9 + 1)` runs out of gas.
5. The staticcall reverts; the base class catches it and assigns an empty `PositionBalance[]` array for this gauge.
6. All staked LP and claimable rewards for accounts in this gauge are omitted from the NAV calculation.

### Expected Impact

- Any account with staked BPT in the affected gauge has that position silently dropped from NAV (under-report, bounded to the size of that gauge's TVL attributed to those accounts).

## Recommended Mitigation

Clamp `rewardCount` to a known maximum (e.g., 8, matching the Balancer gauge reward-token cap) before using it to size the temp array:

```solidity
// Fixed: cap at a known safe maximum
uint256 rewardCount = _rewardCount(gauge);
uint256 safeRewardCount = rewardCount > 8 ? 8 : rewardCount;
INAVCalculator.PositionBalance[] memory temp =
    new INAVCalculator.PositionBalance[](tokens.length + safeRewardCount + 1);
```

The inner loop then iterates `i < rewardCount` (the original value) so legitimate gauges with more reward slots still have all tokens attempted via the safe `_rewardToken` try/catch — excess slots beyond 8 would require a separate approach or accept a bounded limit. Alternatively, apply the cap only in the loop bound as well.
