# L-03: Cap adapter — per-leg and combined burn-quote paths diverge when the burn fee is non-linear

## Summary

`CapBalanceAdapter` has two parallel valuation paths that can report different USDC values for the same account. `getAdapterPositions` (the NAV path) prices each leg — cUSD and stcUSD→cUSD — with a separate `getBurnAmount` call. `getAdapterBalances` / `getAdapterBalanceForAsset` (the aggregate path) prices the sum of both in one `getBurnAmount` call. If `getBurnAmount` charges a flat or tier-based fee rather than a strictly proportional one, the per-leg sum differs from the combined quote, causing the two interfaces to report inconsistent values.

## Vulnerability Detail

### Root Cause

```solidity
// @audit NAV path: two separate getBurnAmount calls (each pays its own fee)
function _cUsdLegUsdc(address account) internal view returns (uint256) {
    uint256 cUsdBalance = IERC20(address(CUSD)).balanceOf(account);
    if (cUsdBalance == 0) return 0;
    (uint256 usdcAmount,) = CUSD.getBurnAmount(USDC, cUsdBalance);
    return usdcAmount;
}

function _stcUsdLegUsdc(address account) internal view returns (uint256) {
    uint256 stcUsdBalance = IERC20(address(STCUSD)).balanceOf(account);
    if (stcUsdBalance == 0) return 0;
    uint256 cUsdEquiv = STCUSD.convertToAssets(stcUsdBalance);
    if (cUsdEquiv == 0) return 0;
    (uint256 usdcAmount,) = CUSD.getBurnAmount(USDC, cUsdEquiv);
    return usdcAmount;
}

// @audit aggregate path: one combined getBurnAmount call
function _calculateBalance(address account) internal view returns (uint256) {
    uint256 cUsdBalance = IERC20(address(CUSD)).balanceOf(account);
    uint256 stcUsdToCUsd = stcUsdBalance > 0 ? STCUSD.convertToAssets(stcUsdBalance) : 0;
    uint256 totalCUsd = cUsdBalance + stcUsdToCUsd;
    if (totalCUsd == 0) return 0;
    (uint256 usdcAmount,) = CUSD.getBurnAmount(USDC, totalCUsd);
    return usdcAmount;
}
```

### Code Location
- File: `src/balances/BalanceAdapters/CapBalanceAdapter.sol`
- Functions: `_cUsdLegUsdc` (line 215–219), `_stcUsdLegUsdc` (lines 223–229), `_calculateBalance` (lines 236–249)
- The split vs combined invocation pattern is the root cause.

The `getAdapterPositions` (NAV) path will report `sum(_cUsdLegUsdc, _stcUsdLegUsdc)` while `getAdapterBalances` reports `_calculateBalance`. These values diverge if `getBurnAmount` applies a minimum fee, a tiered fee, or any non-proportional function.

## Impact

- **Likelihood**: Low — depends on Cap's actual `getBurnAmount` fee structure. If purely proportional (fee = fixed % of `amountIn`), the two paths are identical. A flat or minimum fee makes them diverge.
- **Impact**: Low-Medium — when divergent, NAVCalculator's NAV read (which uses `getAdapterPositions`) and the legacy `getAdapterBalances` endpoint report different totals for the same account, misleading off-chain consumers that compare the two. The `getAdapterPositions` per-leg path will typically under-report relative to the combined-quote path (each small leg pays the full minimum fee), meaning NAV is conservatively understated.
- **Severity**: LOW

## Attack Scenario

### Preconditions
- Cap protocol's `getBurnAmount` includes a flat minimum fee of F USDC per call.
- Account holds both cUSD and stcUSD.

### Attack Steps
1. NAV path calls `_cUsdLegUsdc` → `getBurnAmount(USDC, cUsdBalance)` → returns `cUsdBalance - F`.
2. NAV path calls `_stcUsdLegUsdc` → `getBurnAmount(USDC, cUsdEquiv)` → returns `cUsdEquiv - F`.
3. Sum reported by `getAdapterPositions` = `(cUsdBalance - F) + (cUsdEquiv - F)` = `total - 2F`.
4. Aggregate path calls `getBurnAmount(USDC, cUsdBalance + cUsdEquiv)` → returns `total - F`.
5. `getAdapterBalances` reports `total - F`; `getAdapterPositions` reports `total - 2F`.
6. Consumers reconciling both interfaces see a discrepancy of F.

### Expected Impact
- `getAdapterPositions`-based NAV is understated by one flat-fee unit relative to the aggregate path. With a zero flat fee (strictly proportional), no divergence. Real-world impact depends on Cap's fee schedule.

## Recommended Mitigation

Unify both paths to use the same quoting approach. The simplest fix is to make `_calculateBalance` also use per-leg quoting (matching `getAdapterPositions`), or make both paths use the combined quote and split the result proportionally. Document which path is authoritative for NAV and which for off-chain display.

**Prior context:** Corresponds to finding M-15 in the prior Vigilo automated audit. Triaged as "Deferred — confirm fee model before changing." This review **confirms** the structural inconsistency is present and unchanged.
