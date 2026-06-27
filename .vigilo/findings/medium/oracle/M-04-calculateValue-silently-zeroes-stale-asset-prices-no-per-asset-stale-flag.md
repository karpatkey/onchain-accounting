# M-04: `calculateValue` Silently Zeroes Stale Asset Prices Without Surfacing Per-Asset Staleness

## Summary

`PriceFeedLib.calculateValue` (and the `NAVCalculator.calculateValue` wrapper) returns only `quoteAssetStale` to callers. When an individual asset's price feed is stale, `_selectFeedCore` returns `price = 0` and `stale = true`, but the `stale` flag is discarded inside `calculateValue`. The asset contributes `0` to the total value sum without any warning. Callers receive a numerically lower `value` than the true portfolio value with no indication that a specific asset's price was unavailable.

## Vulnerability Detail

### Root Cause

- File: `src/prices/PriceFeedLib.sol`
- Function: `calculateValue()`
- Lines: 504–525

```solidity
for (uint256 i = 0; i < assetAddresses.length; i++) {
    uint256 amount = amounts[i];
    if (amount == 0) continue;

    address asset = assetAddresses[i];
    if (assetIndex[asset] == 0) revert AssetNotFound();
    uint8 assetDecimals = _getRegisteredAsset(assetIndex, registeredAssets, asset).decimals;
    // @audit stale return value is fully discarded here
    (int256 usdRate, uint8 usdRateDecimals,,,) = _selectFeedCore(priceOracles, asset);
    value += _priceConversion(
        amount,
        false,
        assetDecimals,
        usdRate,          // usdRate == 0 when stale
        usdRateDecimals,
        quoteInfo.price,
        quoteInfo.priceDecimals,
        quoteInfo.assetDecimals
    );
}
```

When `_selectFeedCore` returns `(price=0, stale=true)`:
- `usdRate = 0` is passed into `_priceConversion`.
- `_priceConversion` computes `(signedAmount * 0) / denom1 = 0`.
- Zero is silently added to `value`.

The function signature `returns (int256 value, bool quoteAssetStale)` offers no mechanism to surface that one or more input assets had stale feeds. Compare with `computeNav`, which populates `nav.stalePriceAssets` for exactly this purpose.

### Contrast with `computeNav`

`computeNav` builds a `PriceFeedCache` for each asset and then builds `nav.stalePriceAssets` from it:
```solidity
nav.stalePriceAssets = _buildStaleAssets(assetIndex, registeredAssets, priceFeeds);
```
This surface exists in the NAV path but is absent from `calculateValue`.

## Impact

- **Likelihood**: Medium — `calculateValue` is a public view function intended for off-chain use and potentially for on-chain consumers.
- **Impact**: Medium — If a caller uses `calculateValue` to decide a risk threshold, rebalance trigger, or collateral adequacy check, a stale feed for one asset will make the position appear worth less (or zero) without the caller being aware. Decisions based on this silently-reduced value may be incorrect.
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions
- Asset X (e.g. rsETH) has a single registered price feed.
- The rsETH feed becomes stale (e.g. the underlying Kelp rate provider stops updating and the heartbeat expires).
- A caller (on-chain contract or off-chain script) uses `calculateValue([rsETH, USDC], [bigAmount, smallAmount], USD)` to check whether the portfolio meets a minimum NAV threshold.

### Attack Steps
1. rsETH feed expires its heartbeat; `_selectFeedCore` returns `(0, stale=true)` for rsETH.
2. `calculateValue` is called. rsETH contributes `0` to `value`. USDC contributes its correct value.
3. The returned `value` reflects only the USDC portion; `quoteAssetStale = false` (USDC feed is fresh).
4. Caller sees a healthy `quoteAssetStale = false` and a `value` that is far below the true portfolio value.
5. If the caller gates on `value >= MIN_THRESHOLD`, it incorrectly treats the portfolio as below the threshold and takes the wrong action (e.g. forced rebalance, false alert, or missed liquidation avoidance).

### Expected Impact
- Silently incorrect value returned for portfolios containing assets with stale feeds.
- Downstream consumers making decisions based on `calculateValue` may act on materially wrong data without any staleness signal.

## Recommended Mitigation

Extend the return signature to include a staleness array analogous to `nav.stalePriceAssets`:

```solidity
function calculateValue(
    // ... existing params
) external view returns (int256 value, bool quoteAssetStale, address[] memory staleAssets) {
    // ...
    address[] memory staleTemp = new address[](assetAddresses.length);
    uint256 staleCount;
    for (uint256 i = 0; i < assetAddresses.length; i++) {
        // ...
        (int256 usdRate, uint8 usdRateDecimals, bool assetStale,,) = _selectFeedCore(priceOracles, asset);
        if (assetStale) {
            staleTemp[staleCount++] = asset;
            // value contribution is 0; caller knows why
        }
        value += _priceConversion(...);
    }
    staleAssets = ArrayLib.copySliceAddress(staleTemp, staleCount);
}
```

Alternatively, add a separate `calculateValueWithStaleness` variant and keep the existing signature unchanged for backward compatibility.
