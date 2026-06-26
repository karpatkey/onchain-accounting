# L-01: Custom Feed `getLatestPrice()` Not Called at Registration — Oversized Price Undetected Until Runtime

## Summary

`PriceFeedLib.addFeed` calls `_validateFeedSupportInternal` which, for `PriceType.Custom` feeds, only checks `supportsInterface`. It never invokes `getLatestPrice()`. Consequently, a Custom feed whose current price already exceeds `type(int256).max` passes registration without triggering the overflow that would later crash `selectFeed`. The discrepancy between what is validated at `addFeed` time and what is executed at `selectFeed` time creates a gap where a broken or adversarially crafted feed can be registered cleanly and only reveals itself as a DoS once live queries begin.

## Vulnerability Detail

**Registration path for Custom feeds (`PriceFeedLib.sol:148-177`):**

```solidity
function addFeed(...) external {
    _validateFeedSupportInternal(asset, priceFeed, priceType);
    // ...
    uint8 dec;
    if (priceType == IPrices.PriceType.Custom) {
        dec = ICustomPriceFeed(priceFeed).decimals();  // only decimals() is called
    }
    // getLatestPrice() is NEVER called here
    configs.push(...);
}
```

**`_validateFeedSupportInternal` for Custom feeds (`PriceFeedLib.sol:232-234`):**

```solidity
if (priceType == IPrices.PriceType.Custom) {
    if (!priceFeed.supportsInterface(type(ICustomPriceFeed).interfaceId)) revert IPrices.InvalidPriceOracle();
}
// no call to getLatestPrice(), no price or decimals sanity check
```

**Contrast with non-Custom feeds:** For `Chainlink/Redstone/API3`, the validator calls `latestRoundData()` and checks `updatedAt`/`startedAt` against `block.timestamp` (lines 241-242). Custom feeds receive no equivalent liveness or value check.

This means:
- A feed returning `price = type(uint256).max` can be registered.
- The overflow at `customPrice.toInt256()` (line 58) only materializes during `selectFeed` — a runtime DoS described separately in H-01.
- Even without the H-01 overflow, a feed with `stale=true` for its entire lifetime, or one that always returns `price=0`, can be registered and will silently be skipped on every query with no operator notification.

## Root Cause

**File:** `src/prices/PriceFeedLib.sol`, function `addFeed` (~line 148) and `_validateFeedSupportInternal` (~line 232)

No call to `getLatestPrice()` is made for `PriceType.Custom` feeds during registration.

## Impact

- **Silent useless feeds:** A Custom feed that is perpetually stale or always returns `price=0` can be registered without detection, inflating `getPriceFeedCount()` while never contributing to `selectFeed`.
- **Enables H-01 DoS pathway:** The missing check at registration is the first half of the exploit chain. A complete liveness/bounds check at registration would block the overflow before it can be deployed.
- **Operator confusion:** Operators relying on `getPriceFeedCount() > 1` as a redundancy signal may believe they have backup feeds when all Custom feeds are non-functional.

## Preconditions

- MANAGER role registers a Custom price feed.
- The feed is broken or adversarially crafted from the start.

## Mitigation

Add a liveness and bounds check for Custom feeds inside `addFeed` (or `_validateFeedSupportInternal`):

```solidity
if (priceType == IPrices.PriceType.Custom) {
    (uint256 p, bool s) = ICustomPriceFeed(priceFeed).getLatestPrice();
    // Reject feeds that are already stale or return a price that would overflow int256
    if (s) revert IPrices.InvalidPriceOracle();          // currently stale
    if (p == 0) revert IPrices.InvalidPriceOracle();     // zero price
    if (p > uint256(type(int256).max)) revert IPrices.InvalidPriceOracle(); // overflow guard (see H-01)
    dec = ICustomPriceFeed(priceFeed).decimals();
}
```

Note: The `stale` check should arguably be a warning rather than a hard revert in some deployment flows (e.g., a freshly deployed feed with no data yet). Consider an additional flag or a grace allowance for the registration context. The overflow guard (`p > type(int256).max`) should be unconditional.
