# L-02: ERC4626Wrap — `convertToAssets` used instead of `previewRedeem` overstates value for vaults with exit fees

## Summary

`ERC4626WrapBalanceAdapter._calculateBalance` reports `WRAPPER.convertToAssets(WRAPPER.balanceOf(account))`. `convertToAssets` returns the gross underlying per share before any redemption fee; `previewRedeem` returns the net amount the account would actually receive. For vaults with a non-zero exit fee, `convertToAssets` overstates the realisable NAV.

## Vulnerability Detail

### Root Cause

`convertToAssets` is a pure exchange-rate lookup that does not account for redemption fees. ERC-4626 specifies that `previewRedeem` must return "the exact amount of assets that would be withdrawn... including deposit/withdrawal fees". For a fee-bearing vault, `convertToAssets(shares) > previewRedeem(shares)`.

```solidity
// @audit uses convertToAssets — ignores vault exit fee; previewRedeem would give the realisable amount
function _calculateBalance(address account) internal view returns (uint256) {
    return WRAPPER.convertToAssets(WRAPPER.balanceOf(account));
}
```

### Code Location
- File: `src/balances/BalanceAdapters/ERC4626WrapBalanceAdapter.sol`
- Function: `_calculateBalance`
- Line: 190

## Impact

- **Likelihood**: Low — current deployed wrappers (Aave stata-tokens, sGHO) do not have redemption fees. The issue would activate if a future wrapper added an exit fee.
- **Impact**: Low — inflates NAV by the fee amount; since adapters are immutable, a wrapper that later adds a fee would permanently overstate that position until a new adapter is deployed.
- **Severity**: LOW

## Attack Scenario

### Preconditions
- A vault registered with this adapter introduces a non-zero redemption fee (e.g. 0.1%).
- Account holds shares worth 1,000 units of underlying.

### Attack Steps
1. Vault admin introduces a 0.1% exit fee via governance.
2. Adapter continues to call `convertToAssets(shares)` → reports 1,000 units.
3. `previewRedeem(shares)` would return 999 units (after the 0.1% fee).
4. NAVCalculator prices the reported 1,000-unit position at face value; actual exit value is 999 units.

### Expected Impact
- NAV is overstated by the fee fraction of the position's total value. For the current adapters (stata-tokens, sGHO), no overstatement occurs; it becomes active if fees are added.

## Recommended Mitigation

Replace `convertToAssets(balanceOf(account))` with `previewRedeem(balanceOf(account))`. This is equivalent for fee-less vaults and conservative for fee-bearing vaults.

**Prior context:** This corresponds to finding M-4 in the prior Vigilo automated audit (2026-06-vigilo-automated-audit.md). It was triaged as "Deferred — confirm intended valuation basis" in the remediation doc. This review **confirms** the finding is present and code-unchanged; it remains a Low because no current wrapper carries an exit fee.
