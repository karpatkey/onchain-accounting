# M-03: ankrETH — ratio() has no freshness guard (corroborates prior M-2)

## Summary

`ankrETH_CustomPriceFeed._compute()` calls `IankrETH(ANKR_ETH).ratio()` to obtain the ankrETH-per-ETH exchange rate. This ratio is a storage variable updated by Ankr's off-chain rebase keeper. No timestamp is associated with it on-chain; the feed applies only the ETH/USD Chainlink heartbeat. If Ankr's keeper lags or is paused, the stale ratio is used without detection.

## Vulnerability Detail

### Root Cause

`ratio()` is a push-updated storage value managed by Ankr's operator. Unlike Chainlink feeds, it carries no `updatedAt` field and no `latestRoundData`-style interface. The contract does not expose a `lastUpdateTimestamp()`. Because there is no age check on the ratio, a multi-day-old ratio propagates silently once the ETH/USD gate passes.

### Code Location

- File: `src/prices/protocols/ankrETH_CustomPriceFeed.sol`
- Function: `_compute()`
- Lines: 65-68

```solidity
// @audit ratio() is keeper-updated with no on-chain timestamp; no staleness check applied
uint256 ratio = IankrETH(ANKR_ETH).ratio();
if (ratio == 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
price = uint256(ethToUsdPrice).mulDiv(1e18, ratio, Math.Rounding.Floor);
```

`latestRoundData()` returns the ETH/USD Chainlink tuple as `updatedAt`, which reflects only the ETH/USD oracle freshness — not the ratio freshness.

## Impact

- **Likelihood**: Low — Ankr's rebase updates are historically routine; prolonged keeper outage is a tail event.
- **Impact**: Medium — in a period of active staking rewards accumulation, a stale ratio understates the ankrETH value relative to ETH without raising a stale flag to NAVCalculator.
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions

- Ankr's rebase keeper stops updating `ratio()` for an extended period (e.g. multi-day incident).
- ETH/USD Chainlink feed remains fresh.

### Attack Steps

1. `ratio()` reflects a value from N days ago (smaller denominator = smaller ETH-per-ankrETH = understated price).
2. `getLatestPrice()` is called.
3. ETH/USD staleness gate passes.
4. `price = ETH/USD * 1e18 / ratio` is computed with the stale ratio.
5. Feed returns `stale=false` with a price below fair value.
6. NAVCalculator under-reports USD value of ankrETH holdings.

### Expected Impact

- Persistent under-reporting of ankrETH NAV for the duration of the keeper outage. The magnitude is bounded by reward accumulation rate (roughly 3–5% APR / 365 = ~0.01% per day), so multi-day lag produces small but non-zero errors.

## Recommended Mitigation

Ankr's `ankrETH` contract exposes a `ratio()` but historically has not published a `lastRebaseTimestamp`. If a companion timestamp is available (e.g. via event parsing or a governance-announced keeper contract), add a secondary heartbeat check. Otherwise, accept and document this as an architectural constraint of the Ankr protocol and monitor the keeper off-chain.
