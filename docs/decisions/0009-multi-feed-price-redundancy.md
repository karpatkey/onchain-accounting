# ADR 0009 — Multi-feed price redundancy

**Status:** Accepted  
**Date:** 2026-05-16

---

## Context

`Prices.sol` previously stored **one feed per asset**. If that single feed froze or returned a stale price, NAV reads degraded silently (`stale=true`, no fallback). Production assets increasingly have multiple viable price sources (Chainlink, Redstone Classic Push, API3 dAPIs), and registering only one creates unnecessary fragility.

---

## Decision

Allow **N price feeds per asset** (N ≥ 1). On every read, pick the **freshest non-stale feed** (freshest-wins selector). Only return `stale=true` when every registered feed has failed the staleness gate.

### Selection algorithm

```
for each cfg in _priceOracles[asset]:
    rawPrice, updatedAt = read(cfg)          // per-type dispatch below
    if rawPrice <= 0 or internal stale: skip
    effectiveTime = min(updatedAt, block.timestamp)   // clock-skew normalisation
    if block.timestamp - effectiveTime >= cfg.chainlinkHeartbeat: skip  // staleness gate (>= so boundary is stale)
    if effectiveTime > bestTime: update winner

if no winner: return (0, firstFeed.decimals, true)
else:         return (winner.price, winner.decimals, false)
```

**Per-type read:**

| `PriceType` | Read path |
|---|---|
| `Chainlink`, `Redstone` | `AggregatorV3Interface.latestRoundData()` — `answer` is price, `updatedAt` is freshness timestamp |
| `API3` | `AggregatorV3Interface.latestRoundData()` — `answer` is an 18-decimal dAPI value, divided by `1e10` to the canonical 8 decimals at read; `updatedAt` is freshness timestamp |
| `Custom` | `IPriceFeedCustom.getLatestPrice()` for `(price, internalStale)` gate; then `latestRoundData()` for `updatedAt` (a revert is caught and treated as no-timestamp). `updatedAt == 0` means "no trackable oracle" → treated as `block.timestamp - 1` |

### Invariant: cannot remove last feed

`_removePriceFeedAt` and `_removePriceFeed` revert with `CannotRemoveLastFeed` when only one feed remains. The MANAGER role can add feeds and remove any non-last feed. Full removal (`_removeAllPriceFeeds`) is only available via `unregisterAsset`.

### New provider types in `PriceType` enum

```solidity
Chainlink, Redstone, API3, Custom
```

Redstone and API3 both implement `AggregatorV3Interface`; Redstone shares Chainlink's read path verbatim, while API3 adds an 18→8 decimal rescale (see the per-type table above). The enum values exist for observability and admin-time validation.

### Storage change

`mapping(address => PriceFeedConfig) public priceOracles` → `mapping(address => PriceFeedConfig[]) internal _priceOracles`.

New view API: `getPriceFeedCount(asset)`, `getPriceFeedAt(asset, index)`, `getPriceFeeds(asset)`.

A 50-slot `__pricesGap` gap array was added to `Prices.sol` to close an upgrade-safety gap that existed before this PR (the contract had no gap).

---

## Rationale

### Why freshest-wins instead of median or quorum?

Freshest-wins is the simplest rule that achieves the main goal (any single feed freeze is silently recovered from). Median and quorum require ≥ 3 feeds; we cannot guarantee that for every asset in the short term, and they add significant read complexity.

### Accepted failure mode: timestamp fabrication

A malicious or misconfigured feed could report an `updatedAt` equal to `block.timestamp` on every call, systematically winning the freshest-wins race regardless of actual data freshness. In practice, adding such a feed requires the MANAGER role to be compromised — the same attacker could call `registerAsset` with an arbitrary oracle, so this is not a new attack surface. A deviation-cap sanity layer (reject any feed whose price deviates from the median by > X%) would close this, and is flagged for v2 if/when enough feeds are deployed per asset to make it tractable.

### Why `updatedAt == 0 → block.timestamp - 1` for Custom feeds?

Some on-chain rate-only adapters (e.g., pure DSR or exchange-rate feeds with no external oracle) have no meaningful "last update time" — the rate is a live storage slot that changes continuously. `latestRoundData()` on these returns `updatedAt = 0`. Treating `0` as literally zero would make the staleness gate reject the feed (`block.timestamp - 0 >= heartbeat` is almost always true). Treating it as `block.timestamp` would make it win every tie. `block.timestamp - 1` is a compromise: the feed participates, but yields to any feed with a real on-chain timestamp.

---

## Consequences

- Single-feed assets behave identically to the previous implementation.
- New feeds can be added per-asset without contract upgrades (MANAGER call).
- The `Prices.sol` storage layout changed; this is acceptable because the system is pre-launch (no live state to migrate).
- NAVCalculator's external API changes: `setPriceFeed` → `addPriceFeed`; `unsetPriceFeed` removed; `removePriceFeedAt` and `removePriceFeed` added.
- Existing custom adapters (`IPriceFeedCustom`) are unaffected as feed implementations; they are registered as one feed among N for their asset.
- `latestRoundData()` on custom feeds is now called by `Prices.sol` (for freshness comparison among multi-feed survivors). The documented convention of returning `updatedAt = min(constituent feed timestamps)` continues to be correct and is now load-bearing for freshness ranking.
- **EIP-170 (24 576-byte bytecode limit):** The added `_selectFeed` loop and feed-management functions pushed `NAVCalculator` over the limit. This is resolved by extracting the heavy logic into `src/prices/PriceFeedLib.sol` — a Solidity `library` with all functions marked `external`, compiled as a separate artifact and called via `DELEGATECALL`. The calling contract's inlined bytecode shrinks by ~1 800 bytes; `NAVCalculator` ends up at ~24 307 bytes (269 bytes under the limit) at `optimizer_runs = 200` with `via_ir = true`.
