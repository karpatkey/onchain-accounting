# L-02: MerklRewardsBalanceAdapter — ASSISTANT_ROLE holder can `clearAllocation` a valid pending reward, causing targeted under-report

## Summary

`clearAllocation(user, token)` is gated by `onlyRole(ASSISTANT_ROLE)`, the same role used for submission. An assistant (e.g. a compromised automation key) can call `clearAllocation` on any `(user, token)` pair to zero out a valid cached allocation without submitting a new proof, permanently suppressing that entry until a fresh proof is submitted. This is a targeted under-report capability in the hands of the assistant.

## Vulnerability Detail

### Root Cause

The design intentionally keeps `clearAllocation` behind `ASSISTANT_ROLE` (not `DEFAULT_ADMIN_ROLE`) so the automation can GC stale entries without human intervention. The consequence is that a compromised assistant has the power to clear any live entry, not just stale ones. The adapter has no way to distinguish an assistant clearing a legitimately stale entry from one suppressing a live allocation.

### Code Location
- File: `src/balances/AssistedBalanceAdapters/MerklRewardsBalanceAdapter.sol`
- Function: `clearAllocation`
- Lines: 146–152

```solidity
// @audit ASSISTANT_ROLE can clear any (user, token) allocation, including live ones
function clearAllocation(address user, address token) external onlyRole(ASSISTANT_ROLE) {
    if (user == address(0) || token == address(0)) revert InvalidArguments();
    if (allocations[user][token].submittedAt == 0) return; // nothing to clear
    delete allocations[user][token];
    _removeUserToken(user, token);
    emit AllocationCleared(user, token);
}
```

## Impact
- **Likelihood**: Low — requires a compromised assistant key; the assistant is documented as an automation with a narrow permission surface.
- **Impact**: Low — the cleared allocation causes under-report only (Iron Law preserved). The `DEFAULT_ADMIN_ROLE` can rotate the assistant and a new proof can be resubmitted. No funds are at risk.
- **Severity**: LOW (documented design trade-off; not a new vector beyond the trust model stated in ADR 0007)

## Attack Scenario

### Preconditions
- ASSISTANT_ROLE is held by an automation key.
- Account `U` has a large pending Merkl reward allocation for token `T` cached and fresh (root matches current).

### Steps
1. Attacker compromises the ASSISTANT_ROLE key.
2. Attacker calls `clearAllocation(U, T)`.
3. `allocations[U][T]` is deleted and `T` is removed from `_userTokens[U]`.
4. NAV reads for account `U` now return 0 for token `T`.
5. The DEFAULT_ADMIN_ROLE holder (security council Safe) must rotate ASSISTANT_ROLE and the bot must resubmit a fresh proof to restore correctness.

### Expected Impact
- NAV for account `U` under-reports by the value of the cleared allocation until a fresh proof is submitted.
- All accounts can be targeted simultaneously if the attacker iterates all (user, token) pairs.

## Recommended Mitigation

Option A: Move `clearAllocation` to `onlyRole(DEFAULT_ADMIN_ROLE)`. Stale-entry GC becomes a human-in-the-loop operation, which is acceptable given the low frequency of claimed rewards.

Option B: Only allow clearing entries where `allocations[user][token].cumulativeAmount <= claimed[user][token]` (i.e., the entry is genuinely fully claimed). This prevents clearing live entries programmatically while still allowing automated GC for zero-unclaimed positions.

The current design is an acknowledged trade-off per ADR 0007 ("completeness trust: owner can starve the cache"). Either option raises the bar for a compromised assistant to suppress live allocations.
