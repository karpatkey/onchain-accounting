# M-02 — All Custom adapters return `answer=0` with a real non-zero `updatedAt` in `latestRoundData()` when stale, misleading external callers

## Summary

Every Custom price adapter in scope follows this pattern in `latestRoundData()`:

```solidity
answer = stale ? int256(0) : int256(price);
```

When `_compute()` returns `stale=true` (e.g. the Chainlink heartbeat has elapsed), `answer` is set to `0` but `updatedAt` is set to the **last Chainlink `updatedAt`** from the failing round. This combination — `answer=0` with a non-zero `updatedAt` — is semantically ambiguous and misleads any external caller that uses `updatedAt` to assess freshness independently of `answer`.

## Vulnerability Detail

The `ICustomPriceFeed` NatSpec documents `latestRoundData()` as returning the "worst-case underlying oracle for external observability." External tooling and monitoring scripts commonly treat `updatedAt` as the primary freshness signal and `answer == 0` as a secondary validity flag. But no standard interpretation treats `answer == 0` + `updatedAt = recent_timestamp` as "price is stale" — that combination conventionally means "price feed just returned zero," which is a data anomaly, not a freshness signal.

Concrete example — `wstETH_CustomPriceFeed.sol` when Chainlink ETH/USD is exactly at the heartbeat boundary:

```solidity
// _compute returns:
//   price = 0
//   stale = true
//   updatedAt = (last Chainlink updatedAt, e.g. block.timestamp - heartbeat)
//
// latestRoundData() then returns:
//   answer = 0
//   updatedAt = block.timestamp - heartbeat   ← fresh-looking timestamp
```

An external monitoring system that checks `block.timestamp - updatedAt < heartbeat` would consider this round fresh (boundary condition: equal, not exceeding). An external system checking `answer > 0` would detect the anomaly. Systems checking *only* `updatedAt` — which is common for Chainlink-compatible consumers — would incorrectly conclude the feed is live and healthy with a zero price.

The same pattern exists across all 12 Custom adapters in scope.

For the dual-feed adapters (`eETH_Price`, `weETH_Price`, `LDO_Price`), the `updatedAt` returned is `min(u1, u2)`. If one feed is stale and the other is fresh, `updatedAt` = the stale feed's timestamp. The stale feed's `updatedAt` may itself be within heartbeat of a *different* configured heartbeat on the caller's side, compounding the confusion.

## Root Cause

`latestRoundData()` in each adapter — the `answer = stale ? 0 : int256(price)` encoding does not propagate the staleness signal through the `updatedAt` field. The NatSpec for `ICustomPriceFeed.latestRoundData()` does not specify how staleness should be encoded in `updatedAt`, leaving this ambiguous.

Affected files (all adapters expose this pattern):
- `ezETH_CustomPriceFeed.sol:89-93`
- `eETH_CustomPriceFeed.sol:137-146`
- `sDAI_CustomPriceFeed.sol:109-119` (mainnet)
- `sUSDS_CustomPriceFeed.sol:107-116`
- `sUSDe_CustomPriceFeed.sol:101-111`
- `syrupUSDC_CustomPriceFeed.sol:101-111`
- `sXDAI_CustomPriceFeed.sol:101-111`
- `wstETH_CustomPriceFeed.sol:92-102`
- `rETH_CustomPriceFeed.sol:92-102`
- `cbETH_CustomPriceFeed.sol:92-102`
- `weETH_CustomPriceFeed.sol:122-132`
- `rsETH_CustomPriceFeed.sol:102-112`
- `ETHx_CustomPriceFeed.sol:104-114`
- `LDO_CustomPriceFeed.sol:131-141`

## Impact

External monitoring scripts, dashboards, or integrators that consume `latestRoundData()` on these Custom adapters and rely solely on `updatedAt` for freshness — without also checking `answer > 0` — will not detect stale prices. This is a systemic observability failure across all Custom adapters. It does not affect the primary `selectFeed` path (which calls `getLatestPrice()` first), but does affect any secondary consumer of `latestRoundData()`.

If a future integration uses these adapters as drop-in replacements for standard Chainlink aggregators, the `answer=0` + non-zero `updatedAt` encoding will cause that integrator's staleness check to pass on a stale price.

## Attack Scenario

1. Attacker waits until a Custom adapter's Chainlink feed is exactly at (or past) its heartbeat boundary.
2. `getLatestPrice()` returns `(0, true)` — correctly stale.
3. A monitoring bot calls `latestRoundData()` and checks only `updatedAt < threshold`. It sees `updatedAt` = last Chainlink push, which may be within threshold. Bot reports feed as healthy.
4. No alert is raised. Operators are unaware the feed is stale.
5. If operators would have manually intervened (e.g. pause the system, switch to backup), they do not, because the monitoring bot reports false health.

## Preconditions

- An external system consumes `latestRoundData()` directly on a Custom adapter and uses `updatedAt` as the primary (or sole) freshness signal.

## Mitigation

When `stale == true`, zero out `updatedAt` as well (or set it to a canonical stale sentinel such as `1`), making the staleness unambiguous regardless of which field the caller checks:

```solidity
function latestRoundData() external view override returns (...) {
    (price, stale, roundId, startedAt, updatedAt, answeredInRound) = _compute();
    if (stale) {
        answer = 0;
        updatedAt = 0;   // ← unambiguous: no valid timestamp when stale
    } else {
        answer = int256(price);
    }
}
```

Update `ICustomPriceFeed` NatSpec to specify this convention explicitly so all future adapters follow it consistently.
