// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BaseCustomPriceFeed} from "src/prices/BaseCustomPriceFeed.sol";

/// @title rETH Custom Price Oracle
/// @notice USD price of rETH = `rETH.getExchangeRate()` (ETH per rETH, 18 dec) × the NAV's ETH/USD price.
/// @dev Shared skeleton (base/USD via the NAV, staleness, decimals, latestRoundData, the `rate × base/USD / 1e18`
///      math) lives in BaseCustomPriceFeed; this feed supplies only the rETH exchange rate via `_rate()`.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract rETH_CustomPriceFeed is BaseCustomPriceFeed {
    /// @param rEth_ The address of the rETH token.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(address rEth_, address nav_, address baseAsset_) BaseCustomPriceFeed(rEth_, nav_, baseAsset_) {}

    /// @inheritdoc BaseCustomPriceFeed
    function _rate() internal view override returns (uint256) {
        return IrETH(UNDERLYING).getExchangeRate();
    }
}

interface IrETH {
    /// @notice Get amount of ETH backing 1 rETH (18 decimals).
    function getExchangeRate() external view returns (uint256);
}
