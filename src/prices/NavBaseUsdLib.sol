// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {NAV_DECIMALS} from "src/constants.sol";

/// @title NavBaseUsdLib
/// @author KPK
/// @notice Single reuse point for custom price feeds that price an asset as `rate × base/USD` and want the
///         `base/USD` term to come from the **NAV's own price selector** (`getPriceData(baseAsset)`) rather than a
///         hardcoded Chainlink oracle — so the whole system uses one price source per base asset (ETH/WETH in most
///         cases; a stablecoin for the ERC4626 vaults). Because `getPriceData` and `NAVCalculator.computeNav` go
///         through the identical feed selector in the same block, the `base/USD` term used by a derived asset's USD
///         value is exactly the one the base asset's own position legs are priced with — so it **cancels cleanly**
///         when NAV is quoted in the base (fixes the mixed-feed error where an LST used Chainlink ETH/USD while WETH
///         used API3).
/// @dev **Circularity invariant:** `baseAsset` MUST be priced by *direct* feeds (Chainlink/API3/Redstone), never by a
///      custom feed that itself calls back into the NAV — otherwise `getPriceData(baseAsset)` recurses. WETH / GNO /
///      the stablecoins all use direct feeds; never register a NAV-sourced custom feed *for* a base asset.
library NavBaseUsdLib {
    /// @notice The base asset's USD price via the NAV's selector, normalized to `NAV_DECIMALS` (8).
    /// @param nav        The NAVCalculator (proxy) to read from.
    /// @param baseAsset  The registered base asset whose USD price is wanted (e.g. WETH).
    /// @return price8    Base/USD normalized to `NAV_DECIMALS`; 0 when `stale`.
    /// @return stale     True if the NAV reports the base stale/sequencer-down, the price is non-positive, or the read
    ///                   reverts (e.g. base not registered). Fail-to-stale — never reverts the calling feed.
    /// @return updatedAt The selected base feed's `updatedAt` (for the caller's `latestRoundData` freshness); 0 on a
    ///                   revert or a rate-only base.
    function baseUsd(INAVCalculator nav, address baseAsset)
        internal
        view
        returns (uint256 price8, bool stale, uint256 updatedAt)
    {
        try nav.getPriceData(baseAsset) returns (INAVCalculator.PriceFeedData memory pd) {
            if (pd.stale || pd.price <= 0) return (0, true, pd.updatedAt);
            uint256 raw = uint256(pd.price);
            if (pd.decimals == NAV_DECIMALS) {
                price8 = raw;
            } else if (pd.decimals > NAV_DECIMALS) {
                price8 = raw / (10 ** (uint256(pd.decimals) - NAV_DECIMALS));
            } else {
                price8 = raw * (10 ** (NAV_DECIMALS - uint256(pd.decimals)));
            }
            if (price8 == 0) return (0, true, pd.updatedAt);
            return (price8, false, pd.updatedAt);
        } catch {
            return (0, true, 0);
        }
    }
}
