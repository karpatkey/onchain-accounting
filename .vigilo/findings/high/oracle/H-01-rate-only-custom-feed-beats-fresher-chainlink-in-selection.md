# H-01 — Rate-only Custom feeds always beat fresher Chainlink feeds in `selectFeed`

## Summary

`PriceFeedLib.selectFeed` assigns `updatedAt = block.timestamp - 1` to any Custom feed whose `latestRoundData()` returns `updatedAt == 0`. The intent (documented in `IPrices.sol`) is that such feeds should *yield* to feeds with a real push timestamp. The implementation does the opposite: `block.timestamp - 1` beats every real Chainlink feed updated more than one second ago, so the rate-only Custom adapter always wins the "freshest-wins" race regardless of how recent the competing Chainlink round is.

## Vulnerability Detail

`PriceFeedLib.selectFeed` (line 67):

```solidity
updatedAt = lrdUpdatedAt == 0 ? (block.timestamp > 0 ? block.timestamp - 1 : 0) : lrdUpdatedAt;
```

The winner is chosen by the largest `effectiveTime` (line 90):

```solidity
if (effectiveTime > bestTime) { ... winnerIdx = i; }
```

Any Chainlink feed with a legitimate `updatedAt` older than one second (i.e. virtually always) produces `effectiveTime = block.timestamp - N` where `N >= 1`. A Custom rate-only feed returning `lrdUpdatedAt == 0` gets `effectiveTime = block.timestamp - 1`, which is strictly greater than `block.timestamp - N` for any `N > 1`. Therefore the Custom feed wins.

`IPrices.sol` line 23–24 explicitly documents the intended semantics:

> "updatedAt==0 is treated as block.timestamp-1 so rate-only feeds participate **but yield to** any feed with a real push timestamp"

The code contradicts this intent.

## Root Cause

`PriceFeedLib.sol:67` — the `block.timestamp - 1` sentinel places rate-only Custom feeds above all real Chainlink/Redstone/API3 feeds in the `effectiveTime` ordering rather than below them.

## Impact

When an asset has both a rate-only Custom adapter and a Chainlink/Redstone feed registered, the Custom adapter unconditionally wins the selection race. If the Custom adapter's underlying rate source (e.g. a protocol's internal cached value) becomes stale or manipulated while the Chainlink feed remains healthy, the system will report the Custom adapter's price and discard the healthy Chainlink price. This undermines the redundancy guarantee of the multi-feed design and can propagate a stale or manipulated rate-based price undetected.

Adapters affected (those that return `updatedAt == 0` from `latestRoundData()`, i.e. rate-only feeds where the rate source carries no on-chain timestamp): none of the current adapters in scope return `0` from `latestRoundData()` — they all forward the Chainlink `updatedAt`. However, the documented contract for `ICustomPriceFeed.latestRoundData()` explicitly allows returning `(0,0,0,0,0)` for feeds with no oracle dependency, and the `PriceFeedLib` is designed to handle that case. Any future Custom adapter of this type will silently win against all Chainlink feeds.

## Attack Scenario

1. Protocol registers two feeds for asset X: (a) Chainlink aggregator updated every hour, (b) Custom rate-only adapter returning `lrdUpdatedAt = 0`.
2. The rate-only adapter's underlying on-chain rate is manipulated (e.g. by a flash-loan inflating TVL/totalSupply, or by a compromised protocol contract).
3. `selectFeed` is called. The Custom adapter passes the `getLatestPrice()` check, then `latestRoundData()` returns `lrdUpdatedAt = 0`.
4. `updatedAt` is set to `block.timestamp - 1`. The Chainlink feed (updated 5 minutes ago) has `effectiveTime = block.timestamp - 300`.
5. `block.timestamp - 1 > block.timestamp - 300` → Custom adapter wins.
6. NAVCalculator prices asset X at the manipulated Custom rate, not the Chainlink price.

## Preconditions

- An asset must have both a rate-only Custom feed (returning `lrdUpdatedAt == 0`) and a Chainlink-type feed registered simultaneously.
- The rate-only Custom feed's price source must be manipulable or must become stale independently.

## Mitigation

Reverse the sentinel so rate-only feeds yield to any real push timestamp. Replace `block.timestamp - 1` with `0` in the fallback:

```solidity
// updatedAt = lrdUpdatedAt == 0 ? 0 : lrdUpdatedAt;
updatedAt = lrdUpdatedAt;   // if lrdUpdatedAt is 0, effectiveTime = 0, losing to any real feed
```

With `effectiveTime = 0`, the rate-only feed will only win if no other feed has any real timestamp, preserving the "yield" semantics from the documentation.
