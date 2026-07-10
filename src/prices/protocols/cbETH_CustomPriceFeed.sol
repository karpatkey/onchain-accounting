// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BaseCustomPriceFeed} from "src/prices/BaseCustomPriceFeed.sol";

/// @title cbETH Custom Price Oracle
/// @notice USD price of cbETH = `cbETH.exchangeRate()` (ETH per cbETH, 18 dec) × the NAV's ETH/USD price.
/// @dev Shared skeleton (base/USD via the NAV, staleness, decimals, latestRoundData, the `rate × base/USD / 1e18`
///      math) lives in BaseCustomPriceFeed; this feed supplies only the cbETH exchange rate via `_rate()`.
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
