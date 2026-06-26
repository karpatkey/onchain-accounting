# ezETH L2: xRenzoDeposit.getRate() has no staleness guard

## Severity: Medium

## Summary
`ezETH_L2_Price` multiplies a live Chainlink ETH/USD feed by a cross-chain ezETH/ETH rate
obtained from `xRenzoDeposit.getRate()`. The ETH/USD Chainlink heartbeat is checked, but the
L2 rate — relayed from L1 via Renzo's own keeper — has no age verification. A multi-hour
messaging delay or keeper outage returns a stale rate paired with a fresh ETH/USD price,
producing a wrong non-stale price with no warning.

## Vulnerability Detail
`ezETH_L2_Price._compute()` (line 49):
```solidity
uint256 ezEthRate = X_RENZO_DEPOSIT.getRate();
if (ezEthRate == 0) { return (0, true, ...); }
```
`xRenzoDeposit.getRate()` returns a stored value that is pushed from L1 by a keeper. The adapter
verifies only ETH/USD freshness (line 48). If the L1→L2 bridge is slow during sequencer
downtime recovery, or Renzo's keeper stops, `getRate()` returns a value that may be hours old.

## Root Cause
`src/prices/protocols/ezETH_L2_CustomPriceFeed.sol:49` — no timestamp check on the cross-chain rate.

## Impact
NAV is computed from an stale ezETH/ETH rate × fresh ETH price. During high-volatility periods
when the rate update lags, the computed price deviates from fair value while `stale = false`.

## Attack Scenario
1. L2 sequencer experiences downtime and recovers; Renzo's keeper hasn't relayed a new rate yet.
2. `xRenzoDeposit.getRate()` returns a 4-hour-old rate.
3. `ezETH_L2_Price.getLatestPrice()` returns `(staleRate * freshEthPrice, false)`.
4. NAVCalculator uses this price without detecting staleness.

## Preconditions
Renzo keeper outage or L1→L2 bridge delay. No attacker action required.

## Mitigation
`xRenzoDeposit` should expose a `lastUpdated()` timestamp alongside `getRate()`. If available,
add a heartbeat check analogous to the ETH/USD check. If not available, document the gap in
the NatSpec (the L1 adapter already documents its analogous limitation). Alternatively, use
an independent ezETH/USD Chainlink feed on L2 as a cross-check.
