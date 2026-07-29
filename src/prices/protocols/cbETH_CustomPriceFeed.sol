// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BaseCustomPriceFeed} from "src/prices/BaseCustomPriceFeed.sol";

/// @title cbETH Custom Price Oracle
/// @notice USD price of cbETH = `cbETH.exchangeRate()` (ETH per cbETH, 18 dec) × the NAV's ETH/USD price.
/// @dev Shared skeleton (base/USD via the NAV, staleness, decimals, latestRoundData, the `rate × base/USD / 1e18`
///      math) lives in BaseCustomPriceFeed; this feed supplies only the cbETH exchange rate via `_rate()`.
/// @dev **DEPLOYED NOWHERE TODAY — retained deliberately, not an oversight.** Mainnet cbETH is not a held asset, so
///      this contract has no entry in `contracts-deployment-config/custom-price-feeds/1.json` and no registration in
///      `nav-config`. `03_DeployPriceFeeds._deployCbEth()` is therefore a reachable-but-never-taken branch: its
///      `isAdapterEnabled("cbETH")` gate returns false because the key is absent.
///
///      It is kept because it is the natural MONITOR feed if mainnet cbETH is ever held. This contract reads
///      `cbETH.exchangeRate()` — a **fundamental** rate straight off the token — whereas {cbETH_L2_CustomPriceFeed}
///      (live on Base) composes a Chainlink cbETH/ETH **market** feed. Those are genuinely independent sources, which
///      is precisely what a divergence check requires: per `Prices.sol`, `_monitorFeeds` is "NEVER used to price the
///      NAV; read only to detect divergence", and "the intended production configuration is exactly one primary feed
///      per asset, with redundancy moved to `_monitorFeeds`". Pairing a fundamental primary against a market monitor
///      is the shape wstETH and weETH already use.
///
///      Do not delete it as dead code, and do not wire it up without a held cbETH position to price.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract cbETH_CustomPriceFeed is BaseCustomPriceFeed {
    /// @param cbEth_ The address of the cbETH token.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(address cbEth_, address nav_, address baseAsset_) BaseCustomPriceFeed(cbEth_, nav_, baseAsset_) {}

    /// @inheritdoc BaseCustomPriceFeed
    function _rate() internal view override returns (uint256) {
        return IcbETH(UNDERLYING).exchangeRate();
    }
}

interface IcbETH {
    /// @notice Get the exchange rate of cbETH to ETH (18 decimals).
    function exchangeRate() external view returns (uint256);
}
