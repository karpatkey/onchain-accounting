# M-02: CapBalanceAdapter NAV path and balance-getter path use structurally different burn-quote methods

## Summary

`CapBalanceAdapter.getAdapterPositions` values each cUSD/stcUSD leg by calling `ICUsd.getBurnAmount` separately per leg, while `getAdapterBalances` / `getAdapterBalanceForAsset` call `getBurnAmount` once on the combined cUSD total. For any burn-fee function that is not perfectly linear (e.g. has a fixed-cost component, tiered fees, or integer-rounding characteristics), the two paths return inconsistent results. The NatSpec comment that the two "may differ from this combined figure by at most burn-quote rounding" is incorrect when `getBurnAmount` is nonlinear.

## Vulnerability Detail

### Root Cause

`_calculateBalance` (used by the no-arg getters) aggregates:
```solidity
// @audit combined quote: one call on totalCUsd
(uint256 usdcAmount,) = CUSD.getBurnAmount(USDC, totalCUsd);
return usdcAmount;
```

`getAdapterPositions` quotes each leg independently:
```solidity
// @audit separate quotes: cUSD leg
(uint256 usdcAmount,) = CUSD.getBurnAmount(USDC, cUsdBalance);   // _cUsdLegUsdc

// @audit separate quotes: stcUSD leg
(uint256 usdcAmount,) = CUSD.getBurnAmount(USDC, cUsdEquiv);     // _stcUsdLegUsdc
```

The NatSpec at `CapBalanceAdapter.sol:235` states: "the two may differ from this combined figure by at most burn-quote rounding." For a purely proportional fee `f(x) = x * rate`, the two-leg sum equals the combined value minus at most 1 integer unit (sum-of-floors ≤ floor-of-sum). However, for a nonlinear fee function — such as a fixed-fee component (`fee = base + x * rate`) or a tiered fee structure — the two-leg sum can differ from the combined value by an unbounded amount.

### Code Location

- File: `src/balances/BalanceAdapters/CapBalanceAdapter.sol`
- Functions: `_calculateBalance()` vs `_cUsdLegUsdc()` + `_stcUsdLegUsdc()`
- Lines: 215-230 (separate leg quotes), 236-250 (combined quote)

```solidity
// @audit NAV path: two separate burn-quotes
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

// @audit balance-getter path: one combined burn-quote
function _calculateBalance(address account) internal view returns (uint256) {
    uint256 totalCUsd = cUsdBalance + stcUsdToCUsd;
    if (totalCUsd == 0) return 0;
    (uint256 usdcAmount,) = CUSD.getBurnAmount(USDC, totalCUsd);
    return usdcAmount;
}
```

## Impact

- **Likelihood**: Medium — triggered whenever an account holds both cUSD and stcUSD AND the Cap protocol's burn function has any nonlinear characteristics (fixed-cost component, nonlinear fee tiers, or rounding at small amounts).
- **Impact**: Low — only affects off-chain consumers that compare `getAdapterBalances` with the NAV `getAdapterPositions` output and expect them to be identical. The NAV path (`getAdapterPositions`) is the canonical source for portfolio valuation; the inconsistency does not affect the correctness of the NAV value itself, since integer arithmetic guarantees that for any convex fee function the two-leg split under-reports versus the combined call (sum-of-floors ≤ floor-of-sum). For a fixed-cost-per-call fee structure, the two-leg path would over-report by up to one fee increment.
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions

- Cap protocol's `getBurnAmount` has a fixed-cost component per call (e.g., a minimum 1 USDC fee regardless of amount).
- An account holds both cUSD and stcUSD.

### Attack Steps

1. Account holds 1 cUSD and 1 stcUSD-equivalent-in-cUSD.
2. `_calculateBalance` calls `getBurnAmount(USDC, 2_cUSD)`: deducts 1 USDC fixed fee from combined, returns 1 USDC net.
3. `getAdapterPositions` calls `getBurnAmount(USDC, 1_cUSD)` (returns 0 after deducting 1 USDC fixed fee) + `getBurnAmount(USDC, 1_cUSD)` (returns 0). Sum = 0.
4. NAV reports 0 USDC for this account; balance getter returns 1 USDC.
5. Alternatively, with a fee structure where split yields more, NAV path over-reports versus the balance getter.

### Expected Impact

- NAV and balance-getter diverge for accounts with mixed cUSD/stcUSD positions when the burn function is nonlinear.
- External consumers relying on `getAdapterBalances` for reconciliation against NAV will see persistent discrepancies.

## Recommended Mitigation

Reuse `_calculateBalance` logic in `getAdapterPositions` for the total USDC computation, then apportion between legs by their proportional cUSD input:

```solidity
uint256 totalCUsd = cUsdBalance + stcUsdToCUsd;
if (totalCUsd == 0) return new INAVCalculator.PositionBalance[](0);
(uint256 totalUsdc,) = CUSD.getBurnAmount(USDC, totalCUsd);

uint256 cUsdUsdc = totalCUsd > 0 ? totalUsdc * cUsdBalance / totalCUsd : 0;
uint256 stcUsdUsdc = totalUsdc - cUsdUsdc;
```

This ensures both paths use the same burn-quote call and the leg split is exact (within 1 unit of integer rounding).
