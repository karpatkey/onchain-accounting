# I-01 — LDO_Price.sol: inline comment incorrectly states LDO/ETH feed uses 8 decimals

## Summary

The inline comment in `LDO_Price.sol` states that both the LDO/ETH and ETH/USD prices are "in 8 decimals". The actual Chainlink LDO/ETH feed on Ethereum mainnet (`0x4e844912dbB21F4d8de54D82E6D7b6b80bd1dDD8`) uses **18 decimals** (ETH-denominated feeds on Chainlink mainnet universally use 18 decimals). The code is arithmetically correct because it uses `LDO_TO_ETH_CHAINLINK_ORACLE.decimals()` dynamically, but the comment creates confusion about the expected precision of the intermediate calculation.

## Vulnerability Detail

```solidity
// LDO_Price.sol  lines 108-112
// LDO/ETH price is in 8 decimals, ETH/USD price is in 8 decimals
// First multiply the prices together (this will have 8 + 8 = 16 decimals)
// Then divide by 10^8 to get back to 8 decimals (matching ETH/USD)
price = ldoToEthPrice.toUint256()
    .mulDiv(ethToUsdPrice.toUint256(), 10 ** LDO_TO_ETH_CHAINLINK_ORACLE.decimals(), Math.Rounding.Floor);
```

The actual computation, with the real decimals:
- `ldoToEthPrice`: 18 decimals (Chainlink LDO/ETH feed).
- `ethToUsdPrice`: 8 decimals (Chainlink ETH/USD feed).
- `10 ** LDO_TO_ETH_CHAINLINK_ORACLE.decimals()` = `10^18`.
- `mulDiv(ldoToEth[1e18], ethToUsd[1e8], 1e18)` = result in `1e8` ✓.

The comment describes "8 + 8 = 16 decimals → divide by 10^8" which corresponds to a scenario where LDO/ETH were 8 decimals. The actual intermediate product is `1e26`, divided by `1e18`, producing the correct `1e8` result. The arithmetic is right; the comment is wrong.

## Root Cause

`LDO_Price.sol` lines 108-110 — incorrect description of LDO/ETH feed precision.

## Impact

Purely informational. The runtime computation is correct. A developer maintaining this contract and trusting the comment over the code could incorrectly assume the LDO/ETH feed returns 8-decimal prices, potentially leading to errors when reasoning about acceptable price ranges, precision loss, or when writing test assertions with hardcoded expected values.

## Preconditions

N/A — no runtime impact.

## Mitigation

Replace the comment with the correct decimals:

```solidity
// LDO/ETH price is in 18 decimals (ETH-denominated Chainlink feed), ETH/USD price is in 8 decimals.
// Intermediate product has 26 decimals; dividing by 10^18 yields 8 decimals (matching ETH/USD output).
```
