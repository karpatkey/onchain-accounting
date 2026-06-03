# L-02 — CrossRate and all dual-feed adapters: round metadata (roundId, startedAt, answeredInRound) sourced from the wrong oracle

## Summary

In `CrossRate_Price.sol` and all six L2 dual-feed adapters (`wstETH_L2`, `cbETH_L2`, `rsETH_L2`, `weETH_L2`, `syrupUSDC_L2`, `LDO`), the `latestRoundData()` response tuple `(roundId, startedAt, answeredInRound)` always originates from whichever oracle had the **older** `updatedAt` (i.e. the minimum-`updatedAt` oracle selected to represent staleness). The `answeredInRound` field from this oracle has no relationship to the `roundId` of the other oracle, making the cross-feed tuple semantically inconsistent. External integrators that validate `answeredInRound >= roundId` (a legacy Chainlink V2 pattern) will receive a mismatched pair.

## Vulnerability Detail

All dual-feed `_compute()` functions apply the same pattern:

```solidity
// CrossRate_Price.sol  lines 61-65
if (u1 <= u2) {
    (roundId, startedAt, updatedAt, answeredInRound) = (r1, s1, u1, ar1);
} else {
    (roundId, startedAt, updatedAt, answeredInRound) = (r2, s2, u2, ar2);
}
```

The intent is to expose the worst-case (least-fresh) oracle metadata, per the `IPriceFeedCustom.latestRoundData()` NatSpec. This correctly conveys the `updatedAt` of the staler feed for observability. However, `roundId` and `answeredInRound` are coherent only within a single feed's round lifecycle. Returning `roundId` from feed A alongside `answeredInRound` from feed A while the price is computed from feed A × feed B creates a tuple where neither `roundId` nor `answeredInRound` bears any relationship to the other feed's round state.

The risk is limited because:
1. `PriceFeedLib.selectFeed()` ignores `roundId` and `answeredInRound` entirely; only `updatedAt` participates in feed selection.
2. Modern Chainlink V3 OCR aggregators always set `answeredInRound == roundId`, making the legacy `answeredInRound >= roundId` check vacuous.

The residual risk is that off-system tooling (monitoring dashboards, alerting infrastructure, integrators consuming `latestRoundData()` directly) may misinterpret the tuple.

## Root Cause

- `CrossRate_Price.sol` lines 61–65
- `wstETH_L2_Price.sol` lines 86–90
- `cbETH_L2_Price.sol` lines 54–58
- `rsETH_L2_Price.sol` lines 54–58
- `weETH_L2_Price.sol` lines 54–58
- `syrupUSDC_L2_Price.sol` lines 54–58
- `LDO_Price.sol` lines 92–96

## Impact

External consumers of `latestRoundData()` that inspect `roundId` / `answeredInRound` (e.g., those applying the Chainlink V2 staleness pattern `require(answeredInRound >= roundId)`) will receive a pair that crosses oracle boundaries and may trigger false-positive staleness reverts or silently pass because `answeredInRound == roundId` on V3 aggregators. No impact on the on-chain `NAVCalculator` read path, which does not use these fields.

## Attack Scenario / PoC

1. A third-party protocol integrates with `CrossRate_PriceAdapter.latestRoundData()` and applies the legacy check: `require(answeredInRound >= roundId, "Stale")`.
2. At a given block: feed 1 (X/USD) is at round 500, feed 2 (Y/X) is at round 120.
3. `updatedAt(feed2) < updatedAt(feed1)`, so the adapter returns `(roundId=120, answeredInRound=120)`.
4. The check passes vacuously. The price, however, has been computed from both feeds, so neither round number describes the composite price.
5. If the third-party instead relied on the `roundId` to index historical prices on feed 1, it would retrieve the wrong round.

## Preconditions

- A consumer calls `latestRoundData()` directly on a dual-feed adapter and uses `roundId` or `answeredInRound` semantically (not just for pass/fail staleness).

## Mitigation

Consider returning `(0, answer, 0, updatedAt, 0)` from `latestRoundData()` for composite adapters, zeroing out the fields that are semantically undefined for cross-feed tuples. This is already done by `ETHPlus_PriceOracle` (which has no round concept) and is explicitly permitted by the `IPriceFeedCustom` NatSpec. Alternatively, document clearly in NatSpec that `roundId` and `answeredInRound` are sourced from the staler oracle and bear no relation to the computed price.
