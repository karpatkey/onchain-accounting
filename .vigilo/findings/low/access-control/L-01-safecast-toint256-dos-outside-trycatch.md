# SafeCast.toInt256 revert outside try/catch can permanently DoS selectFeed

## Severity: Low

## Summary
`PriceFeedLib.selectFeed` calls `customPrice.toInt256()` outside the try/catch block that
guards `getLatestPrice()`. A custom feed that returns a non-stale price ≥ 2^255 causes an
uncaught revert, making every call that reads this token's price permanently revert.

## Vulnerability Detail
`PriceFeedLib.sol:51–58`:
```solidity
try ICustomPriceFeed(cfg.priceFeed).getLatestPrice() returns (uint256 p, bool s) {
    customPrice = p;
    internalStale = s;
} catch {
    continue;  // ← catches reverts from getLatestPrice()
}
if (internalStale || customPrice == 0) continue;
rawPrice = customPrice.toInt256();  // ← OUTSIDE try/catch; reverts if p >= 2^255
```
If any registered Custom adapter returns `(type(uint256).max, false)` — for example due to
an arithmetic overflow in its `_compute()` function — the revert at line 58 propagates
through the entire loop with no handler.

## Root Cause
`src/prices/PriceFeedLib.sol:58` — `toInt256()` is not guarded.

## Impact
`selectFeed` permanently reverts for every call on that token. This cascades to
`latestPrice`, `getAccountNav`, `getAccountPositions`, and `calculateValue` for the affected
asset. Recovery requires removing the offending feed, which requires admin action.

## Preconditions
A registered Custom adapter must return price ≥ 2^255. This cannot happen for any legitimate
asset with realistic USD prices (2^255 / 1e8 ≈ $5.7 × 10^68), but could arise from an
arithmetic overflow bug in a custom adapter.

## Mitigation
Add a bounds check before the cast:
```solidity
if (customPrice > uint256(type(int256).max)) continue;
rawPrice = int256(customPrice);
```
