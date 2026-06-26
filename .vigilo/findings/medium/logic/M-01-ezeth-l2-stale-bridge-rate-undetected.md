# M-01 — ezETH L2: Cross-chain rate from xRenzoDeposit has no staleness guard

## Summary

`ezETH_L2_CustomPriceFeed.sol` multiplies the `xRenzoDeposit.getRate()` exchange rate by the Chainlink ETH/USD price to produce the USD price of ezETH on L2. A heartbeat check is applied to the ETH/USD Chainlink feed, but **no staleness check whatsoever is applied to the `xRenzoDeposit.getRate()` return value**. Because this rate is relayed from L1 via a cross-chain bridge message, it can become arbitrarily stale during bridge latency, sequencer downtime, or Renzo oracle inactivity — and the adapter will silently treat a stale rate as fresh.

## Vulnerability Detail

`IxRenzoDeposit.getRate()` on the L2 contract returns the ezETH-per-ETH rate that was last pushed from L1. The push cadence is determined by Renzo's L1 oracle and the bridge liveness, neither of which is inspected by the adapter. The function has no timestamp or version field that could be read to bound the age of the rate.

```solidity
// ezETH_L2_CustomPriceFeed.sol  lines 49-52
uint256 ezEthRate = X_RENZO_DEPOSIT.getRate();
if (ezEthRate == 0) { return (0, true, roundId, startedAt, updatedAt, answeredInRound); }
// ezETH/ETH rate is 18 decimals, ETH/USD is 8 decimals -> result is 8 decimals
price = ezEthRate.mulDiv(uint256(ethToUsdPrice), 1e18, Math.Rounding.Floor);
```

The only staleness protection present is for the Chainlink ETH/USD feed (lines 46-48). The rate component is accepted unconditionally as long as it is non-zero.

Contrast this with the mainnet adapter (`ezETH_CustomPriceFeed.sol`), whose NatSpec explicitly acknowledges the analogous limitation for `calculateTVLs()` (lines 17-18), yet the L2 adapter carries no equivalent caveat and gives operators no signal that the rate may be hours or days old.

## Root Cause

`ezETH_L2_CustomPriceFeed.sol`, lines 49-52 — `X_RENZO_DEPOSIT.getRate()` is consumed without querying any update timestamp or applying a heartbeat guard.

`IxRenzoDeposit` interface (lines 89-91) exposes only `getRate()` with no companion timestamp function.

## Impact

During bridge disruptions (e.g., L2 sequencer downtime followed by a grace-period catch-up, or Renzo L1 oracle inactivity), the ezETH/ETH rate stored in `xRenzoDeposit` can be many hours old. The adapter will report a non-stale price derived from that old rate combined with a fresh ETH/USD price, causing the NAV calculation for any portfolio holding L2 ezETH to be based on a mispriced ezETH. Depending on the direction of rate drift, this leads to either overvaluation or undervaluation.

## Attack Scenario / PoC

1. The L2 sequencer goes offline for a period long enough that Renzo's keeper cannot push a new rate to `xRenzoDeposit`.
2. During the grace period after sequencer recovery, the L2 is live but `xRenzoDeposit` still holds the pre-downtime rate (e.g., from 24 h ago).
3. A call to `getLatestPrice()` on `ezETH_L2_CustomPriceFeed` returns `stale = false` as long as:
   - The Chainlink ETH/USD feed is fresh (it would be updated immediately after sequencer recovery).
   - `ezEthRate != 0` (always true — the stale rate is still stored).
4. NAVCalculator prices ezETH using the stale rate × fresh ETH/USD, producing an incorrect NAV.

## Preconditions

- `ezETH_L2_CustomPriceFeed` is deployed and registered as a price feed for L2 ezETH.
- A bridge disruption or Renzo oracle inactivity causes `xRenzoDeposit` to hold an aged rate.
- The Chainlink ETH/USD feed recovers (posts a fresh update) before `xRenzoDeposit` receives a new rate.

## Mitigation

1. **If `xRenzoDeposit` exposes a rate timestamp:** add a heartbeat check analogous to the ETH/USD check — store a `X_RENZO_RATE_HEARTBEAT` immutable and gate on `block.timestamp - lastRateUpdate >= X_RENZO_RATE_HEARTBEAT → stale`.

2. **If no timestamp is available (current interface):** document the architectural constraint clearly in the NatSpec (mirroring `ezETH_CustomPriceFeed.sol`) and evaluate whether a secondary Chainlink ezETH/ETH feed (once available on the L2) should be used instead or as a fallback.

3. **Alternatively**, switch to a Chainlink-native ezETH/ETH price feed if one becomes available on the target L2, which would allow a proper heartbeat guard.
