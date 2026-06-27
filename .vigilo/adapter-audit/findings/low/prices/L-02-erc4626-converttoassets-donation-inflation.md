# L-02: ERC4626-backed feeds — convertToAssets donation/inflation sensitivity

## Summary

Five feeds (sGHO, sUSDe, sUSDS, syrupUSDC, RWIV, sXDAI) all call `IERC4626.convertToAssets(10 ** _vaultDecimals)` to obtain the share→asset exchange rate. For vaults with non-atomic total-assets accounting (where `totalAssets()` can be inflated by a direct donation or deflated by a partial-slash), this call can return a temporarily incorrect rate. This is a known ERC4626 inflation/donation sensitivity, previously noted as M-4 in the prior broad audit. The question is whether the concrete vaults in use are susceptible.

## Vulnerability Detail

### Root Cause

`convertToAssets(shares)` is defined in ERC4626 as `shares * totalAssets() / totalSupply()`. If `totalAssets()` is derivable from on-chain state that can be transiently manipulated (e.g. a vault that counts raw token balance), a large donation inflates the per-share rate for one block. The feeds read this value in a single `eth_call` / transaction.

For the specific vaults in scope:
- **sGHO** — Aave GHO staking vault. `totalAssets()` is accrued via an internal accumulator, not raw balance. Low donation sensitivity.
- **sUSDe** — Ethena sUSDe. `totalAssets()` is tracked via an internal vault bookkeeping system, not raw balance. Low sensitivity.
- **sUSDS** — Sky/Maker sUSDS. ERC4626 over MakerDAO's `vat` DSR accounting. `totalAssets()` is computed from `pot.chi` × shares, not raw balance. Low sensitivity.
- **syrupUSDC (mainnet)** — Maple Finance syrup vault. `totalAssets()` reflects queued and deployed USDC via internal accounting. Moderate sensitivity: vault manager deposits/withdrawals can move `totalAssets()` in single transactions but this is gated; simple donation to the vault address does inflate `totalAssets()` if the vault uses `balanceOf(this)`.
- **RWIV** — Nexus Mutual RWI vault (USDC-backed). Similar Maple-style vault structure.
- **sXDAI** — Gnosis Chain savings xDAI. Uses ERC4626; `totalAssets()` from underlying xDAI balance.

The share-unit passed is always `10 ** _vaultDecimals` — this correctly avoids the integer-precision issue that the prior audit's M-4 flagged for calling with a very small share count.

### Code Location (representative)

- File: `src/prices/protocols/sGHO_CustomPriceFeed.sol`
- Lines: 94-95

```solidity
// @audit convertToAssets: correct share unit used; donation sensitivity depends on vault totalAssets() implementation
uint256 sghoToGhoPrice = IERC4626(SGHO).convertToAssets(10 ** _vaultDecimals);
price = sghoToGhoPrice.mulDiv(ghoToUsdPrice.toUint256(), 10 ** _vaultDecimals, Math.Rounding.Floor);
```

Same pattern repeated in: sUSDe (line 95), sUSDS (line 97), syrupUSDC (line 95), RWIV (line 95), sXDAI (line 95).

## Impact

- **Likelihood**: Low — NAVCalculator is a pure read path (`eth_call`); no on-chain transaction flows through it, so flash-loan donation attacks that require atomicity cannot be executed. The remaining risk is a persistent (block-level) donation to a vault that uses raw `balanceOf` in `totalAssets()`.
- **Impact**: Low — since this is a read-only NAV system, an inflated price returns an over-reported portfolio NAV figure for one query cycle. No funds flow through NAVCalculator.
- **Severity**: LOW

## Attack Scenario

Not a viable on-chain exploit against this read-only accounting system. The prior audit's M-4 classification is effectively **refuted** for this codebase: there is no financial transaction triggered by the inflated NAV figure within the same atomic context. The risk reduces to off-chain report integrity.

## Recommended Mitigation

For completeness, prefer `previewRedeem(10 ** _vaultDecimals)` over `convertToAssets` for ERC4626 vaults that may override the latter with custom logic. For vaults where `totalAssets()` counts raw `balanceOf(this)`, consider whether the vault's admin controls mitigate donation risk sufficiently. No code change strictly necessary for this read-only context.
