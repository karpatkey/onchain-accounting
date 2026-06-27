# M-04: Convex CVX Rewards Derivation Uses Current-Block Cliff, Overstating Pending CVX When Supply Advances Before Claim

## Summary

`ConvexRewardsMetaBalanceAdapter._cvxMintAmount()` derives the pending CVX amount from the CRV earned using the CURRENT CVX total supply to determine the emission cliff. CVX is minted when the user actually claims (not at reporting time). Between the NAV read and the eventual claim, additional CVX may be minted by other claimers, advancing the supply into the next cliff and reducing the mint-per-CRV ratio. The adapter thus systematically overstates CVX rewards for claimers who accumulate large positions before claiming.

## Vulnerability Detail

### Root Cause

- File: `src/balances/MetaBalanceAdapters/ConvexRewardsMetaBalanceAdapter.sol`
- Function: `_cvxMintAmount(uint256 crvEarned)`
- Lines: 329–339

```solidity
function _cvxMintAmount(uint256 crvEarned) internal view returns (uint256) {
    if (crvEarned == 0 || CVX_TOKEN == address(0)) return 0;
    (bool ok, uint256 supply) = _safeUint(CVX_TOKEN, abi.encodeWithSignature("totalSupply()"));
    if (!ok) return 0;
    // @audit Uses current block's supply to calculate cliff. Between this read and
    //        actual claim, other CRV claims mint more CVX, advancing the cliff.
    //        The actual minted CVX will be LESS than this estimate once supply crosses
    //        the next cliff boundary during the accumulation period.
    uint256 cliff = supply / _CVX_REDUCTION_PER_CLIFF;
    if (cliff >= _CVX_TOTAL_CLIFFS) return 0;
    uint256 remaining = _CVX_TOTAL_CLIFFS - cliff;
    uint256 cvxAmount = (crvEarned * remaining) / _CVX_TOTAL_CLIFFS;
    uint256 amtTillMax = _CVX_MAX_SUPPLY > supply ? _CVX_MAX_SUPPLY - supply : 0;
    return cvxAmount > amtTillMax ? amtTillMax : cvxAmount;
}
```

### CVX Emission Schedule

The CVX mint schedule: `cvxPerCrv = remainingCliffs / TOTAL_CLIFFS`, where `remainingCliffs = TOTAL_CLIFFS - floor(totalSupply / REDUCTION_PER_CLIFF)`. As more CVX is minted (by all Convex users claiming), `totalSupply` increases, `cliff` advances, and `remainingCliffs` decreases. This reduction is not instantaneous; it occurs in discrete cliff steps.

The exact CVX minted for a given CRV claim depends on `totalSupply` at the MOMENT of the actual `claim()` transaction, not at NAV read time. A large accumulation of CRV earned across a pool will not be claimed atomically — each claimer's CVX is independent. If the reporter holds a large CRV balance unclaimed for weeks while the Convex protocol's CVX supply crosses a cliff boundary, the NAV read uses the OLD cliff (higher `remaining`, higher CVX per CRV) while the actual claim executes at the new cliff (lower `remaining`, less CVX per CRV).

### Quantification

Each cliff covers 100,000 CVX (1/1000th of 100M max supply). At 1,000 total cliffs, the reduction per cliff is 1/1000 = 0.1% of the CRV→CVX ratio. Over many cliffs accumulated across a long non-claiming period (e.g., cliff 700 → cliff 720 between read and claim), the overstatement is `(740 - 720) / 1000 × crvEarned` which is a 2% overstatement on pending CVX. For large positions, this is material relative to the actual CVX claim amount.

Note: this is a read-only valuation issue; no funds are lost from the adapter itself. The risk is NAV overstatement.

## Impact

- **Likelihood**: Medium — CVX supply continuously advances; any position reported during a cliff transition is affected.
- **Impact**: Low-Medium — CVX pending rewards are overstated proportionally to the cliff advancement during the accumulation window. For positions with large CRV balances accumulated over months, the overstatement could reach several percent of CVX value.
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions
- A portfolio account has accumulated large pending CRV rewards across several Convex pools without claiming.
- CVX total supply is near a cliff boundary.

### Attack Steps
1. NAVCalculator calls `ConvexRewardsMetaBalanceAdapter.getAdapterPositions(account, address(0))`.
2. `_cvxMintAmount(crvEarned)` reads `CVX.totalSupply()` at the current block: supply puts the cliff at 750, remaining = 250.
3. Computed CVX = `crvEarned × 250 / 1000`.
4. Position is emitted with this CVX amount and priced at CVX/USD feed.
5. Between NAV read and claim, other Convex users claim, advancing supply past the 751 cliff threshold.
6. When the portfolio's account claims, remaining = 249; actual CVX minted is `crvEarned × 249 / 1000`.
7. NAV was overstated by `crvEarned × 1 / 1000` worth of CVX.
8. Downstream risk systems used the higher reported CVX NAV for portfolio decisions.

### Expected Impact
- Portfolio NAV overstates pending CVX rewards by the cliff-advancement delta.
- Overstatement grows with accumulation time and account position size relative to CVX supply advancement.

## Recommended Mitigation

This is an inherent limitation of snapshot-based reward derivation: exact CVX cannot be predicted in advance because it depends on the global supply at claim time. Two options:

1. **Accept and document**: Mark the CVX rewards as an approximate upper bound in NatSpec. Add a note that NAV consumers should treat CVX pending rewards as estimates (not exact values). This is the pragmatic choice since the error magnitude is typically small.

2. **Conservative cliff look-ahead**: Use `cliff + 1` (the next cliff) as the conservative estimate for large pending amounts. If the current supply is within a configurable threshold (e.g., 10,000 CVX) of a cliff boundary, use the next cliff's `remaining` to avoid reporting at the cliff's edge when the supply is about to cross:

```solidity
uint256 cliff = supply / _CVX_REDUCTION_PER_CLIFF;
// @audit-fix: use conservative estimate at cliff boundaries
uint256 distanceToNextCliff = _CVX_REDUCTION_PER_CLIFF - (supply % _CVX_REDUCTION_PER_CLIFF);
if (distanceToNextCliff < CLIFF_BOUNDARY_THRESHOLD && cliff + 1 < _CVX_TOTAL_CLIFFS) {
    cliff = cliff + 1; // step forward conservatively
}
uint256 remaining = _CVX_TOTAL_CLIFFS - cliff;
```
