# M-04: weETH L2 — undocumented eETH≈ETH 1:1 parity assumption

## Summary

`weETH_L2_CustomPriceFeed` uses a `WEETH_TO_EETH_CHAINLINK` feed (weETH/eETH rate) multiplied by ETH/USD, treating eETH as worth exactly 1 ETH. The NatSpec documents this assumption (`"Assumes eETH ≈ ETH 1:1"`), but there is no assertion, circuit breaker, or maximum-deviation check enforcing the parity at runtime. If eETH were to de-peg significantly from ETH (as occurred historically during LSD market stress), the feed would continue reporting as if eETH equals ETH.

## Vulnerability Detail

### Root Cause

The formula `price = (weETH/eETH) * (ETH/USD)` substitutes `eETH ≈ ETH` by multiplying the `weETH/eETH` rate directly by `ETH/USD`. There is no guard checking that eETH/ETH is within a reasonable band (e.g. 0.99–1.01). A de-peg in eETH would silently inflate the reported weETH price.

### Code Location

- File: `src/prices/protocols/weETH_L2_CustomPriceFeed.sol`
- Function: `_compute()`
- Lines: 78-79

```solidity
// @audit eETH/ETH parity assumed; no circuit breaker or band check
price = weEthToEethRate.toUint256()
    .mulDiv(ethToUsdPrice.toUint256(), 10 ** WEETH_TO_EETH_CHAINLINK.decimals(), Math.Rounding.Floor);
```

Comment in the NatSpec: `"Assumes eETH ≈ ETH 1:1"`.

## Impact

- **Likelihood**: Low — EtherFi's eETH has maintained close parity; a significant de-peg requires a major protocol event.
- **Impact**: Medium — a 5% eETH de-peg would cause a 5% over-statement of weETH NAV without the feed returning `stale=true`.
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions

- EtherFi eETH de-pegs from ETH (e.g. large withdrawal queue back-pressure, protocol incident, or secondary market illiquidity on L2).
- Both Chainlink feeds (weETH/eETH and ETH/USD) remain fresh and within heartbeat.

### Attack Steps

1. eETH trades at 0.95 ETH on secondary markets due to a large de-peg event.
2. The Chainlink weETH/eETH feed continues reporting the on-chain conversion rate (weETH stays mechanically tied to eETH units).
3. `_compute()` multiplies (weETH/eETH) × (ETH/USD) without applying the eETH/ETH discount.
4. `getLatestPrice()` returns `stale=false` with a price that is ~5% above fair value.
5. NAVCalculator over-reports the USD value of any weETH L2 position.

### Expected Impact

- Portfolio NAV over-stated for L2 weETH positions by the magnitude of the eETH/ETH de-peg, without any staleness or circuit-breaker signal.

## Recommended Mitigation

Options in increasing robustness:

1. Add a live eETH/ETH Chainlink feed on the relevant L2 and multiply all three legs: `(weETH/eETH) * (eETH/ETH) * (ETH/USD)`.
2. Add a sanity-bound check: if the implied eETH/ETH rate (derivable from the weETH/eETH feed and weETH/ETH) diverges more than a configured threshold from 1.0, return `stale=true`.
3. Use the mainnet `weETH_CustomPriceFeed` pattern (weETH/ETH direct feed) if a wstETH/ETH-style L2 Chainlink feed for weETH/ETH becomes available.
