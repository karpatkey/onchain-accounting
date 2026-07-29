// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BaseCustomPriceFeed} from "src/prices/BaseCustomPriceFeed.sol";
import {NotAContract} from "src/errors.sol";

/// @title osToken Custom Price Oracle
/// @notice USD price of a StakeWise osToken (osETH, osGNO, …) = `OsTokenVaultController.convertToAssets(1e18)`
///         (underlying per osToken, 18 dec) × the NAV's <underlying>/USD price.
/// @dev Shared skeleton (base/USD via the NAV, staleness, decimals, latestRoundData, the `rate × base / 1e18` math)
///      lives in BaseCustomPriceFeed; the base asset here is the <underlying> priced by the NAV and `_rate()` is the
///      osToken→underlying conversion rate.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract osToken_CustomPriceFeed is BaseCustomPriceFeed {
    /// @notice StakeWise OsTokenVaultController exposing convertToAssets.
    IOsTokenVaultController public immutable OS_TOKEN_VAULT_CONTROLLER;

    /// @param osToken_ The osToken address (osETH, osGNO, …).
    /// @param osTokenVaultController_ The StakeWise OsTokenVaultController for this osToken.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (the underlying, e.g. WETH/GNO) whose NAV-selected USD price scales the rate.
    constructor(address osToken_, address osTokenVaultController_, address nav_, address baseAsset_)
        BaseCustomPriceFeed(osToken_, nav_, baseAsset_)
    {
        if (osTokenVaultController_.code.length == 0) revert NotAContract("OsTokenVaultController");
        OS_TOKEN_VAULT_CONTROLLER = IOsTokenVaultController(osTokenVaultController_);
    }

    /// @inheritdoc BaseCustomPriceFeed
    function _rate() internal view override returns (uint256) {
        return OS_TOKEN_VAULT_CONTROLLER.convertToAssets(1e18);
    }
}

interface IOsTokenVaultController {
    /// @notice Converts a given amount of osToken shares to the underlying asset amount.
    /// @param shares The amount of osToken shares to convert.
    /// @return assets The equivalent amount of underlying assets.
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}
