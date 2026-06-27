# M-03: Missing `answeredInRound >= roundId` Check Allows Incomplete Chainlink Round to Pass Staleness Gate

## Summary

`PriceFeedLib._selectFeedCore` discards the `answeredInRound` return value from `AggregatorV3Interface.latestRoundData()` and never verifies that `answeredInRound >= roundId`. When Chainlink starts a new aggregation round before it is complete, `latestRoundData()` may return the *previous* completed round's answer with an `updatedAt` from that old round while `roundId` has already been incremented. The staleness gate (`block.timestamp - updatedAt >= heartbeat`) uses the old round's timestamp, which can still be within the heartbeat window, so the stale intermediate price passes as fresh.

## Vulnerability Detail

### Root Cause

- File: `src/prices/PriceFeedLib.sol`
- Function: `_selectFeedCore()`
- Lines: 112–129

```solidity
// @audit answeredInRound return value is silently discarded
try AggregatorV3Interface(cfg.priceFeed).latestRoundData() returns (
    uint80, int256 a, uint256, uint256 u, uint80
//   ^^^^                                  ^^^^ answeredInRound ignored
) {
    answer = a;
    lrdUpdatedAt = u;
} catch {
    continue;
}
if (answer <= 0) continue;
rawPrice = answer;
// ...
uint256 effectiveTime = updatedAt > block.timestamp ? block.timestamp : updatedAt;
if (block.timestamp - effectiveTime >= cfg.chainlinkHeartbeat) continue; // @audit heartbeat check passes with old round's timestamp
```

The Chainlink protocol uses the following semantics:
- `roundId`: the ID of the latest round Chainlink is *trying* to complete.
- `answeredInRound`: the ID of the round in which the returned `answer` was actually computed.
- When `answeredInRound < roundId`, the aggregation for `roundId` has not yet been resolved and `answer` contains the price from `answeredInRound` — a previous round.
- `updatedAt` in this case reflects when `answeredInRound` was last updated, not when `roundId` was initiated.

If `updatedAt` from the previous completed round (`answeredInRound`) is still within the heartbeat window, the staleness gate passes and a price that is effectively *older than the current round* is accepted as valid.

### Registration-time check also lacks the guard

`_validateFeedSupportInternal` (line 920) checks:
```solidity
if (answer <= 0 || updatedAt == 0) revert IPrices.InvalidPriceOracle();
```
It does not check `answeredInRound >= roundId`, so a feed that is mid-round at registration time is accepted.

## Impact

- **Likelihood**: Low — Chainlink rounds are typically short-lived (seconds to minutes); the window where `answeredInRound < roundId` coincides with a fresh-looking `updatedAt` is narrow.
- **Impact**: Medium — A price from the last completed round is accepted as the "current" price during the new round's aggregation window. If the market moved significantly since the previous round completed (e.g. flash crash between two heartbeat cycles), the accepted price reflects the old level.
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions
- A registered Chainlink feed for an asset enters a new round (e.g. heartbeat just triggered a fresh aggregation).
- The new round has not yet been completed (not all nodes have submitted).
- The previous round's `updatedAt` is still within the heartbeat window.

### Attack Steps
1. `_selectFeedCore` is called for an asset (e.g. ETH/USD).
2. `latestRoundData()` returns: `roundId = N`, `answer = priceFromRoundN-1`, `updatedAt = timestampOfRoundN-1`, `answeredInRound = N-1`.
3. `answer > 0` — check passes.
4. `block.timestamp - updatedAt < heartbeat` — check passes (previous round was recent).
5. Feed is selected as fresh and valid; `answer` = price from round `N-1` is used.
6. NAV is computed from a price that does not reflect the most recently submitted oracle values.

### Expected Impact
- NAV is computed from a slightly stale price (from the previous Chainlink round) without any staleness flag being raised.
- In volatile market conditions where the price moved meaningfully between rounds, the NAV underestimates or overestimates portfolio value silently.

## Recommended Mitigation

Add the standard Chainlink round-completeness check in `_selectFeedCore`:

```solidity
try AggregatorV3Interface(cfg.priceFeed).latestRoundData() returns (
    uint80 roundId_, int256 a, uint256, uint256 u, uint80 answeredInRound_
) {
    // @audit-fix: skip incomplete rounds
    if (answeredInRound_ < roundId_) continue;
    answer = a;
    lrdUpdatedAt = u;
} catch {
    continue;
}
```

Apply the same guard in `_validateFeedSupportInternal` at registration time:
```solidity
(uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound_) =
    AggregatorV3Interface(priceFeed).latestRoundData();
if (answer <= 0 || updatedAt == 0) revert IPrices.InvalidPriceOracle();
if (answeredInRound_ < roundId_) revert IPrices.InvalidPriceOracle(); // incomplete round at registration
```
