# sUSDS/sUSDe NatSpec describes convertToAssets(1e18) but code uses convertToAssets(1e8)

## Severity: Informational

## Summary
The NatSpec for `sUSDS_CustomPriceFeed` and `sUSDe_CustomPriceFeed` states
`sUSDS_per_share = IERC4626(sUSDS).convertToAssets(1e18)` and divides by 1e18.
The implementation calls `convertToAssets(10 ** _decimals)` (= 1e8) and divides by 1e8.
Both are mathematically equivalent due to `convertToAssets` being linear in shares, so the
computed price is correct. The NatSpec is misleading.

## Root Cause
`src/prices/protocols/sUSDS_CustomPriceFeed.sol:19` and `src/prices/protocols/sUSDe_CustomPriceFeed.sol:19`.

## Mitigation
Update the NatSpec `@dev` section to match the implementation:
```
where `sUSDS_per_share = IERC4626(sUSDS).convertToAssets(10**feedDecimals)`,
scaled back by `10**feedDecimals` via mulDiv.
```
