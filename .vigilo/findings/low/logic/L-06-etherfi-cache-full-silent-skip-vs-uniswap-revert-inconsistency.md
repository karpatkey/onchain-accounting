# L-06: Inconsistent cache-full behavior between assisted adapters — EtherFi silently drops IDs at cap, Uniswap V3 reverts

## Summary

`EtherFiWithdrawalQueueBalanceAdapter._addTokenId` silently returns (no-op, no event) when the cache is at `MAX_TOKEN_IDS`. `UniswapV3PoolsBalanceAdapter._addTokenId` and `NexusMutualStakingPoolsBalanceAdapter._addTokenId` revert with `TokenIdCacheFull`. The silent-skip design in ether.fi means the assistant receives no signal that a position was dropped, leading to silent under-reporting of NAV with no indication of the cause.

## Vulnerability Detail

### Root Cause

Different `_addTokenId` implementations in the same assisted-adapter family use different failure modes at cache capacity:

**EtherFi (silent skip):**
```solidity
// @audit Silent no-op at capacity: assistant gets no signal, position is lost
if (_tokenIds[account].length >= MAX_TOKEN_IDS) return;
```

**Uniswap V3 (revert):**
```solidity
// @audit Revert: assistant is forced to GC before adding
if (_tokenIds[account].length >= MAX_TOKEN_IDS) revert TokenIdCacheFull(account, MAX_TOKEN_IDS);
```

### Code Locations
- `src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueBalanceAdapter.sol`, line 278
- `src/balances/AssistedBalanceAdapters/UniswapV3PoolsBalanceAdapter.sol`, line 289

## Impact
- **Likelihood**: Low — requires 256 simultaneous open withdrawal requests per account, which is a real-world impossibility
- **Impact**: Low — when it occurs, the assistant's `submitTokenIds` transaction succeeds (no revert) but positions are silently omitted from NAV. The assistant has no on-chain signal to trigger GC. NAV is silently understated for accounts at the cap.
- **Severity**: LOW — practically unreachable but a design inconsistency that breaks the "fail-loud writes" invariant for the assisted-adapter family

## Recommended Mitigation

Apply the fail-loud (revert) pattern uniformly in `EtherFiWithdrawalQueueBalanceAdapter._addTokenId`:

```solidity
if (_tokenIds[account].length >= MAX_TOKEN_IDS) revert TokenIdCacheFull(account, MAX_TOKEN_IDS);
```

This matches the behavior of `UniswapV3PoolsBalanceAdapter` and `NexusMutualStakingPoolsBalanceAdapter` and gives the assistant an on-chain signal to trigger GC before the submission.
