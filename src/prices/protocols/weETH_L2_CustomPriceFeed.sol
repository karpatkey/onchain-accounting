// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TwoFeedChainlinkPriceFeed} from "src/prices/TwoFeedChainlinkPriceFeed.sol";

/// @title weETH L2 Custom Price Oracle
/// @notice Returns the USD price of weETH on L2 as `(weETH/eETH) × (ETH/USD)` from two Chainlink feeds (the
///         weETH/eETH rate composed with ETH/USD; eETH is ~1:1 with ETH).
/// @dev Thin {TwoFeedChainlinkPriceFeed} subclass — the dual-feed compose/staleness math and `ICustomPriceFeed`
///      surface live in the base; this only pins the weETH/eETH feed, the ETH/USD feed, and their heartbeats.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract weETH_L2_CustomPriceFeed is TwoFeedChainlinkPriceFeed {
    /// @param weEth_ The weETH token address.
    /// @param weEthToEethChainlink_ The weETH/eETH Chainlink feed.
    /// @param ethToUsdChainlinkOracle_ The ETH/USD Chainlink feed.
    /// @param weEthToEethHeartbeat_ Staleness threshold (seconds) for the weETH/eETH feed.
    /// @param ethToUsdChainlinkHeartbeat_ Staleness threshold (seconds) for the ETH/USD feed.
    constructor(
        address weEth_,
        address weEthToEethChainlink_,
        address ethToUsdChainlinkOracle_,
        uint256 weEthToEethHeartbeat_,
        uint256 ethToUsdChainlinkHeartbeat_
    )
        TwoFeedChainlinkPriceFeed(
            weEth_, weEthToEethChainlink_, ethToUsdChainlinkOracle_, weEthToEethHeartbeat_, ethToUsdChainlinkHeartbeat_
        )
    {}
}
