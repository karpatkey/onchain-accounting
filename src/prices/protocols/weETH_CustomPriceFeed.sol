// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TwoFeedChainlinkPriceFeed} from "src/prices/TwoFeedChainlinkPriceFeed.sol";

/// @title weETH Custom Price Oracle
/// @notice Returns the USD price of weETH as `(weETH/ETH) × (ETH/USD)` from two Chainlink feeds.
/// @dev Thin {TwoFeedChainlinkPriceFeed} subclass — the dual-feed compose/staleness math and `ICustomPriceFeed`
///      surface live in the base; this only pins the weETH/ETH feed, the ETH/USD feed, and their heartbeats.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract weETH_CustomPriceFeed is TwoFeedChainlinkPriceFeed {
    /// @param weEth_ The weETH token address.
    /// @param weEthToEthChainlink_ The weETH/ETH Chainlink feed.
    /// @param ethToUsdChainlinkOracle_ The ETH/USD Chainlink feed.
    /// @param weEthToEthHeartbeat_ Staleness threshold (seconds) for the weETH/ETH feed.
    /// @param ethToUsdChainlinkHeartbeat_ Staleness threshold (seconds) for the ETH/USD feed.
    constructor(
        address weEth_,
        address weEthToEthChainlink_,
        address ethToUsdChainlinkOracle_,
        uint256 weEthToEthHeartbeat_,
        uint256 ethToUsdChainlinkHeartbeat_
    )
        TwoFeedChainlinkPriceFeed(
            weEth_, weEthToEthChainlink_, ethToUsdChainlinkOracle_, weEthToEthHeartbeat_, ethToUsdChainlinkHeartbeat_
        )
    {}
}
