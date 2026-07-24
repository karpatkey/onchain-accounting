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
    /// @return stale     True if the NAV reports the base feed stale, the price is non-positive, or the read reverts
    ///                   (e.g. base not registered). Fail-to-stale — never reverts the calling feed. Note: L2
    ///                   sequencer-down alone does NOT mark the base stale here (see the sequencer note below).
    /// @return updatedAt The selected base feed's `updatedAt` (for the caller's `latestRoundData` freshness); 0 on a
    ///                   revert or a rate-only base.
    /// @dev **L2 sequencer:** `getPriceData` folds sequencer-down into `pd.stale` (`stale || sequencerDown`), but
    ///      `NAVCalculator.computeNav` prices every *direct* position at its last value and ignores the sequencer at
    ///      the per-position level — surfacing it only via the top-level `nav.sequencerDown` flag. If custom feeds
    ///      zeroed on sequencer-down, custom-priced positions would crater to $0 during an L2 outage while direct ones
    ///      stayed live — an internally inconsistent, understated NAV. So we un-fold the raw `pd.sequencerDown` and
    ///      zero only on genuine base-feed staleness, matching the direct-feed path; the `nav.sequencerDown` flag
    ///      remains the single sequencer signal for consumers.
    function baseUsd(INAVCalculator nav, address baseAsset)
        internal
        view
        returns (uint256 price8, bool stale, uint256 updatedAt)
    {
        try nav.getPriceDataNoDivergence(baseAsset) returns (INAVCalculator.PriceFeedData memory pd) {
            // Zero on genuine feed staleness or a non-positive price, but NOT on sequencer-down alone.
            bool baseStale = pd.stale && !pd.sequencerDown;
            if (baseStale || pd.price <= 0) return (0, true, pd.updatedAt);
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

    /// @notice The base leg's freshness for governing-leg reporting: the base asset's NAV-selected feed `updatedAt`
    ///         plus its configured heartbeat. Used by custom feeds' {ICustomPriceFeed-governingFeedFreshness} — the
    ///         base/USD leg is a genuine Chainlink dependency, so its `(updatedAt, heartbeat)` is a real matched pair.
    /// @dev Returns the base feed's values even when the base is stale (so a consumer can SEE the staleness); returns
    ///      `(0, 0)` only when the NAV read reverts (e.g. base not registered). The circularity invariant applies (the
    ///      base is priced by direct feeds), so `pd.chainlinkHeartbeat` is a direct feed's window, never a custom feed's.
    /// @param nav        The NAVCalculator (proxy) to read from.
    /// @param baseAsset  The registered base asset whose leg freshness is wanted (e.g. WETH).
    /// @return updatedAt The base feed's `latestRoundData` update timestamp (0 on revert or a rate-only base).
    /// @return heartbeat The base feed's configured staleness window in seconds (0 on revert).
    function baseFreshness(INAVCalculator nav, address baseAsset)
        internal
        view
        returns (uint256 updatedAt, uint256 heartbeat)
    {
        try nav.getPriceDataNoDivergence(baseAsset) returns (INAVCalculator.PriceFeedData memory pd) {
            return (pd.updatedAt, pd.chainlinkHeartbeat);
        } catch {
            return (0, 0);
        }
    }
}
