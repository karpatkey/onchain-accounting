# H-02 — Protocol-internal rate sources have no staleness check; a frozen rate passes as fresh

## Summary

Five adapters — `rETH_Price`, `wstETH_Price`, `cbETH_Price`, `rsETH_Price`, and `ETHx_Price` — multiply a Chainlink ETH/USD price by a rate obtained directly from a protocol contract (`getExchangeRate()`, `stEthPerToken()`, `exchangeRate()`, `getLatestRate()`). The Chainlink heartbeat is enforced, but **no timestamp or freshness check is applied to the protocol-internal rate**. If the on-chain rate freezes (governance pause, oracle failure inside the protocol, or deliberate manipulation), the adapter returns a valid-looking non-stale price with an arbitrarily old rate.

## Vulnerability Detail

Pattern shared by all five adapters (example from `rETH_CustomPriceFeed.sol`):

```solidity
// rETH_CustomPriceFeed.sol:66-73
(roundId, ethToUsdPrice, startedAt, updatedAt, answeredInRound) =
    ETH_TO_USD_CHAINLINK_ORACLE.latestRoundData();
if (ethToUsdPrice <= 0) { return (0, true, ...); }
uint256 effectiveUpdatedAt = updatedAt > block.timestamp ? block.timestamp : updatedAt;
if (block.timestamp - effectiveUpdatedAt >= ETH_TO_USD_CHAINLINK_HEARTBEAT) {
    return (0, true, ...);
}
uint256 rate = IrETH(RETH).getExchangeRate();   // ← no freshness check
if (rate == 0) { return (0, true, ...); }
price = rate.mulDiv(uint256(ethToUsdPrice), 1e18, Math.Rounding.Floor);
```

The only gate on `rate` is `rate == 0`. A stale but non-zero cached rate passes silently.

Affected files and rate sources:

| File | Rate source | Function |
|---|---|---|
| `rETH_CustomPriceFeed.sol:70` | Rocket Pool rETH contract | `getExchangeRate()` |
| `wstETH_CustomPriceFeed.sol:70` | Lido wstETH contract | `stEthPerToken()` |
| `cbETH_CustomPriceFeed.sol:70` | Coinbase cbETH contract | `exchangeRate()` |
| `rsETH_CustomPriceFeed.sol:80` | Kelp DAO rate provider | `getLatestRate()` |
| `ETHx_CustomPriceFeed.sol:82` | Stader StakePoolsManager | `getExchangeRate()` |

## Root Cause

The adapters assume that protocol-internal rate functions are continuously updated in-sync with blocks. In practice:

- `rETH`'s `getExchangeRate()` is updated by a Rocket Pool Oracle DAO multisig on a periodic schedule. If the DAO pauses updates, the rate can be stale for days.
- Stader's `getExchangeRate()` similarly depends on off-chain oracle submissions.
- Kelp's `getLatestRate()` is pushed by a trusted rate provider, not permissionlessly computed.

None of these carry an on-chain "last updated at" timestamp that the adapter could check. The only observable staleness indicator would be comparing the rate against a previous stored snapshot — which these adapters do not do.

## Impact

If any of these protocol rate sources freeze (due to governance pause, oracle multisig key compromise, or deliberate rate manipulation):

1. The adapter continues to return `stale = false` as long as the Chainlink ETH/USD feed is fresh.
2. NAVCalculator uses the stale rate multiplied by a fresh ETH/USD price, producing a price that may be significantly wrong (hours or days stale in extreme cases).
3. If a single-feed configuration, there is no backup feed to detect the discrepancy.

## Attack Scenario (rsETH — most actionable)

Kelp DAO's `getLatestRate()` is sourced from a trusted off-chain provider address that is upgradeable/governable. If the trusted provider is compromised or the Kelp governance is attacked:

1. Attacker gains control of the Kelp rate provider contract.
2. Attacker calls the provider to set `getLatestRate()` to an inflated value (e.g. 2x the real rsETH/ETH rate).
3. `rsETH_Price._compute()` fetches the inflated rate. Chainlink ETH/USD is fresh.
4. Adapter returns `stale = false`, `price = inflatedRate * ETH/USD`.
5. NAVCalculator reports rsETH worth 2x its real value.
6. Protocol decisions (NAV reporting, collateral ratios if used downstream) are based on the false price.

## Preconditions

- The respective protocol's rate-update mechanism must be paused, broken, or compromised.
- The Chainlink ETH/USD feed must remain fresh (otherwise both inputs are stale and the adapter correctly marks stale).

## Mitigation

For each adapter, compare the fetched rate against a plausible range and revert/mark stale on violation. Where the protocol exposes a `lastUpdated` timestamp alongside the rate, check it against a configured freshness window. Concretely:

1. Add a `rateHeartbeat` immutable to each adapter (e.g. 24 hours for Rocket Pool, 1 hour for Stader).
2. If the underlying protocol exposes a "rate updated at" timestamp, enforce `block.timestamp - rateUpdatedAt < rateHeartbeat`.
3. Where no timestamp is available, add an immutable `minRate` / `maxRate` sanity bound (e.g. rate must be within ±20% of 1e18 for LSTs) so an arbitrarily manipulated value at least gets rejected.
