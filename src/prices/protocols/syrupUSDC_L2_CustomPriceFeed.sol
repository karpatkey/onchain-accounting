// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TwoFeedChainlinkPriceFeed} from "src/prices/TwoFeedChainlinkPriceFeed.sol";

/// @title syrupUSDC L2 Custom Price Oracle
/// @notice Returns the USD price of syrupUSDC on L2 as `(syrupUSDC/USDC) × (USDC/USD)` from a Chainlink
///         syrupUSDC/USDC feed and the NAV's USDC/USD price.
/// @dev Thin {TwoFeedChainlinkPriceFeed} subclass — the compose/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the syrupUSDC/USDC feed + its heartbeat, and the NAV and base asset.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract syrupUSDC_L2_CustomPriceFeed is TwoFeedChainlinkPriceFeed {
    /// @param syrupUsdc_ The syrupUSDC token address.
    /// @param syrupUsdcToUsdcChainlink_ The syrupUSDC/USDC Chainlink feed.
    /// @param syrupUsdcToUsdcHeartbeat_ Staleness threshold (seconds) for the syrupUSDC/USDC feed.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. USDC) whose NAV-selected USD price scales the rate.
    constructor(
        address syrupUsdc_,
        address syrupUsdcToUsdcChainlink_,
        uint256 syrupUsdcToUsdcHeartbeat_,
        address nav_,
        address baseAsset_
    ) TwoFeedChainlinkPriceFeed(syrupUsdc_, syrupUsdcToUsdcChainlink_, syrupUsdcToUsdcHeartbeat_, nav_, baseAsset_) {}
}
