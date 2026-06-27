# M-01: ERC4626 Balance Adapters Use `convertToAssets` Instead of `previewRedeem`, Overstating NAV When Vaults Charge Exit Fees

## Summary

`ERC4626WrapBalanceAdapter` and `MorphoVaultsMetaBalanceAdapter` both compute a holder's underlying balance by calling `IERC4626.convertToAssets(shares)`. Per EIP-4626, `convertToAssets` MUST NOT account for withdrawal/exit fees; `previewRedeem` SHOULD account for them. When a vault charges a fee-on-redemption (e.g. a Morpho vault's performance fee taken at withdrawal, or any fee-bearing ERC4626 wrapper), the adapter overstates the redeemable underlying and inflates portfolio NAV.

## Vulnerability Detail

### Root Cause

- File: `src/balances/BalanceAdapters/ERC4626WrapBalanceAdapter.sol`
- Function: `_calculateBalance(address account)`
- Line: 190

```solidity
// @audit convertToAssets MUST NOT include withdrawal fees per EIP-4626 §4.3
// Use previewRedeem to obtain the true net-of-fees redeemable amount.
function _calculateBalance(address account) internal view returns (uint256) {
    return WRAPPER.convertToAssets(WRAPPER.balanceOf(account));
}
```

- File: `src/balances/MetaBalanceAdapters/MorphoVaultsMetaBalanceAdapter.sol`
- Function: `_instancePositions(address account, bytes32 instance, address assetFilter)`
- Line: 49

```solidity
// @audit same pattern — convertToAssets returns gross-of-fees amount
uint256 amount = vault.convertToAssets(vault.balanceOf(account));
```

EIP-4626 §4.3 specifies: `convertToAssets` MUST NOT be inclusive of any fees that are charged against assets in the Vault. `previewRedeem` SHOULD be inclusive of withdrawal fees.

### Affected Adapters

| Adapter | Vault family | Fee exposure |
|---|---|---|
| `ERC4626WrapBalanceAdapter` | Any ERC4626 wrapper (Nexus RWIV, syrupUSDC, Maple Finance, sGHO, sXDAI) | Fee-on-redeem charged by vault |
| `MorphoVaultsMetaBalanceAdapter` | All Morpho ERC4626 vaults configured on NAVCalculator | Performance fee taken on withdrawal |

For Morpho vaults specifically, the Morpho curator can enable a performance fee charged at withdrawal; `convertToAssets` returns a higher amount than `previewRedeem` in that case.

### Note on wave-1 finding M-05

Wave-1 M-05 covered `convertToAssets` being manipulable by **token donation** in the six custom **price feeds**. This finding is distinct: it concerns the **balance adapters** computing the account's BALANCE (share count → underlying amount), not the price. A vault with an exit fee returns a lower `previewRedeem` than `convertToAssets` even without any donation. The two issues compose: donation inflates the computed price AND the computed balance, compounding the NAV overstatement.

## Impact

- **Likelihood**: Medium — Morpho vault curators do configure performance fees; new ERC4626 wrappers added may have withdrawal fees by design.
- **Impact**: Medium — For each fee-bearing vault, every account's position is overstated by `feeRate × position`. If a vault charges a 2% performance fee, a 500 USDC position is reported as 510 USDC. Downstream systems consuming NAV for risk management or rebalancing decisions are misled.
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions
- A Morpho vault configured on NAVCalculator charges a 1% fee on redemption.
- A portfolio account holds 100,000 vault shares whose `convertToAssets` → 10,000 USDC but `previewRedeem` → 9,900 USDC (fee = 100 USDC).

### Attack Steps
1. NAVCalculator calls `MorphoVaultsMetaBalanceAdapter.getAdapterPositions(account, address(0))`.
2. The adapter calls `vault.convertToAssets(vault.balanceOf(account))` and gets 10,000 USDC.
3. The position is emitted as `amount = 10,000 USDC`.
4. NAVCalculator prices 10,000 USDC at the registered USDC/USD feed → overstated NAV.
5. The true liquidatable value is 9,900 USDC (fee applies on exit), but NAV reports the higher amount.
6. Risk controls, rebalancing triggers, or redemption limits based on this NAV use a misleadingly high figure.

### Expected Impact
- Portfolio NAV is overstated by the exit-fee amount across all fee-bearing ERC4626 vault positions.
- Systemic risk: if the portfolio holds many such positions, cumulative overstatement could mask solvency issues.

## Recommended Mitigation

Replace `convertToAssets(shares)` with `previewRedeem(shares)` in both adapters:

```solidity
// ERC4626WrapBalanceAdapter._calculateBalance — corrected
function _calculateBalance(address account) internal view returns (uint256) {
    // @audit-fix: previewRedeem includes withdrawal fees; convertToAssets does not
    return WRAPPER.previewRedeem(WRAPPER.balanceOf(account));
}

// MorphoVaultsMetaBalanceAdapter._instancePositions — corrected
uint256 amount = vault.previewRedeem(vault.balanceOf(account));
```

Note that `previewRedeem` may revert on some vault implementations (e.g. paused vaults). Wrap in try/catch or treat a revert as zero balance, consistent with the existing defensive pattern in `MetaBalanceAdapter`.
