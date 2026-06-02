# Non-custom feed registration does not validate answer > 0 or updatedAt > 0

## Severity: Low

## Summary
`_validateFeedSupportInternal` checks only that `updatedAt <= block.timestamp` and
`startedAt <= block.timestamp`. A feed returning `answer = 0` or `updatedAt = 0` at
registration time passes validation, registers cleanly, but is silently skipped on every
`selectFeed` call — inflating the registered feed count without providing redundancy.

## Root Cause
`src/prices/PriceFeedLib.sol:241–242`:
```solidity
(,, uint256 startedAt, uint256 updatedAt,) = AggregatorV3Interface(priceFeed).latestRoundData();
if (updatedAt > block.timestamp || startedAt > block.timestamp) revert IPrices.InvalidPriceOracle();
```
No check on `answer > 0` or `updatedAt > 0`.

## Impact
Operators may believe an asset has N healthy feeds when some registered feeds have never
produced a valid price. With two registered feeds, if one is silently always-skip, the asset
has effectively one feed with no redundancy — but the operator sees `healthyFeedCount = 0`
only after a call, not at registration time.

## Mitigation
Add at registration time:
```solidity
int256 answer;
(, answer,, uint256 updatedAt,) = AggregatorV3Interface(priceFeed).latestRoundData();
if (answer <= 0 || updatedAt == 0) revert IPrices.InvalidPriceOracle();
```
