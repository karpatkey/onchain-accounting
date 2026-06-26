# H-03 — `sUSDS_Price` and `sUSDe_Price` pass Chainlink decimal units as vault share units to `convertToAssets`, producing a near-zero price

## Summary

`sUSDS_Price._compute()` and `sUSDe_Price._compute()` call `IERC4626.convertToAssets(10 ** _decimals)` where `_decimals` is taken from the Chainlink feed (`8` for most USD feeds). The ERC-4626 vault share tokens (sUSDS, sUSDe) have **18 decimals**, so a correct probe is `convertToAssets(1e18)`. Passing `1e8` instead of `1e18` queries the vault for the assets backing only `0.0000000001` shares (one hundred-millionth of one share), returning a vanishingly small number. The subsequent division by `10 ** _decimals` does not compensate, leaving a price that is `1e10` times smaller than intended — effectively zero for most practical exchange rates.

## Vulnerability Detail

### `sUSDS_CustomPriceFeed.sol` (lines 83–87)

```solidity
uint256 sUsdsToUsdsPrice = IERC4626(S_USDS).convertToAssets(10 ** _decimals);
// comment says "sUSDS/USDS price is in 18 decimals" — incorrect
price = sUsdsToUsdsPrice.mulDiv(usdsToUsdPrice.toUint256(), 10 ** _decimals, Math.Rounding.Floor);
```

- `_decimals = 8` (from Chainlink USDS/USD oracle)
- `convertToAssets(1e8)` is called on an 18-decimal vault
- sUSDS has 18 decimals; `1e8` shares ≈ `1e8 / 1e18` = `1e-10` full shares
- `convertToAssets(1e8)` ≈ `floor(1e8 * totalAssets / totalShares)` ≈ `1e8 * 1.05 / 1e0` = `1` (rounds to 0 or 1 depending on rounding)
- `price = 1 * USDS_USD / 1e8 = 1e8 / 1e8 = 1` → 1 USD-unit in 8 decimals = **$0.00000001** for sUSDS

The true price of sUSDS should be approximately $1.05 at current rates. The computed price is approximately $0.00000001 — a factor of ~10^8 lower.

### `sUSDe_CustomPriceFeed.sol` (lines 81–82)

Identical pattern:

```solidity
uint256 sUsdeToUsdePrice = IERC4626(S_USDE).convertToAssets(10 ** _decimals);
price = sUsdeToUsdePrice.mulDiv(usdeToUsdPrice.toUint256(), 10 ** _decimals, Math.Rounding.Floor);
```

sUSDe also has 18 decimals. Same `1e8` probe → same near-zero result.

### Why `syrupUSDC_Price` is incidentally correct

`syrupUSDC` (built on USDC) typically has **6-decimal** shares. Chainlink USDC/USD has 8 decimals, so `_decimals = 8`. The probe `convertToAssets(1e8)` = `convertToAssets(100 USDC-shares)` returns approximately `1e8 * rate` USDC atoms. After dividing by `1e8` the price is ~`rate * USDC_USD` which is correct. This coincidence hides the pattern bug in the test suite.

## Root Cause

- `sUSDS_CustomPriceFeed.sol:83` — `10 ** _decimals` used as the share unit instead of `10 ** IERC4626(S_USDS).decimals()`
- `sUSDe_CustomPriceFeed.sol:81` — same root cause

The formula implicitly assumes the vault share decimals equal the Chainlink feed decimals, which is false for sUSDS and sUSDe.

## Impact

`sUSDS_Price` and `sUSDe_Price` return a price approximately `1e10` times smaller than the real price. Any NAVCalculator call that prices sUSDS or sUSDe positions will report near-zero values for those assets, causing severe undervaluation of the portfolio NAV. If the system gates withdrawals, rebalancing, or risk checks on NAV, this undervaluation will misprice large positions.

Because `price != 0`, the adapter does **not** return `stale = true`. The broken price propagates as a valid, fresh price.

## Attack Scenario

This is a systemic miscalculation rather than an attacker-triggered event:

1. Protocol holds 10,000 sUSDS (real value ≈ $10,500).
2. `sUSDS_Price.getLatestPrice()` returns `price ≈ 1` (1 USD-unit = $0.00000001).
3. NAVCalculator prices the position at `10,000 * 0.00000001 = $0.0001`.
4. NAV is reported as missing ~$10,500 worth of assets.
5. Downstream systems (risk monitoring, rebalancing triggers, external integrators reading `latestPrice`) act on severely wrong data.

## Preconditions

- sUSDS or sUSDe is registered and has a non-zero balance in a monitored position.
- The Chainlink USDS/USD or USDe/USD feed is fresh (adapter does not return stale).

## Mitigation

Use the vault's own declared share decimals for the probe unit, not the Chainlink feed decimals:

```solidity
// sUSDS_CustomPriceFeed.sol — corrected _compute()
uint256 shareUnit = 10 ** IERC4626(S_USDS).decimals();          // 18 for sUSDS
uint256 sUsdsToUsdsPrice = IERC4626(S_USDS).convertToAssets(shareUnit);
// sUsdsToUsdsPrice is now in USDS-atom units (18 dec) per 1 sUSDS share (18 dec)
// Result decimals: USDS atoms (18) per share (18) → dimensionless ratio × 1e18 scaling
price = sUsdsToUsdsPrice.mulDiv(usdsToUsdPrice.toUint256(), shareUnit, Math.Rounding.Floor);
```

Apply the same fix to `sUSDe_CustomPriceFeed.sol`.
