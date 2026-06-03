# L-02: ERC-165 Guard for Non-Custom Feed Types Does Not Verify `AggregatorV3Interface` Compliance

## Summary

`_validateFeedSupportInternal` for `Chainlink`, `Redstone`, and `API3` feed types verifies only that the candidate address does **not** claim to implement `IPriceFeedCustom` via ERC-165, and that `latestRoundData()` returns non-future timestamps. It does not verify that the feed implements the full `AggregatorV3Interface` (e.g., a meaningful `decimals()` return, a non-reverting `getRoundData`). A minimalist contract that implements `latestRoundData()` returning zeros for `updatedAt`/`startedAt` — and any non-zero value for `answer` — can pass registration and silently fail in production.

## Vulnerability Detail

**`_validateFeedSupportInternal` for non-Custom types (`PriceFeedLib.sol:234-243`):**

```solidity
} else if (
    priceType == IPrices.PriceType.Chainlink || priceType == IPrices.PriceType.Redstone
        || priceType == IPrices.PriceType.API3
) {
    if (priceFeed.supportsInterface(type(IPriceFeedCustom).interfaceId)) {
        revert IPrices.InvalidPriceOracle();
    }
    (,, uint256 startedAt, uint256 updatedAt,) = AggregatorV3Interface(priceFeed).latestRoundData();
    if (updatedAt > block.timestamp || startedAt > block.timestamp) revert IPrices.InvalidPriceOracle();
}
```

Observations:
1. The `answer` field from `latestRoundData()` is not checked at registration time. A feed returning `answer = 0` passes validation but will be skipped in `selectFeed` (since `answer <= 0 → continue`) without any alert.
2. A feed returning `updatedAt = 0` and `startedAt = 0` passes both checks (`0 > block.timestamp` is false) and can be registered. In `selectFeed`, `effectiveTime = 0`, and `block.timestamp - 0 >= chainlinkHeartbeat` will be true for any realistic heartbeat, making the feed always-stale and never useful.
3. The check that the feed does NOT implement `IPriceFeedCustom` is a negative guard. It does not confirm the feed correctly implements `AggregatorV3Interface` beyond the single `latestRoundData()` call.

**Specific case: a "zero-answer" feed at registration that later provides valid prices** — this is not a bug. But the inverse (feed has valid answer at registration, later always returns `answer = 0`) is not caught until the feed stops contributing to `selectFeed` without notification.

## Root Cause

**File:** `src/prices/PriceFeedLib.sol`, function `_validateFeedSupportInternal`, lines 234-243

No check on `answer` value and no check that `updatedAt > 0` (indicating at least one historical data point exists).

## Impact

- **Silent dead feeds:** A feed with `answer = 0` or `updatedAt = 0` at registration is useless but registerable. Operators relying on `getPriceFeedCount()` for redundancy may be unaware a registered feed contributes nothing.
- **No functional impact if at least one valid feed exists:** The fallback mechanism in `selectFeed` skips bad feeds, so a useless feed does not cause a wrong price — it only reduces the effective redundancy count.
- Severity is **Low** because the multi-feed design is specifically intended to survive individual feed failures.

## Preconditions

- MANAGER registers a feed with `answer = 0` or with `updatedAt = 0`.

## Mitigation

Add a minimum-viability check at registration for non-Custom feeds:

```solidity
(, int256 answer, uint256 startedAt, uint256 updatedAt,) = AggregatorV3Interface(priceFeed).latestRoundData();
if (updatedAt > block.timestamp || startedAt > block.timestamp) revert IPrices.InvalidPriceOracle();
if (answer <= 0) revert IPrices.InvalidPriceOracle();   // reject zero/negative price at registration
if (updatedAt == 0) revert IPrices.InvalidPriceOracle(); // reject uninitialized feed
```

These checks match the conditions that `selectFeed` uses to discard feeds at query time, ensuring that only feeds that would currently contribute can be registered. A feed that later becomes stale or returns a zero price is still gracefully skipped; this only tightens the registration gate.
