# L-01 — Rate-feed `.decimals()` called live on every price computation instead of cached at construction

## Summary

Seven adapters call the rate-leg oracle's `.decimals()` function on every invocation of `_compute()` instead of caching the value at construction time. The adapters affected are `CrossRate_Price.sol`, `LDO_Price.sol`, `wstETH_L2_Price.sol`, `cbETH_L2_Price.sol`, `rsETH_L2_Price.sol`, `weETH_L2_Price.sol`, and `syrupUSDC_L2_Price.sol`. If the Chainlink proxy for the rate feed is ever upgraded to an aggregator that returns a different `decimals()` value, the price scaling in `_compute()` will silently diverge from the fixed `_decimals` value cached at construction (which comes from the USD-leg feed), resulting in a permanently miscalculated output price with no revert.

## Vulnerability Detail

Each adapter stores `_decimals` once in the constructor from the USD-leg feed (e.g., ETH/USD → 8):

```solidity
// wstETH_L2_Price.sol  line 69
_decimals = ETH_TO_USD_CHAINLINK_ORACLE.decimals();
```

However the denominator used in the price computation reads the rate-feed decimals live at every call:

```solidity
// wstETH_L2_Price.sol  lines 102-103
price = wstEthToEthRate.toUint256()
    .mulDiv(ethToUsdPrice.toUint256(), 10 ** WSTETH_TO_ETH_CHAINLINK_ORACLE.decimals(), Math.Rounding.Floor);
```

The same pattern appears in:

| File | Live `.decimals()` call |
|---|---|
| `CrossRate_Price.sol` line 77 | `10 ** Y_TO_X_FEED.decimals()` |
| `LDO_Price.sol` line 112 | `10 ** LDO_TO_ETH_CHAINLINK_ORACLE.decimals()` |
| `cbETH_L2_Price.sol` line 70 | `10 ** CBETH_TO_ETH_CHAINLINK.decimals()` |
| `rsETH_L2_Price.sol` line 70 | `10 ** RSETH_TO_ETH_CHAINLINK.decimals()` |
| `weETH_L2_Price.sol` line 70 | `10 ** WEETH_TO_EETH_CHAINLINK.decimals()` |
| `syrupUSDC_L2_Price.sol` line 71 | `10 ** SYRUP_USDC_TO_USDC_CHAINLINK_ORACLE.decimals()` |

Chainlink aggregator proxies can be pointed at a new underlying aggregator by the feed owner. If the replacement aggregator returns `decimals() = 8` where the original returned `18` (or vice-versa), the exponent in the denominator changes by `1e10`, producing a price that is 10 billion times too large or too small. Because `_decimals` is already cached with the correct output precision (8), the adapter's `decimals()` function continues to report 8 correctly — the error is invisible to feed-selection logic but the numeric value is catastrophically wrong.

Secondary issue: the live external call costs ~2 100 gas per `_compute()` invocation. Caching in a `uint8 immutable` at construction eliminates this overhead.

## Root Cause

- `CrossRate_Price.sol` line 77
- `LDO_Price.sol` line 112
- `wstETH_L2_Price.sol` line 103
- `cbETH_L2_Price.sol` line 70
- `rsETH_L2_Price.sol` line 70
- `weETH_L2_Price.sol` line 70
- `syrupUSDC_L2_Price.sol` line 71

## Impact

If the rate-leg Chainlink proxy is upgraded to an aggregator with a different `decimals()` value, every subsequent `getLatestPrice()` call returns a price that is off by a factor of `10^(old_decimals − new_decimals)`. The adapter continues to signal `stale = false`, so the NAV calculator receives and uses the wrong price without any staleness signal. No revert, no on-chain alert.

Likelihood is low — Chainlink rarely changes feed decimals — but the consequence is severe if it occurs.

## Attack Scenario / PoC

1. Chainlink upgrades the wstETH/ETH feed proxy on Arbitrum from an 18-decimal aggregator to an 8-decimal aggregator.
2. `wstETH_L2_PriceOracle._compute()` now computes: `wstEthToEthRate[1e18] * ethToUsdPrice[1e8] / 1e8 = result[1e18]`.
3. `_decimals()` still returns 8 (cached at construction time from the unchanged ETH/USD feed).
4. `getLatestPrice()` returns a price that is `1e10` times larger than the true USD price of wstETH.
5. NAVCalculator values the wstETH position at 10 billion times its actual worth.

## Preconditions

- The Chainlink proxy for the rate-leg feed is upgraded to an aggregator with different decimals.
- No administrator notices and replaces the price adapter.

## Mitigation

Cache the rate-feed decimals in an immutable at construction time, exactly as done for the USD-feed decimals:

```solidity
// Constructor addition
uint8 private immutable _rateDecimals;

constructor(...) {
    ...
    _rateDecimals = WSTETH_TO_ETH_CHAINLINK_ORACLE.decimals();
    _decimals = ETH_TO_USD_CHAINLINK_ORACLE.decimals();
}

// _compute() change
price = wstEthToEthRate.toUint256()
    .mulDiv(ethToUsdPrice.toUint256(), 10 ** _rateDecimals, Math.Rounding.Floor);
```

Apply the same pattern to all seven affected adapters. This also reduces gas cost by ~2 100 per call and makes the invariant (`output decimals = USD-feed decimals`) easy to audit statically.
