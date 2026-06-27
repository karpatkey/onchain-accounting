# M-03: Lido Withdrawal Queue Adapter Uses `amountOfStETH` for Non-Finalized Requests, Overstating NAV After a Negative Rebase

## Summary

`LidoWithdrawalQueueBalanceAdapter._ethOwed()` reports `amountOfStETH` — fixed at request creation time — for withdrawal requests that are not yet finalized. After a Lido negative rebase event (slashing), `amountOfStETH` exceeds the ETH that Lido will actually pay out when the request is finalized. The adapter therefore overstates the ETH value of pending (non-finalized) withdrawal positions during and after a negative rebase.

## Vulnerability Detail

### Root Cause

- File: `src/balances/BalanceAdapters/LidoWithdrawalQueueBalanceAdapter.sol`
- Function: `_ethOwed(address account)`
- Lines: 120–128

```solidity
for (uint256 i = 0; i < statuses.length; i++) {
    if (statuses[i].isClaimed) {
        continue;
    }
    if (statuses[i].isFinalized && lastCheckpoint != 0) {
        // … uses getClaimableEther() — correct for finalized requests
        total += WITHDRAWAL_QUEUE.getClaimableEther(one, hint)[0];
    } else {
        // @audit For non-finalized requests, uses amountOfStETH locked AT REQUEST TIME.
        // After a negative rebase, Lido caps finalization at the post-rebase ETH amount,
        // which will be LESS than amountOfStETH. This is not yet reflected here.
        total += statuses[i].amountOfStETH;
    }
}
```

### Lido Negative-Rebase Behavior

When Lido applies a negative rebase (validator slashing):

1. `stETH` balances decrease proportionally across all holders.
2. `amountOfStETH` in withdrawal requests is a fixed snapshot from request-creation time — it does **not** adjust for subsequent rebases.
3. When Lido finalizes a request after a negative rebase, the payout is capped at the post-rebase ETH equivalent: `min(amountOfStETH, totalEth / totalShares × amountOfShares)`.
4. The adapter's fallback (`total += statuses[i].amountOfStETH`) uses the pre-rebase value and will therefore overstate the eventual payout.

The NatSpec at line 22 states: "amountOfStETH is fixed at request time and equals the ETH paid on claim (verified on-chain; it can differ only on a negative rebase between request and finalization, where Lido caps the payout)." The adapter acknowledges this risk in its NatSpec but does not mitigate it in code.

### Severity Context

Lido negative rebases are rare but have occurred historically (e.g. Shapella-related slashing events). A significant slashing event (e.g. a large validator set penalized) could reduce stETH balances materially (0.1%–1%+ in severe scenarios). For large pending withdrawal queues, the absolute overstatement compounds across many open requests.

## Impact

- **Likelihood**: Low — Lido negative rebases are infrequent; the window is the period between rebase and finalization of the affected requests.
- **Impact**: Medium — Every pending withdrawal request is reported at the pre-rebase `amountOfStETH`. The true claimable ETH is lower. Portfolio NAV is overstated during the rebase-to-finalization window.
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions
- A portfolio account has multiple open (non-finalized) Lido withdrawal requests totaling a significant ETH amount.
- Lido experiences a negative rebase event reducing stETH balances by ~0.5%.

### Attack Steps
1. Validator slashing event triggers Lido negative rebase; stETH balances decrease by 0.5%.
2. Open withdrawal requests' `amountOfStETH` values are NOT updated (they are snapshots from request time).
3. NAVCalculator calls `LidoWithdrawalQueueBalanceAdapter.getAdapterPositions(account, address(0))`.
4. For each non-finalized request, `statuses[i].amountOfStETH` returns the pre-rebase ETH amount.
5. The position is emitted with an inflated `amount`.
6. NAVCalculator prices the inflated amount at the ETH/USD feed → overstated NAV.
7. Downstream risk systems see a portfolio NAV that does not reflect the post-rebase reduction.
8. When requests eventually finalize, the claimable ETH is lower, but NAV was overstated during the interim.

### Expected Impact
- Portfolio NAV is overstated by the negative-rebase delta on all non-finalized withdrawal positions.
- The overstatement is temporary (resolves when requests are finalized), but during the window it misrepresents true portfolio value.

## Recommended Mitigation

For non-finalized requests, use `amountOfShares` (the shares snapshot, which does not change on rebase) and compute the current ETH value from the current `stETH/share` rate, rather than the fixed `amountOfStETH`:

```solidity
} else {
    // @audit-fix: value non-finalized requests using current share price,
    // not the frozen amountOfStETH (which does not adjust for negative rebases).
    // getCurrentShareRate() or getPooledEthByShares(amountOfShares) gives the
    // current ETH value of the locked shares:
    uint256 currentEth = WITHDRAWAL_QUEUE.getPooledEthByShares(statuses[i].amountOfShares);
    total += currentEth < statuses[i].amountOfStETH ? currentEth : statuses[i].amountOfStETH;
}
```

If Lido's `WithdrawalQueueERC721` exposes a `getPooledEthByShares` or equivalent, that call gives the current-rate ETH value of the locked shares, which is post-rebase-correct. Alternatively, call the stETH contract's `getPooledEthByShares(amountOfShares)` to obtain the current share value. The minimum of the current share value and `amountOfStETH` is the realistic upper bound on payout.
