# M-01 — `ezETH_Price`: `calculateTVLs()` result is accepted without any sanity bounds; a malicious Renzo contract inflates price arbitrarily

## Summary

`ezETH_PriceOracle._compute()` wraps `RESTAKE_MANAGER.calculateTVLs()` in a `try/catch` and uses the returned `totalTVL` unchecked to compute the ezETH/ETH rate. If the `RestakeManager` contract is upgraded, paused, or compromised, it can return any `totalTVL`. There is no lower bound, upper bound, or cross-check against an external independent price source for the TVL figure. The only guard against an obviously wrong value is the zero-supply check on ezETH.

## Vulnerability Detail

```solidity
// ezETH_Price.sol:55-64
try RESTAKE_MANAGER.calculateTVLs() returns (uint256[][] memory, uint256[] memory, uint256 totalTVL) {
    uint256 supply = IERC20(EZETH).totalSupply();
    if (supply == 0) { return (0, true, ...); }
    ezEthRate = totalTVL.mulDiv(1e18, supply, Math.Rounding.Floor);
} catch {
    return (0, true, ...);
}
if (ezEthRate == 0) { return (0, true, ...); }
price = ezEthRate.mulDiv(uint256(ethToUsdPrice), 1e18, Math.Rounding.Floor);
```

The `try/catch` ensures that a reverting `calculateTVLs()` marks the feed stale — this is a safety measure. However, a *non-reverting* but manipulated return value passes through without any validation.

**The `calculateTVLs()` path is inherently trusted:**

Renzo's `RestakeManager` is a UUPS-upgradeable contract controlled by a multisig. Its `calculateTVLs()` internally aggregates TVL from operator delegators, each of which calls its own oracle. If any sub-oracle is manipulated (or if the `RestakeManager` itself is upgraded with a malicious implementation), `totalTVL` can be set to an arbitrary value.

Additionally, the adapter note in the NatSpec acknowledges a related staleness issue:

> "calculateTVLs() reads Renzo's internal oracles, whose freshness is not independently checked here."

This confirms that the TVL figure may reflect stale sub-oracle prices without the adapter detecting it.

## Root Cause

`ezETH_Price.sol:55–64` — `totalTVL` from `calculateTVLs()` is used directly as the numerator in the price formula with no:
- Minimum TVL sanity check
- Maximum TVL sanity check (e.g. totalTVL must be < totalSupply * MAX_RATE_ETH)
- Independent reference price comparison

## Impact

A compromised or upgraded Renzo `RestakeManager` can set `totalTVL` to any value:

- **Inflated TVL**: ezETH price is reported as many multiples of real value. If used in collateral or risk calculations, this overstates NAV.
- **Deflated TVL (non-zero)**: ezETH appears worth nearly nothing, understating NAV.
- **Stale sub-oracle TVL**: Already acknowledged in NatSpec. The adapter cannot detect this — it correctly marks only a `calculateTVLs()` revert as stale, not a stale-but-non-reverting call.

## Attack Scenario

1. Renzo's multisig governance is compromised (3-of-5 key theft, social engineering, etc.).
2. Attacker upgrades `RestakeManager` to a version that returns `totalTVL = 100 * realTVL`.
3. `calculateTVLs()` does not revert; it returns the inflated figure.
4. `ezETH_PriceOracle` computes `ezEthRate = (100 * realTVL) * 1e18 / supply = 100 * realRate`.
5. `getLatestPrice()` returns `(100 * realPrice, false)` — marked as non-stale.
6. NAVCalculator prices ezETH at 100x real value.

Alternatively, a flash-loan attack against a Renzo sub-oracle (if any sub-oracle reads a spot price) would inflate `totalTVL` within the same transaction.

## Preconditions

- Renzo `RestakeManager` must be compromised, upgraded maliciously, or have a sub-oracle that reads a manipulable price.
- The Chainlink ETH/USD feed must remain fresh.

## Mitigation

1. **Rate bounds check**: After computing `ezEthRate`, verify it falls within a plausible range (e.g. `0.9e18 <= ezEthRate <= 1.5e18` for a liquid restaking token expected to trade close to 1 ETH). Revert/mark stale on violation.
2. **Independent cross-check**: If a Chainlink ezETH/ETH or ezETH/USD feed becomes available, compare the TVL-derived price against it and mark stale if the deviation exceeds a threshold (e.g. 5%).
3. **Stale sub-oracle detection**: If Renzo's `calculateTVLs()` exposes timestamps for each sub-oracle, enforce a freshness check on those timestamps as well.
