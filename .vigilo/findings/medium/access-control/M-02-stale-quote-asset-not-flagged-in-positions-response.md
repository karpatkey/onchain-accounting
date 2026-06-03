# M-02: Stale Quote-Asset Price Falls Back to USD Silently in `getAccountPositions`

## Summary

When `getAccountPositions` or `getAccountPositionsForAsset` is called with a non-zero `quoteAsset` whose price feed is stale, `_priceConversion` silently falls back to computing values in USD instead of the requested quote currency. The returned `Position[]` array has no flag to indicate this substitution. Only `getAccountNav` exposes `nav.quoteAssetStale`; positions callers have no equivalent signal.

## Vulnerability Detail

**Safe guard in `_priceConversion`:**

```solidity
// NAVCalculator.sol:929
if (quotePrice <= 0) {
    return usdValue; // USD (NAV_DECIMALS)
}
```

When `_latestPrice(quoteAsset)` returns `(0, decimals, stale=true)`, `quoteInfo.price = 0`. The guard fires and returns `usdValue` — but the `Position.value` field carries no information distinguishing "value in requested quote" from "value in USD fallback".

**NAV path exposes the flag; positions path does not:**

```solidity
// NAVCalculator.sol:265 — getAccountNav sets the flag
nav.quoteAssetStale = quoteInfo.stale;
```

```solidity
// NAVCalculator.sol:380-422 — getAccountPositions/_getAccountPositionsInternal
// quoteInfo.stale is computed but never surfaced in the Position[] return value
```

The `Position` struct (defined in `INAVCalculator.sol`) contains `stale bool` to flag per-asset price staleness, but there is no analogous field for quote-asset staleness. A caller requesting ETH-denominated positions during an ETH price outage receives USD-denominated values with the same `Position.quoteAsset` struct pointing to ETH — a contradictory combination.

## Root Cause

**File:** `src/nav/NAVCalculator.sol`, function `_getAccountPositionsInternal` (~line 389)

`quoteInfo.stale` is fetched but discarded. It is not propagated into the `Position[]` return or into a separate out-parameter.

## Impact

Off-chain consumers (dashboards, liquidation bots, portfolio managers) that:
- Call `getAccountPositions(account, quoteAsset)` with a non-USD quote asset
- Trust `Position.value` as being denominated in `quoteAsset`

…will silently receive USD-denominated values during quote-asset feed outages. Depending on the magnitude difference between the quote asset and USD (e.g., 1 BTC ≈ 100,000 USD), this can produce order-of-magnitude errors in displayed or computed portfolio values.

No on-chain funds are directly at risk (NAVCalculator is read-only), but incorrect values propagated to downstream systems (liquidation triggers, margin checks, governance votes based on NAV thresholds) could cause material financial harm.

## Attack Scenario

**Preconditions:**
- A DeFi application uses `getAccountPositions(account, WBTC)` to report BTC-denominated portfolio values.
- The WBTC/USD price feed becomes stale (heartbeat exceeded, sequencer outage, etc.).

**Sequence:**
1. WBTC feed goes stale → `_latestPrice(WBTC)` returns `(0, 8, true)`.
2. `quoteInfo.price = 0`, `quoteInfo.stale = true`.
3. `_priceConversion` takes the `quotePrice <= 0` branch → returns USD value.
4. `Position.value` is set to `usdValue` (e.g., 50,000 for a 0.5 ETH position).
5. `Position.quoteAsset` still shows WBTC with 8 decimals.
6. Consumer interprets 50,000 as BTC — which is 50,000 BTC (~$5 billion), not $50,000.
7. Consumer's downstream logic acts on this inflated value.

## Preconditions

- Caller uses a non-zero `quoteAsset`.
- That quote asset's price feed is stale at query time.

## Mitigation

**Option A (minimal):** Add a `quoteAssetStale bool` field to the `Position` struct and populate it from `quoteInfo.stale` in `_enrichPositionWithPricing`.

**Option B (no struct change):** Return a `bool quoteAssetStale` as a second return value from `getAccountPositions` and `getAccountPositionsForAsset`, mirroring the `getAccountNav` pattern.

**Option C (defensive):** When `quoteInfo.stale == true` and `quoteAsset != address(0)`, either revert with a descriptive error (`QuoteAssetStale(quoteAsset)`) or override `quoteAsset` to `address(0)` (USD) and document the fallback explicitly, ensuring callers always know which currency the values are in.

Option C is the most defensive and eliminates the ambiguity entirely, at the cost of a behaviour change for callers who expect graceful degradation.
