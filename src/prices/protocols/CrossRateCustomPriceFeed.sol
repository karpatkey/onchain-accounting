// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {TwoFeedChainlinkPriceFeed} from "src/prices/TwoFeedChainlinkPriceFeed.sol";

/// @title Cross-Rate Price Adapter
/// @notice Computes Y/USD from a Chainlink Y/X (rate) feed and the NAV's own X/USD price: `price = (Y/X) × (X/USD)`.
///         Use when no direct Y/USD feed exists; the base asset X is priced by the NAV and Y is quoted in X.
/// @dev Thin {TwoFeedChainlinkPriceFeed} subclass. Constructor argument order matches every other two-feed feed —
///      `(asset, rateFeed, rateHeartbeat, nav, baseAsset)` — i.e. the Y/X (rate) feed + its heartbeat first, then the
///      NAV and the base asset X whose USD price is sourced from the NAV.
/// @author KPK
contract CrossRateCustomPriceFeed is TwoFeedChainlinkPriceFeed {
    /// @param underlyingAsset_ The asset whose USD price is returned (Y).
    /// @param yToXFeed_ Chainlink oracle for Y to X (the rate feed; its decimals scale the product).
    /// @param yToXHeartbeat_ Staleness threshold (seconds) for the Y/X feed.
    /// @param nav_ The NAVCalculator proxy to read the base asset X's USD price from.
    /// @param baseAsset_ The base asset X whose NAV-selected USD price scales the rate.
    constructor(address underlyingAsset_, address yToXFeed_, uint256 yToXHeartbeat_, address nav_, address baseAsset_)
        TwoFeedChainlinkPriceFeed(underlyingAsset_, yToXFeed_, yToXHeartbeat_, nav_, baseAsset_)
    {}
}
