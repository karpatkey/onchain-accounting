# [WITHDRAWN — formula verified correct]

The three-branch feeGrowthInside formula in `_computeFees` was initially flagged but is correct per Uniswap V3 whitepaper §6.3.

- `tickCurrent < tickLower`: fgInside = fgOutLower - fgOutUpper (correct)
- `tickLower <= tickCurrent < tickUpper`: fgInside = fgGlobal - fgOutLower - fgOutUpper (correct)
- `tickCurrent >= tickUpper`: fgInside = fgOutUpper - fgOutLower (correct)

All subtractions are inside `unchecked` matching Uniswap's own implementation. No finding.
