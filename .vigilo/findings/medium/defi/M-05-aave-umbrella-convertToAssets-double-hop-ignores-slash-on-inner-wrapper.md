# M-05: Aave Umbrella Adapter Uses `convertToAssets` on waToken Wrapper — Fee-on-Redeem on Inner Wrapper Overstates Principal

## Summary

`AaveUmbrellaBalanceAdapter._stakedUnderlying()` resolves the staked balance via up to two `convertToAssets` calls: one on the stake token itself and one on the intermediate waToken wrapper (`stk → waToken → bare reserve`). Like the ERC4626WrapBalanceAdapter (see M-01), `convertToAssets` does not include withdrawal fees per EIP-4626. If the waToken wrapper (`StaticATokenLM` / `StataTokenV2`) charges a fee on redemption (possible via Aave governance), the staked balance is overstated. More importantly, the `convertToAssets` call on the waToken does not account for the current Aave exchange rate being fully up-to-date vs the stored index.

## Vulnerability Detail

### Root Cause

- File: `src/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.sol`
- Function: `_stakedUnderlying(address stakeToken, address account)`
- Lines: 271–286

```solidity
function _stakedUnderlying(address stakeToken, address account) internal view returns (uint256) {
    uint256 amount = IUmbrellaStakeToken(stakeToken).balanceOf(account);
    if (amount == 0) return 0;
    // Step 1: stake token shares → stake token's underlying (waToken units)
    amount = IUmbrellaStakeToken(stakeToken).convertToAssets(amount);

    address firstLevel = _safeAsset(stakeToken);
    if (firstLevel == address(0)) return amount;

    if (_isErc4626Wrapper(firstLevel)) {
        // @audit Step 2: waToken units → bare reserve.
        // convertToAssets does NOT include withdrawal fees per EIP-4626.
        // For StaticATokenLM (waToken), convertToAssets uses the STORED Aave index, not
        // the accrued-but-not-yet-updated index; this slightly understates yield at this level
        // but the fee issue overstates net value.
        return IERC4626Like(firstLevel).convertToAssets(amount);
    }
    return amount;
}
```

### Two Distinct Issues

**Issue A (Fee-on-Redeem)**: Same as M-01. If Aave governance introduces a fee on the `StataTokenV2` redemption, `convertToAssets` would return more than `previewRedeem`, overstating the recoverable underlying.

**Issue B (Accrued vs Stored Index)**: The Aave `StaticATokenLM.convertToAssets()` uses the Aave liquidity index from the LAST on-chain index update. Between index updates (triggered by interactions), the real accrued value is slightly higher (new interest accrued). `previewRedeem` on the `StaticATokenLM` typically uses `refreshRate()` internally, which fetches the current accrued index from Aave's `getReserveNormalizedIncome()`. For large positions over long periods without interactions, this discrepancy accumulates.

In practice, Issue B causes a slight UNDERSTATEMENT (not overstatement) of the principal. The net direction of error depends on which effect dominates.

### Context

The NatSpec for the adapter documents at line 49: "Slashing-correctness: Umbrella stake tokens reduce `totalAssets` while keeping `totalSupply` constant when slashing fires, so the chained `convertToAssets` walk is automatically post-slash-correct." This is accurate for slashing on the STAKE TOKEN level. The issue raised here is at the INNER WRAPPER level (waToken), which does not slash but may charge fees.

## Impact

- **Likelihood**: Low — Aave governance would need to enable waToken withdrawal fees, which is not current behavior.
- **Impact**: Low-Medium — If inner wrapper fees are introduced, all Umbrella staked positions using the `stkwa*` family of tokens (e.g., `stkwaEthUSDC`, `stkwaEthWETH`) would have overstated balances.
- **Severity**: MEDIUM (forward-looking risk)

## Attack Scenario

### Preconditions
- Aave governance introduces a 0.5% redemption fee on `StataTokenV2` (waToken).
- A portfolio account holds a large balance of `stkwaEthUSDC`.

### Attack Steps
1. Aave governance activates a 0.5% fee on `StataTokenV2.redeem()`.
2. NAVCalculator calls `AaveUmbrellaBalanceAdapter.getAdapterPositions(account, address(0))`.
3. `_stakedUnderlying` calls `waToken.convertToAssets(amount)` → returns gross-of-fee amount.
4. True recoverable amount (via `previewRedeem`) is 0.5% lower.
5. Position is emitted at the inflated amount; NAV is overstated.
6. Risk systems relying on NAV do not detect the delta.

### Expected Impact
- Portfolio NAV for Umbrella stkwa* positions is overstated by the inner wrapper fee rate.

## Recommended Mitigation

Replace `convertToAssets` with `previewRedeem` for the inner wrapper conversion:

```solidity
if (_isErc4626Wrapper(firstLevel)) {
    // @audit-fix: previewRedeem includes withdrawal fees; convertToAssets does not
    // Also: StaticATokenLM.previewRedeem uses refreshRate() → accrued-but-not-stored index
    (bool ok, bytes memory ret) = firstLevel.staticcall{gas: PROBE_GAS}(
        abi.encodeWithSignature("previewRedeem(uint256)", amount)
    );
    if (!ok || ret.length < 32) return 0;
    return abi.decode(ret, (uint256));
}
```

This also resolves Issue B by using the accrued-index path in `StaticATokenLM.previewRedeem`. The try/catch pattern consistent with the existing PROBE_GAS approach is recommended to handle non-standard implementations gracefully.
