# L-01: Rate-only feeds return sentinel updatedAt=block.timestamp-1 — may dominate feed selection

## Summary

Multiple feeds (ankrETH, ETHx, ezETH L1, NXM, osToken, rETH, rsETH, wstETH) back their `latestRoundData()` solely with the Chainlink base feed's `updatedAt`. They return `answer=0` when stale and a real price when fresh, but return `updatedAt` as the Chainlink base feed timestamp (not a rate-side timestamp). In PriceFeedLib, when `latestRoundData()` returns `updatedAt=0` the library applies the sentinel `block.timestamp - 1`. Because rate-only feeds never expose a rate-side timestamp, the upstream feed selection logic sees these as "as fresh as possible" when the Chainlink base is fresh, which is the intended and correct behavior — but there is a subtle edge: when these feeds are stale (return `answer=0`), `updatedAt` still reflects the Chainlink base's real value rather than 0, so the sentinel path in PriceFeedLib is NOT triggered and the stale result correctly uses the real Chainlink base `updatedAt`. This is consistent and not a bug per se, but the sentinel path for rate-only feeds is unreachable by design, making the sentinel code in PriceFeedLib potentially misleading.

## Vulnerability Detail

### Root Cause

`PriceFeedLib` lines 104-110 apply a sentinel `block.timestamp - 1` when `lrdUpdatedAt == 0` (i.e., `latestRoundData()` reverts or returns 0). For rate-only custom feeds backed by `BaseCustomPriceFeed`, `latestRoundData()` always returns the Chainlink base feed's real `updatedAt`, which is positive when the base feed has ever been called. The sentinel is effectively dead code for this class of feed.

For the consumer context this is benign: the Chainlink base freshness gate inside the feed already gates on the rate being non-zero. The PriceFeedLib then re-applies its own heartbeat gate (`cfg.chainlinkHeartbeat`) on the `updatedAt` it receives. Since the `updatedAt` reflects the Chainlink base feed, and the feed already applied the same heartbeat internally, the two gates produce the same result — no double-counting of the stale condition.

### Code Location

- File: `src/prices/PriceFeedLib.sol`
- Lines: 104-110

```solidity
// @audit sentinel path: lrdUpdatedAt==0 → block.timestamp-1. For BaseCustomPriceFeed descendants,
//        latestRoundData() always returns the Chainlink base's updatedAt (never 0), so this path is
//        unreachable for that class. The rate-side freshness is not exposed to PriceFeedLib at all.
updatedAt = lrdUpdatedAt == 0 ? (block.timestamp > 0 ? block.timestamp - 1 : 0) : lrdUpdatedAt;
```

## Impact

- **Likelihood**: N/A (informational gap, not an exploitable condition).
- **Impact**: Low — the double-gate means PriceFeedLib will apply the configured `chainlinkHeartbeat` against the Chainlink base `updatedAt`. If the configured heartbeat in PriceFeedLib differs from `BASE_HEARTBEAT` in the custom feed, the outer gate may be looser or stricter than intended. A stricter outer gate causes false-positives (unnecessarily skipping a fresh feed). A looser outer gate has no effect because the inner feed gate already rejected it.
- **Severity**: LOW

## Attack Scenario

Not applicable — no funds are at risk from this informational gap.

## Recommended Mitigation

1. Document explicitly that rate-only feeds expose only the Chainlink base `updatedAt` and that PriceFeedLib's `chainlinkHeartbeat` for these assets should match the custom feed's `BASE_HEARTBEAT` to avoid inconsistency.
2. Consider having `BaseCustomPriceFeed.latestRoundData()` return `updatedAt = 0` when stale (currently it returns the real Chainlink `updatedAt` even when stale), so PriceFeedLib's sentinel path applies and makes the stale condition explicit to outer consumers reading `latestRoundData()` directly.
