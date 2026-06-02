# L-02 — `selectFeed` calls `getLatestPrice()` and then `latestRoundData()` separately on Custom feeds, allowing a malicious Custom adapter to return inconsistent data between the two calls

## Summary

`PriceFeedLib.selectFeed` makes two separate `try/catch` external calls to a Custom feed in sequence: first `getLatestPrice()` (line 51) and then `latestRoundData()` (line 60). Between these two calls, a reentrant or state-changing Custom feed could return a valid price from `getLatestPrice()` but a manipulated `updatedAt` from `latestRoundData()`, causing `selectFeed` to accept the price but assign it an artificially large or small `updatedAt` for the winner-selection race.

## Vulnerability Detail

```solidity
// PriceFeedLib.sol:51-67
try IPriceFeedCustom(cfg.priceFeed).getLatestPrice() returns (uint256 p, bool s) {
    customPrice = p;
    internalStale = s;
} catch { continue; }

if (internalStale || customPrice == 0) continue;
rawPrice = customPrice.toInt256();

try IPriceFeedCustom(cfg.priceFeed).latestRoundData() returns (
    uint80, int256, uint256, uint256 u, uint80
) {
    lrdUpdatedAt = u;
} catch { continue; }

updatedAt = lrdUpdatedAt == 0 ? (block.timestamp > 0 ? block.timestamp - 1 : 0) : lrdUpdatedAt;
```

A Custom adapter contract has full control over both return values. If the adapter is not a simple immutable contract (e.g. if it is upgradeable, or if it reads from mutable storage), a coordinated two-step manipulation is possible:

1. `getLatestPrice()` returns a plausible price with `stale=false`.
2. `latestRoundData()` returns `updatedAt = block.timestamp` (a future-clamped timestamp that becomes `block.timestamp` after the `> block.timestamp` clamp on line 84).

With `updatedAt = block.timestamp`, `effectiveTime = block.timestamp` is the maximum possible, and this feed will always win the freshest-feed race against any real Chainlink feed that has any non-zero age.

Note: The `_validateFeedSupportInternal` check at registration time calls `supportsInterface(IPriceFeedCustom)` and verifies the type. However, it does not prevent a *registered* Custom adapter from being upgraded post-registration (e.g. if the adapter itself is a proxy) or from returning time-varying data.

## Root Cause

`PriceFeedLib.sol:51-67` — two separate external calls to the same Custom feed without atomicity. The price accepted by the first call is used with the timestamp returned by the second call, and there is no check that the two calls agree on whether the price is valid.

## Impact

Low in practice for the current adapter set (all current Custom adapters are immutable). However:
- If a future Custom adapter is accidentally made upgradeable (e.g. by inheriting from OZ's `UUPSUpgradeable` without removing admin functions), the described manipulation becomes exploitable.
- A Custom adapter that reads from mutable storage (e.g. a cached rate that is updated between transactions) could return inconsistent `updatedAt` values across the two calls in edge conditions.

The impact is that a feed can win the freshest-feed race without actually being the freshest, overriding a healthier Chainlink feed.

## Mitigation

Combine both calls into one: add a combined `getLatestPriceAndRoundData()` method to `IPriceFeedCustom` that atomically returns `(price, stale, updatedAt)` in a single call. This eliminates the two-call window. For backward compatibility, the existing interface can be preserved and `selectFeed` can call the combined method, falling back to two calls only for adapters that do not implement it.

Alternatively, validate that the `answer` returned by `latestRoundData()` equals the `price` returned by `getLatestPrice()`. A mismatch should cause the feed to be skipped.
