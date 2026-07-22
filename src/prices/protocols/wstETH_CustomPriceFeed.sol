// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BaseCustomPriceFeed} from "src/prices/BaseCustomPriceFeed.sol";

/// @title wstETH Custom Price Oracle (pure fundamental)
/// @notice Returns the USD price of wstETH from its on-chain redemption rate and the NAV's ETH/USD price:
///         `price = stEthPerToken × (ETH/USD)`, treating stETH/ETH ≡ 1.0 (Lido's fundamental redemption invariant).
/// @dev Pure-fundamental `BaseCustomPriceFeed` subclass — no market leg. `stEthPerToken()` (stETH per 1 wstETH, 18
///      decimals) is exactly the 18-decimal "base-token units per UNDERLYING" the base expects, since 1 stETH is
///      redeemable ~1:1 for ETH. Any market divergence (e.g. a stETH depeg) is surfaced by a market MONITOR feed
///      (e.g. Redstone wstETH/USD) via NAVCalculator's divergence check, NOT by moving this primary price.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract wstETH_CustomPriceFeed is BaseCustomPriceFeed {
    /// @param wstEth_ The wstETH token address.
    /// @param nav_ The NAVCalculator proxy to read the base asset's (ETH/USD) price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(address wstEth_, address nav_, address baseAsset_) BaseCustomPriceFeed(wstEth_, nav_, baseAsset_) {}

    /// @inheritdoc BaseCustomPriceFeed
    /// @dev ETH per wstETH ≡ stETH per wstETH (stETH/ETH ≡ 1.0). Returns 0 to mark stale (base handles it).
    function _rate() internal view override returns (uint256) {
        return IwstETH(UNDERLYING).stEthPerToken();
    }
}

interface IwstETH {
    /// @notice Amount of stETH for 1 wstETH (18 decimals).
    function stEthPerToken() external view returns (uint256);
}
