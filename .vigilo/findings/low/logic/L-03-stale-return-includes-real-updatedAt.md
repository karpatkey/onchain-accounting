# L-03 — All dual-feed and ETHx adapters: latestRoundData() returns a real updatedAt alongside answer=0 when stale

## Summary

When `_compute()` determines the price is stale, every affected adapter sets `answer = int256(0)` in `latestRoundData()` but returns the **real** oracle `updatedAt` timestamp. An external consumer that does not check the `answer` field for zero — and instead treats a non-zero `updatedAt` as a freshness signal — will misinterpret a stale feed as healthy.

## Vulnerability Detail

The `latestRoundData()` implementations follow this pattern across all adapters:

```solidity
// CrossRate_CustomPriceFeed.sol  lines 104-105
(price, stale, roundId, startedAt, updatedAt, answeredInRound) = _compute();
answer = stale ? int256(0) : int256(price);
```

When stale, `answer = 0` and `updatedAt = min(u1, u2)` (a real, possibly recent timestamp). A caller performing:

```solidity
(, int256 answer, , uint256 updatedAt, ) = adapter.latestRoundData();
require(block.timestamp - updatedAt < HEARTBEAT, "stale");
// answer is 0 — not checked
```

…will pass the heartbeat check (because `updatedAt` is a genuine oracle timestamp) while receiving a zero answer and treating it as a valid price. This is a subtle deviation from the Chainlink convention where a feed that is stale typically also has an outdated `updatedAt`.

The `ICustomPriceFeed` NatSpec explicitly states this is for observability only and that staleness is handled internally. The primary consumer (`PriceFeedLib.selectFeed`) is safe because it checks `getLatestPrice()` first, and discards the feed on `stale = true` before calling `latestRoundData()`. However, external integrators consuming `latestRoundData()` directly may not apply the same guard.

Affected adapters:
- `CrossRate_CustomPriceFeed.sol`
- `ETHx_CustomPriceFeed.sol`
- `LDO_CustomPriceFeed.sol`
- `wstETH_L2_CustomPriceFeed.sol`
- `cbETH_L2_CustomPriceFeed.sol`
- `rsETH_L2_CustomPriceFeed.sol`
- `weETH_L2_CustomPriceFeed.sol`
- `syrupUSDC_L2_CustomPriceFeed.sol`
- `ezETH_L2_CustomPriceFeed.sol`

## Root Cause

The `latestRoundData()` in each adapter sets `answer = 0` on staleness but preserves the real `updatedAt` from the underlying Chainlink oracle. This is documented behaviour per `ICustomPriceFeed` but creates a semantic mismatch with the AggregatorV3Interface convention.

Example: `CrossRate_CustomPriceFeed.sol` lines 102-106.

## Impact

An external integrator calling `latestRoundData()` directly on these adapters and checking only `updatedAt` for freshness (the standard Chainlink pattern) will not detect staleness. They will receive `answer = 0` and potentially compute a zero-valued position or divide by zero, depending on how they use the answer.

Risk to the internal `NAVCalculator` is **nil** — `PriceFeedLib.selectFeed` calls `getLatestPrice()` first and respects the `stale` boolean. The risk is confined to external integrators.

## Attack Scenario / PoC

1. Both feeds in `CrossRate_CustomPriceFeed.sol` cross their heartbeat threshold — `getLatestPrice()` returns `stale = true`.
2. `latestRoundData()` returns `(roundId, 0, startedAt, updatedAt_real, answeredInRound)` where `updatedAt_real` is, say, 23 h 59 m old (just barely crossed the 24 h heartbeat).
3. An external integrator checks `block.timestamp - updatedAt < 86400` → passes (23 h 59 m < 24 h).
4. Integrator uses `answer = 0` as price, potentially creating a zero-value position, division-by-zero, or undetected mis-pricing.

## Preconditions

- An external integrator (not `NAVCalculator`) consumes `latestRoundData()` from these adapters without also calling `getLatestPrice()`.
- The price is stale but `updatedAt` is still within the integrator's heartbeat window.

## Mitigation

Two options:

**Option A (Preferred):** When stale, return `updatedAt = 0` to force any `block.timestamp - updatedAt` check to overflow and revert (under Solidity overflow semantics) or produce a very large number that exceeds any reasonable heartbeat:

```solidity
answer = stale ? int256(0) : int256(price);
if (stale) updatedAt = 0;  // force heartbeat checks to fail
```

**Option B:** Strengthen the NatSpec on `latestRoundData()` in `ICustomPriceFeed` to explicitly warn that `updatedAt` may be fresh even when `answer = 0`, and that `getLatestPrice()` must be called for authoritative staleness.

Note: Option A changes external observability (monitoring tools that read `updatedAt` for debugging would see 0 when stale, losing the underlying oracle timestamp). Option B is documentation-only but provides no runtime protection.
