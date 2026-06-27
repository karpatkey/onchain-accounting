# M-02: ezETH L2 — keeper-relayed rate has no freshness guard

## Summary

`ezETH_L2_CustomPriceFeed` calls `xRenzoDeposit.getRate()` to obtain the ezETH/ETH cross-chain rate. This rate is pushed from L1 to L2 by Renzo's keeper. The feed checks only the ETH/USD Chainlink heartbeat; no timestamp or age check is applied to the rate returned by `getRate()`. If the keeper lags (e.g. during L2 sequencer downtime recovery), the feed silently returns a stale rate with `stale=false`.

## Vulnerability Detail

### Root Cause

`IxRenzoDeposit.getRate()` returns a `uint256` with no accompanying timestamp. The feed does not call any companion timestamp getter (e.g. `xRenzoDeposit.lastPriceTimestamp()` if exposed) and applies no secondary heartbeat check on the rate value. The ETH/USD Chainlink heartbeat check protects only the ETH leg.

### Code Location

- File: `src/prices/protocols/ezETH_L2_CustomPriceFeed.sol`
- Function: `_compute()`
- Lines: 63-66

```solidity
// @audit getRate() is keeper-relayed from L1; no staleness check on this value
uint256 ezEthRate = X_RENZO_DEPOSIT.getRate();
if (ezEthRate == 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
price = ezEthRate.mulDiv(uint256(ethToUsdPrice), 1e18, Math.Rounding.Floor);
```

The NatSpec acknowledges this gap:
> "Staleness gap: xRenzoDeposit.getRate() returns a cross-chain rate relayed from L1 by a keeper. Only the ETH/USD Chainlink heartbeat is verified here."

## Impact

- **Likelihood**: Low-Medium — L2 sequencer downtime or Renzo keeper failure can stall rate updates.
- **Impact**: Medium — during keeper lag, NAV reports an outdated ezETH price without raising a stale flag. The gap is bounded by the L1→L2 bridging frequency (typically 6–24 h for Renzo's keeper).
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions

- L2 sequencer experiences downtime or Renzo's L1→L2 rate relay keeper pauses.
- ETH/USD Chainlink feed on L2 is fresh (within its heartbeat).

### Attack Steps

1. Renzo keeper stops bridging the rate update; `xRenzoDeposit` retains the last pushed value.
2. ETH price moves significantly on L1.
3. A caller invokes `getLatestPrice()` on the L2 feed.
4. ETH/USD staleness check passes (Chainlink feed is fresh).
5. `getRate()` returns the stale pre-keeper-lag value.
6. The feed returns a price and `stale=false` that no longer reflects current L1 ezETH/ETH.
7. NAVCalculator records an inaccurate USD value for any L2 ezETH position.

### Expected Impact

- Portfolio NAV for L2 ezETH positions may deviate from fair value for the duration of the keeper lag, without any stale signal to downstream consumers.

## Recommended Mitigation

If `xRenzoDeposit` exposes a `lastPriceTimestamp()` function, add a secondary heartbeat check:

```solidity
uint256 rateTimestamp = X_RENZO_DEPOSIT.lastPriceTimestamp();
if (block.timestamp - rateTimestamp >= RATE_HEARTBEAT) {
    return (0, true, roundId, startedAt, updatedAt, answeredInRound);
}
```

If no timestamp is available from the contract, consider upgrading the rate relay contract to expose one. As an interim measure, document the keeper's SLA and monitor off-chain.
