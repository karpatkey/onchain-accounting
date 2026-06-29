// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {TwoFeedChainlinkPriceFeed} from "src/prices/TwoFeedChainlinkPriceFeed.sol";

/// @title Cross-Rate Price Adapter
/// @notice Computes Y/USD from a Chainlink Y/X (rate) feed and an X/USD feed: `price = (Y/X) × (X/USD)`. Use when
///         no direct Y/USD feed exists; the base asset X has a USD feed and Y is quoted in X.
/// @dev Thin {TwoFeedChainlinkPriceFeed} subclass. Constructor argument order matches every other two-feed feed —
///      `(asset, rateFeed, usdFeed, rateHeartbeat, usdHeartbeat)` — i.e. the Y/X (rate) feed first, then X/USD.
/// @author KPK
contract CrossRateCustomPriceFeed is TwoFeedChainlinkPriceFeed {
    /// @param underlyingAsset_ The asset whose USD price is returned (Y).
    /// @param yToXFeed_ Chainlink oracle for Y to X (the rate feed; its decimals scale the product).
    /// @param xToUsdFeed_ Chainlink oracle for X to USD (sets the returned price decimals).
    /// @param yToXHeartbeat_ Staleness threshold (seconds) for the Y/X feed.
    /// @param xToUsdHeartbeat_ Staleness threshold (seconds) for the X/USD feed.
    constructor(
        address underlyingAsset_,
        address yToXFeed_,
        address xToUsdFeed_,
        uint256 yToXHeartbeat_,
        uint256 xToUsdHeartbeat_
    ) TwoFeedChainlinkPriceFeed(underlyingAsset_, yToXFeed_, xToUsdFeed_, yToXHeartbeat_, xToUsdHeartbeat_) {}
}
