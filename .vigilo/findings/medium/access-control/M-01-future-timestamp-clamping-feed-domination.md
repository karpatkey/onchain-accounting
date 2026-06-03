# M-01: Post-Registration Future-Timestamp Clamping Grants a Feed Unconditional Priority

## Summary

`PriceFeedLib.selectFeed` clamps any `updatedAt > block.timestamp` to `block.timestamp` before applying the staleness gate and the best-freshness comparison. The registration validator in `_validateFeedSupportInternal` only checks that `updatedAt <= block.timestamp` **at the moment of registration**. After a feed is registered, if it starts returning a future `updatedAt` (via an owner-controlled setter or a protocol upgrade), the clamp silently makes that feed appear as fresh as the current block on every call — winning the freshness competition over all legitimate feeds and preventing any other feed from ever being selected.

## Vulnerability Detail

**Registration validation (point-in-time only):**

```solidity
// PriceFeedLib.sol:241-242
(,, uint256 startedAt, uint256 updatedAt,) = AggregatorV3Interface(priceFeed).latestRoundData();
if (updatedAt > block.timestamp || startedAt > block.timestamp) revert IPrices.InvalidPriceOracle();
```

This check is performed once during `addFeed`. No equivalent check occurs in `selectFeed`.

**Future-timestamp clamping in selectFeed:**

```solidity
// PriceFeedLib.sol:84
uint256 effectiveTime = updatedAt > block.timestamp ? block.timestamp : updatedAt;

// PriceFeedLib.sol:86
if (block.timestamp - effectiveTime >= cfg.chainlinkHeartbeat) continue;
```

If a feed returns `updatedAt = type(uint256).max`, then:
- `effectiveTime = block.timestamp` (clamped, no staleness possible since `block.timestamp - block.timestamp = 0`)
- `0 >= cfg.chainlinkHeartbeat` → always `false` → feed never skipped

**Winner selection:**

```solidity
// PriceFeedLib.sol:90
if (effectiveTime > bestTime) { ... winnerIdx = i; }
```

With `effectiveTime = block.timestamp`, the manipulated feed beats every other feed whose `updatedAt` is a genuine past timestamp (e.g., Chainlink's last push, which is typically seconds-to-hours in the past). The dominating feed wins every block, regardless of how many legitimate feeds are registered.

## Root Cause

**File:** `src/prices/PriceFeedLib.sol`, **lines 84 and 241**

The temporal validation is only a registration-time snapshot. There is no staleness check on the *direction* of `updatedAt` post-registration.

## Impact

A feed that returns future timestamps after registration:

1. **Always wins the freshness competition** — its price is selected every time regardless of how many other healthy feeds exist.
2. **Is never marked stale** — the `stale=true` path requires all feeds to fail the heartbeat gate; this feed always passes.
3. **Silently replaces legitimate prices** — consumers of `latestPrice` receive the manipulated price without any staleness signal.

For the multi-feed redundancy model to provide protection, the selection algorithm must not be bypassable by a single feed.

## Attack Scenario

**Preconditions:**
- MANAGER registers a Chainlink/Redstone/API3-type feed that initially reports a valid `updatedAt` (passing registration).
- The feed contract is upgradeable or has an owner-controlled `updatedAt` override (common for Redstone and some custom Chainlink-compatible adapters), OR the upstream oracle protocol itself has a bug that starts reporting future timestamps.

**Steps:**
1. `NAVCalculator.addPriceFeed(asset, feed, heartbeat, PriceType.Chainlink)` succeeds at time T₀ with `updatedAt = T₀`.
2. At some later time T₁, the feed starts returning `latestRoundData() → (..., answer, ..., T₁ + 1_000_000_000, ...)`.
3. From T₁ onward, every call to `selectFeed(asset)` selects this feed with `effectiveTime = block.timestamp`.
4. All legitimate co-registered feeds (even if fresher in wall-clock time) lose the comparison.
5. The attacker-controlled `answer` is the canonical price for the asset.

**Variant — accidental:** A Redstone-Classic push feed whose keeper script has a timestamp bug starts pushing future `updatedAt` values. No malicious actor required; the legitimate feed now inadvertently suppresses all backup feeds.

## Preconditions

- The feed contract is not perfectly immutable (has upgrade capability or an owner-settable timestamp), or an upstream oracle protocol returns future timestamps.
- MANAGER role is required to register the initial feed.

## Mitigation

**Option A (preferred):** Reject any `updatedAt > block.timestamp` inside `selectFeed`, consistent with the validation applied at registration:

```solidity
// PriceFeedLib.sol — in the non-Custom branch, replace lines 81-86 with:
updatedAt = lrdUpdatedAt;
if (updatedAt > block.timestamp) continue;  // reject future timestamps post-registration
uint256 effectiveTime = updatedAt;
if (block.timestamp - effectiveTime >= cfg.chainlinkHeartbeat) continue;
```

The same guard should apply in the Custom branch (for `lrdUpdatedAt` before line 67).

**Option B:** Keep the clamp but exclude future-timestamp feeds from the winner selection (treat `effectiveTime == block.timestamp` as a tie-break disadvantage, not an advantage).

**Note:** Option A is preferred because it makes the runtime behavior consistent with the registration-time invariant already enforced.
