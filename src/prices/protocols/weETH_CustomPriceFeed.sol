// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BaseCustomPriceFeed} from "src/prices/BaseCustomPriceFeed.sol";

/// @title weETH Custom Price Oracle (pure fundamental)
/// @notice Returns the USD price of weETH from its on-chain exchange rate and the NAV's ETH/USD price:
///         `price = weETH.getRate() × (ETH/USD)`, treating eETH/ETH ≡ 1.0 (eETH is a ~1:1 rebasing claim on ETH).
/// @dev Pure-fundamental `BaseCustomPriceFeed` subclass — no market leg. `getRate()` (eETH per 1 weETH, 18 decimals)
///      is the 18-decimal "base-token units per UNDERLYING" the base expects, since 1 eETH ≈ 1 ETH. Any market
///      divergence is surfaced by a market MONITOR feed (e.g. Redstone weETH/USD) via NAVCalculator's divergence
///      check, NOT by moving this primary price. (The L2 variant instead reads a Chainlink weETH/eETH exchange-rate
///      feed, since weETH is bridged and has no on-chain rate there.)
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract weETH_CustomPriceFeed is BaseCustomPriceFeed {
    /// @param weEth_ The weETH token address.
    /// @param nav_ The NAVCalculator proxy to read the base asset's (ETH/USD) price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(address weEth_, address nav_, address baseAsset_) BaseCustomPriceFeed(weEth_, nav_, baseAsset_) {}

    /// @inheritdoc BaseCustomPriceFeed
    /// @dev ETH per weETH ≡ eETH per weETH (eETH/ETH ≡ 1.0). Returns 0 to mark stale (base handles it).
    function _rate() internal view override returns (uint256) {
        return IweETH(UNDERLYING).getRate();
    }
}

interface IweETH {
    /// @notice Amount of eETH for 1 weETH (18 decimals).
    function getRate() external view returns (uint256);
}
