// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BaseCustomPriceFeed} from "src/prices/BaseCustomPriceFeed.sol";

/// @title osToken Custom Price Oracle
/// @notice USD price of a StakeWise osToken (osETH, osGNO, …) = `OsTokenVaultController.convertToAssets(1e18)`
///         (underlying per osToken, 18 dec) × Chainlink <underlying>/USD.
/// @dev Shared skeleton (staleness, decimals, latestRoundData, the `rate × base / 1e18` math) lives in
///      BaseCustomPriceFeed; the base feed here is the <underlying>/USD oracle and `_rate()` is the
///      osToken→underlying conversion rate.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract osToken_CustomPriceFeed is BaseCustomPriceFeed {
    /// @notice StakeWise OsTokenVaultController exposing convertToAssets.
    IOsTokenVaultController public immutable OS_TOKEN_VAULT_CONTROLLER;

    /// @param osToken_ The osToken address (osETH, osGNO, …).
    /// @param osTokenVaultController_ The StakeWise OsTokenVaultController for this osToken.
    /// @param underlyingToUsdChainlinkOracle_ The Chainlink <underlying>/USD oracle (ETH/USD, GNO/USD, …).
    /// @param underlyingToUsdChainlinkHeartbeat_ Seconds after which the Chainlink price is considered stale.
    constructor(
        address osToken_,
        address osTokenVaultController_,
        address underlyingToUsdChainlinkOracle_,
        uint256 underlyingToUsdChainlinkHeartbeat_
    ) BaseCustomPriceFeed(osToken_, underlyingToUsdChainlinkOracle_, underlyingToUsdChainlinkHeartbeat_) {
        require(osTokenVaultController_.code.length > 0, "OsTokenVaultController must be a contract");
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
