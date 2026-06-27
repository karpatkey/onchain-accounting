# L-04: Lido withdrawal queue — non-finalized requests valued at `amountOfStETH` which can exceed final claimable ETH after a negative rebase

## Summary

`LidoWithdrawalQueueBalanceAdapter._ethOwed` uses the exact claimable ETH (`getClaimableEther`) only for finalized requests. For not-yet-finalized requests it falls back to `amountOfStETH`, which is the stETH amount locked at request time. After a significant negative rebase, Lido's finalization algorithm caps the per-share payout below 1:1 with stETH to protect the staker pool; in that window, `amountOfStETH` overstates the ETH the account will actually receive.

## Vulnerability Detail

### Root Cause

```solidity
// @audit finalized: exact claimable ETH used (correct)
if (statuses[i].isFinalized && lastCheckpoint != 0) {
    uint256[] memory one = new uint256[](1);
    one[0] = ids[i];
    uint256[] memory hint = WITHDRAWAL_QUEUE.findCheckpointHints(one, 1, lastCheckpoint);
    total += WITHDRAWAL_QUEUE.getClaimableEther(one, hint)[0];
} else {
    // @audit not finalized: amountOfStETH used — fixed at request time, not discounted for negative rebase
    total += statuses[i].amountOfStETH;
}
```

`amountOfStETH` is immutable once set at request submission. Lido's finalisation caps payout per share based on the protocol's available ETH buffer. In a prolonged negative-rebase scenario, the actual claimable ETH on finalization will be lower than `amountOfStETH`. Until finalization occurs, the adapter has no way to know the real discount.

### Code Location
- File: `src/balances/BalanceAdapters/LidoWithdrawalQueueBalanceAdapter.sol`
- Function: `_ethOwed`
- Lines: 110–129

## Impact

- **Likelihood**: Low — requires a Lido negative rebase severe enough to trigger payout capping. Historical frequency is very low; Lido has strong social/governance mechanisms to prevent large slashings.
- **Impact**: Low — position is overstated by at most the discount applied by Lido's finalization algorithm. The overstatement persists only until the request is finalized (days to weeks), after which the exact claimable ETH is used.
- **Severity**: LOW

## Attack Scenario

### Preconditions
- A large Ethereum validator slashing event causes Lido's stETH:ETH ratio to drop below 1.
- An account has open (non-finalized) Lido withdrawal requests with total `amountOfStETH` = X.

### Attack Steps
1. Negative rebase occurs; Lido's finalization will apply a discount so the account receives X × discount_factor ETH.
2. Before finalization, adapter reads `amountOfStETH = X` for the pending requests.
3. NAV includes X ETH worth of credit for this position.
4. Finalization occurs; actual ETH received is X × discount_factor < X.
5. NAV was overstated between the rebase and finalization.

### Expected Impact
- NAV is temporarily overstated by `X × (1 - discount_factor)` for the duration between the negative rebase and finalization. Once finalized, the position corrects to the exact claimable amount. No permanent loss; the overstatement is bounded by the finalization cycle.

## Recommended Mitigation

The root cause is that the ETH/stETH conversion discount during finalization is not known until Lido processes the checkpoint. The most conservative fix is to estimate pending requests at the current protocol redemption rate rather than at the locked `amountOfStETH`. Lido's `stETH.getPooledEthByShares(amountOfShares)` gives a live rate estimate. Alternatively, document this as an accepted upper-bound estimate and add a NatSpec note explicitly stating that non-finalized requests may be overstated in negative-rebase scenarios.

**Prior context:** Corresponds to finding M-6 in the prior Vigilo automated audit. Triaged as "Deferred — confirm cap formula and regenerate snapshots." This review **confirms** the issue is structurally present and unchanged. The adapter's existing NatSpec ("It equals the ETH paid in the normal case") partially acknowledges it, but the normal case caveat is only in a comment, not enforced.
