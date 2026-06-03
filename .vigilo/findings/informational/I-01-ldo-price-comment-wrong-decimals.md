# LDO_Price: inline comment claims 8-decimal feed, actual feed uses 18 decimals

## Severity: Informational

## Summary
The inline comment in `LDO_Price._compute()` describes the LDO/ETH Chainlink feed as 8
decimals, but the mainnet LDO/ETH feed uses 18 decimals. The computation is correct because
`_decimals` is read dynamically from the oracle, but the comment will mislead developers
reasoning about expected value ranges or writing test expectations.

## Root Cause
`src/prices/protocols/LDO_Price.sol` — inline comment above the `mulDiv` call.

## Mitigation
Update the comment to reflect that the LDO/ETH feed uses 18 decimals (matching the feed's
actual `decimals()` return value), and describe the scaling accordingly:
`LDO/ETH (18 dec) × ETH/USD (8 dec) / 1e18 → result in 8 dec`.
