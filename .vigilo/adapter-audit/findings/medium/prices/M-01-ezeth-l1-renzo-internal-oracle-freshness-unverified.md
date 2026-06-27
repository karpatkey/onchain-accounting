# M-01: ezETH (L1) — Renzo internal oracle freshness unverified

## Summary

`ezETH_CustomPriceFeed._rate()` derives the ezETH/ETH exchange rate from `RestakeManager.calculateTVLs()`. That function aggregates the TVL of multiple underlying collateral tokens using Renzo's internal oracle system, whose staleness is not checked here. Only the ETH/USD Chainlink heartbeat is validated. If Renzo's internal oracles (or their keeper update cadence) lag, the price feed silently returns a stale rate as fresh.

## Vulnerability Detail

### Root Cause

`calculateTVLs()` internally calls Renzo's `RenzoOracle` to price each supported collateral (e.g. stETH, cbETH, ankrETH). The freshness of those sub-oracles is governed entirely by Renzo's keeper infrastructure. This feed has no way to interrogate those timestamps. There is no secondary heartbeat or freshness gate on the rate side.

### Code Location

- File: `src/prices/protocols/ezETH_CustomPriceFeed.sol`
- Function: `_rate()`
- Lines: 35-43

```solidity
// @audit calculateTVLs() prices each collateral via Renzo's internal oracles — no staleness check here
function _rate() internal view override returns (uint256) {
    try RESTAKE_MANAGER.calculateTVLs() returns (uint256[][] memory, uint256[] memory, uint256 totalTVL) {
        uint256 supply = IERC20(UNDERLYING).totalSupply();
        if (supply == 0) return 0;
        return totalTVL.mulDiv(1e18, supply, Math.Rounding.Floor);
    } catch {
        return 0;
    }
}
```

The NatSpec in the file acknowledges this limitation explicitly:
> "Staleness gap: calculateTVLs() reads Renzo's internal oracles, whose freshness is not independently checked here."

## Impact

- **Likelihood**: Low — Renzo's oracle maintenance has historically been reliable and the on-chain collateral basket is relatively stable LSTs with 24 h heartbeats.
- **Impact**: Medium — a stale internal TVL numerator causes the ezETH price to lag true value; in a NAV accounting context this yields an inaccurate portfolio valuation without triggering the stale flag.
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions

- Renzo's internal oracle keepers stop calling `RenzoOracle` updates for its collateral plugins.
- ETH/USD Chainlink feed remains fresh (within heartbeat), so the ETH/USD staleness gate in `BaseCustomPriceFeed._compute()` does not trip.

### Attack Steps

1. Renzo's internal keeper fails to refresh one or more collateral sub-oracles (e.g. stETH/ETH sub-feed inside Renzo).
2. `calculateTVLs()` returns an internally consistent but outdated TVL figure using stale sub-oracle prices.
3. `_rate()` divides that stale TVL by the current ezETH `totalSupply` and returns a rate that reflects old prices.
4. `BaseCustomPriceFeed._compute()` passes the ETH/USD staleness gate (it is fresh) and multiplies by the stale rate.
5. `getLatestPrice()` returns `stale=false` with an incorrect price.
6. NAVCalculator records an inaccurate USD value for any ezETH position.

### Expected Impact

- Inaccurate portfolio NAV for holdings of ezETH, potentially over- or under-reporting value by the magnitude of price drift in the lagging sub-oracle, without any stale signal being raised.

## Recommended Mitigation

Renzo's `xRenzoDeposit` (used by the L2 adapter) exposes a `lastPriceTimestamp()` or equivalent. On L1, `RestakeManager` does not expose a rate-update timestamp, so a complete fix is not achievable in this adapter without Renzo protocol changes. Mitigations include:

1. Document and accept the gap (already done in NatSpec), and monitor Renzo oracle health off-chain.
2. If Renzo exposes a `lastOracleUpdateTimestamp` in a future upgrade, add a secondary heartbeat check on it.
3. Consider switching the L1 feed to a direct Chainlink ezETH/ETH feed if one becomes available.
