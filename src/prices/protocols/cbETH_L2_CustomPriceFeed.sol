// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TwoFeedChainlinkPriceFeed} from "src/prices/TwoFeedChainlinkPriceFeed.sol";

/// @title cbETH L2 Custom Price Oracle
/// @notice Returns the USD price of cbETH on L2 as `(cbETH/ETH) × (ETH/USD)` from two Chainlink feeds.
/// @dev Thin {TwoFeedChainlinkPriceFeed} subclass — the dual-feed compose/staleness math and `ICustomPriceFeed`
///      surface live in the base; this only pins the cbETH/ETH feed, the ETH/USD feed, and their heartbeats.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract cbETH_L2_CustomPriceFeed is TwoFeedChainlinkPriceFeed {
    /// @param cbEth_ The cbETH token address.
    /// @param cbEthToEthChainlink_ The cbETH/ETH Chainlink feed.
    /// @param ethToUsdChainlinkOracle_ The ETH/USD Chainlink feed.
    /// @param cbEthToEthHeartbeat_ Staleness threshold (seconds) for the cbETH/ETH feed.
    /// @param ethToUsdChainlinkHeartbeat_ Staleness threshold (seconds) for the ETH/USD feed.
    constructor(
        address cbEth_,
        address cbEthToEthChainlink_,
        address ethToUsdChainlinkOracle_,
        uint256 cbEthToEthHeartbeat_,
        uint256 ethToUsdChainlinkHeartbeat_
    )
        TwoFeedChainlinkPriceFeed(
            cbEth_, cbEthToEthChainlink_, ethToUsdChainlinkOracle_, cbEthToEthHeartbeat_, ethToUsdChainlinkHeartbeat_
        )
    {}
}
