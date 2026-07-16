// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BaseCustomPriceFeed} from "src/prices/BaseCustomPriceFeed.sol";

/// @title eETH Custom Price Oracle (pure fundamental)
/// @notice Returns the USD price of eETH as `1.0 × (ETH/USD)` — eETH is a ~1:1 rebasing claim on staked ETH, so its
///         fundamental (redeemable) value tracks ETH one-for-one and is priced directly off the NAV's ETH/USD.
/// @dev Pure-fundamental `BaseCustomPriceFeed` subclass with a constant unit rate (`1e18`). Any market divergence is
///      surfaced by a market MONITOR feed via NAVCalculator's divergence check, not by moving this primary price.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract eETH_CustomPriceFeed is BaseCustomPriceFeed {
    /// @param eEth_ The eETH token address.
    /// @param nav_ The NAVCalculator proxy to read the base asset's (ETH/USD) price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price is the eETH price.
    constructor(address eEth_, address nav_, address baseAsset_) BaseCustomPriceFeed(eEth_, nav_, baseAsset_) {}

    /// @inheritdoc BaseCustomPriceFeed
    /// @dev eETH/ETH ≡ 1.0, so the 18-decimal rate is the unit 1e18.
    function _rate() internal pure override returns (uint256) {
        return 1e18;
    }
}
