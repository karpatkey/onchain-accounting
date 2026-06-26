# L-01 — Dual-feed adapters return `min(u1, u2)` as `updatedAt` but the `ICustomPriceFeed` spec says "worst case underlying oracle" — stale feed drives `updatedAt` while `answer` reflects both feeds

## Summary

`eETH_Price`, `weETH_Price`, and `LDO_Price` read two Chainlink feeds. Their `_compute()` assigns `updatedAt` to `min(u1, u2)` (the older of the two feed timestamps). The `ICustomPriceFeed` NatSpec says `latestRoundData()` should return the "worst-case" oracle data. When `stale=true` is returned because *one* feed is stale (but not the other), the returned `updatedAt` is already the stale feed's timestamp — which is consistent. However, when `stale=false` (both feeds fresh), `updatedAt = min(u1, u2)` is still the older feed's timestamp. This creates an asymmetry: the round metadata (`roundId`, `answeredInRound`) from the *older* feed is returned, but the price is computed from *both* feeds. If the two feeds are for different pairs (LDO/ETH and ETH/USD), the returned `roundId` and `answeredInRound` do not correspond to any single meaningful round.

## Vulnerability Detail

From `weETH_CustomPriceFeed.sol:86-89` (same logic in `eETH_CustomPriceFeed.sol` and `LDO_CustomPriceFeed.sol`):

```solidity
if (u1 <= u2) {
    (roundId, startedAt, updatedAt, answeredInRound) = (r1, s1, u1, ar1);
} else {
    (roundId, startedAt, updatedAt, answeredInRound) = (r2, s2, u2, ar2);
}
```

The metadata tuple is taken wholesale from whichever feed has the *older* `updatedAt`. This means `roundId` and `answeredInRound` refer to a round of the weETH/ETH feed even though `answer` in `latestRoundData()` reflects a computed product of weETH/ETH and ETH/USD. Any caller trying to advance `roundId` (e.g. audit trail reconstruction) will request a round from the wrong feed.

Additionally: the `ICustomPriceFeed` NatSpec (line 31) specifies "return the tuple with the lowest updatedAt (worst case) so callers see the most-stale input." For fresh prices this is honoured — `min(u1, u2)` is returned. But the `roundId` from the fresher feed is silently discarded, which is inconsistent with the intention of giving callers a coherent worst-case view.

## Root Cause

`eETH_CustomPriceFeed.sol:95-99`, `weETH_CustomPriceFeed.sol:86-90`, `LDO_CustomPriceFeed.sol:92-96` — the entire metadata tuple is taken from the feed with the older timestamp, which may not be the "worst case" in a semantically meaningful sense. The `answer` field is computed from both feeds but attributed to one feed's round.

## Impact

Low. This does not affect the primary `selectFeed` path in `PriceFeedLib`. The impact is limited to:
- External tooling consuming `latestRoundData()` for anomaly detection or audit purposes receiving mismatched `roundId`/`answer` combinations.
- Monitoring systems treating `roundId` as stable will observe unexpected jumps when the "lagging" feed alternates between the two.

No price value is miscalculated. `getLatestPrice()` returns correct values.

## Mitigation

Return a synthetic `updatedAt = min(u1, u2)` while zeroing out `roundId`, `startedAt`, and `answeredInRound` (use `0`) to signal that the metadata does not correspond to a single Chainlink round. This is consistent with the spirit of the `ICustomPriceFeed` spec:

```solidity
roundId = 0;
startedAt = 0;
updatedAt = u1 <= u2 ? u1 : u2;   // worst-case timestamp
answeredInRound = 0;
```

Alternatively, document in `ICustomPriceFeed` that multi-source adapters may return incoherent round metadata and callers must not rely on `roundId`.
