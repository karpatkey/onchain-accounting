# H-01: `SafeCast.toInt256` Called Outside `try/catch` in `selectFeed` Enables Per-Token DoS

## Summary

In `PriceFeedLib.selectFeed`, after a Custom feed's `getLatestPrice()` succeeds (returning a non-stale, non-zero `uint256` price), the result is cast to `int256` via `SafeCast.toInt256` **outside** any `try/catch` block. If the custom feed returns a value exceeding `type(int256).max` (i.e., ≥ 2^255), the cast reverts unconditionally. Because the revert escapes the per-feed isolation, the entire `selectFeed` call reverts for that token, permanently bricking `latestPrice`, `getAccountNav`, `getAccountPositions`, and `calculateValue` for all users of that asset.

## Vulnerability Detail

The `selectFeed` loop processes each registered feed with per-feed `try/catch` protection:

```solidity
// PriceFeedLib.sol:51-56  — try/catch ends here
try ICustomPriceFeed(cfg.priceFeed).getLatestPrice() returns (uint256 p, bool s) {
    customPrice = p;
    internalStale = s;
} catch {
    continue;           // ← feed-level isolation stops here
}
if (internalStale || customPrice == 0) continue;
rawPrice = customPrice.toInt256();   // ← line 58: OUTSIDE try/catch
```

`SafeCast.toInt256(uint256 value)` reverts with `SafeCastOverflowedUintToInt` if `value > type(int256).max`. The `catch` block at lines 53-56 only catches errors thrown by `getLatestPrice()` itself. Any exception raised at line 58 propagates all the way out of `selectFeed`, through `_selectFeed`, and through `latestPrice` / `_latestPrice` — reverting the entire call.

## Root Cause

**File:** `src/prices/PriceFeedLib.sol`, **line 58**

```solidity
rawPrice = customPrice.toInt256();   // SafeCast.toInt256 not guarded by try/catch
```

The try/catch block closes at line 55 (`} catch { continue; }`). Line 58 executes in the loop body, outside any exception handler.

## Impact

**Any Custom feed whose `getLatestPrice()` returns a value ≥ 2^255** causes `selectFeed` to revert on every call. This impacts:

- `IPrices.latestPrice(asset)` — permanent revert
- `NAVCalculator.getAccountNav(account, quoteAsset)` if that asset is a position asset or is the quote asset
- `NAVCalculator.getAccountPositions` and `getAccountPositionsForAsset`
- `NAVCalculator.calculateValue` when the affected asset is in the list
- `NAVCalculator.healthCheck` (calls `_latestPrice` for every registered asset)

The DoS is permanent until a MANAGER either removes the offending feed or unregisters the asset entirely.

## Attack Scenario

**Preconditions:**
- MANAGER role (required to call `addPriceFeed`) registers a Custom price feed
- The feed is either malicious (returns `type(uint256).max` intentionally) or buggy (e.g., a math overflow in the feed contract returns an astronomically large value post-registration)

**Steps:**
1. A feed implementing `ICustomPriceFeed` is registered via `NAVCalculator.addPriceFeed(asset, feed, heartbeat, PriceType.Custom)`. At registration time `getLatestPrice()` is never called — only `decimals()` and `supportsInterface` are checked (see `addFeed` in `PriceFeedLib.sol:148-177`).
2. The feed begins returning `getLatestPrice() → (type(uint256).max, false)`.
3. In `selectFeed`, the try/catch succeeds (the external call itself does not revert), `customPrice = type(uint256).max`, `internalStale = false`.
4. Line 57 passes (`customPrice != 0`, not stale).
5. Line 58: `customPrice.toInt256()` reverts unconditionally.
6. `latestPrice(asset)` and all downstream NAV queries permanently revert.

No second MANAGER action is needed after step 2; the feed can be set up to return the large value after an owner-controlled delay.

## Preconditions

- MANAGER role controls the attacker's feed registration (trusted-but-compromised MANAGER, or a governance mistake).
- The problematic Custom feed is registered for the target asset.

## Mitigation

Extend the per-feed exception isolation to cover the cast. The simplest fix is to check the bound before casting:

```solidity
// Before: rawPrice = customPrice.toInt256();
// After:
if (customPrice > uint256(type(int256).max)) continue;
rawPrice = int256(customPrice);
```

Alternatively, restructure the block so that the cast occurs inside or immediately after a dedicated try/catch:

```solidity
try ICustomPriceFeed(cfg.priceFeed).getLatestPrice() returns (uint256 p, bool s) {
    if (s || p == 0 || p > uint256(type(int256).max)) continue;
    customPrice = p;
    internalStale = false;
} catch {
    continue;
}
rawPrice = int256(customPrice);
```

Either approach maintains feed-level isolation and prevents one misbehaving feed from bricking the whole token's price query.
