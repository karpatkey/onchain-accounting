// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TwoFeedChainlinkPriceFeed} from "src/prices/TwoFeedChainlinkPriceFeed.sol";

/// @title rsETH L2 Custom Price Oracle
/// @notice Returns the USD price of rsETH on L2 as `(rsETH/ETH) × (ETH/USD)` from two Chainlink feeds.
/// @dev Thin {TwoFeedChainlinkPriceFeed} subclass — the dual-feed compose/staleness math and `ICustomPriceFeed`
///      surface live in the base; this only pins the rsETH/ETH feed, the ETH/USD feed, and their heartbeats.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract rsETH_L2_CustomPriceFeed is TwoFeedChainlinkPriceFeed {
    /// @param rsEth_ The rsETH token address.
    /// @param rsEthToEthChainlink_ The rsETH/ETH Chainlink feed.
    /// @param ethToUsdChainlinkOracle_ The ETH/USD Chainlink feed.
    /// @param rsEthToEthHeartbeat_ Staleness threshold (seconds) for the rsETH/ETH feed.
    /// @param ethToUsdChainlinkHeartbeat_ Staleness threshold (seconds) for the ETH/USD feed.
    constructor(
        address rsEth_,
        address rsEthToEthChainlink_,
        address ethToUsdChainlinkOracle_,
        uint256 rsEthToEthHeartbeat_,
        uint256 ethToUsdChainlinkHeartbeat_
    )
        TwoFeedChainlinkPriceFeed(
            rsEth_, rsEthToEthChainlink_, ethToUsdChainlinkOracle_, rsEthToEthHeartbeat_, ethToUsdChainlinkHeartbeat_
        )
    {}
}
