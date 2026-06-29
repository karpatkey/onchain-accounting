// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TwoFeedChainlinkPriceFeed} from "src/prices/TwoFeedChainlinkPriceFeed.sol";

/// @title syrupUSDC L2 Custom Price Oracle
/// @notice Returns the USD price of syrupUSDC on L2 as `(syrupUSDC/USDC) × (USDC/USD)` from two Chainlink feeds.
/// @dev Thin {TwoFeedChainlinkPriceFeed} subclass — the dual-feed compose/staleness math and `ICustomPriceFeed`
///      surface live in the base; this only pins the syrupUSDC/USDC feed, the USDC/USD feed, and their heartbeats.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract syrupUSDC_L2_CustomPriceFeed is TwoFeedChainlinkPriceFeed {
    /// @param syrupUsdc_ The syrupUSDC token address.
    /// @param syrupUsdcToUsdcChainlink_ The syrupUSDC/USDC Chainlink feed.
    /// @param usdcToUsdChainlinkOracle_ The USDC/USD Chainlink feed.
    /// @param syrupUsdcToUsdcHeartbeat_ Staleness threshold (seconds) for the syrupUSDC/USDC feed.
    /// @param usdcToUsdChainlinkHeartbeat_ Staleness threshold (seconds) for the USDC/USD feed.
    constructor(
        address syrupUsdc_,
        address syrupUsdcToUsdcChainlink_,
        address usdcToUsdChainlinkOracle_,
        uint256 syrupUsdcToUsdcHeartbeat_,
        uint256 usdcToUsdChainlinkHeartbeat_
    )
        TwoFeedChainlinkPriceFeed(
            syrupUsdc_,
            syrupUsdcToUsdcChainlink_,
            usdcToUsdChainlinkOracle_,
            syrupUsdcToUsdcHeartbeat_,
            usdcToUsdChainlinkHeartbeat_
        )
    {}
}
