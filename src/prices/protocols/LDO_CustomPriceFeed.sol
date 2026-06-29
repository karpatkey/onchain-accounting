// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {TwoFeedChainlinkPriceFeed} from "src/prices/TwoFeedChainlinkPriceFeed.sol";

/// @title LDO Custom Price Oracle
/// @notice Returns the USD price of LDO as `(LDO/ETH) × (ETH/USD)` from two Chainlink feeds.
/// @dev Thin {TwoFeedChainlinkPriceFeed} subclass — the dual-feed compose/staleness math and `ICustomPriceFeed`
///      surface live in the base; this only pins the LDO/ETH feed, the ETH/USD feed, and their heartbeats.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract LDO_CustomPriceFeed is TwoFeedChainlinkPriceFeed {
    /// @param ldo_ The LDO token address.
    /// @param ldoToEthChainlinkAddress_ The LDO/ETH Chainlink feed.
    /// @param ethToUsdChainlinkAddress_ The ETH/USD Chainlink feed.
    /// @param ldoToEthChainlinkHeartbeat_ Staleness threshold (seconds) for the LDO/ETH feed.
    /// @param ethToUsdChainlinkHeartbeat_ Staleness threshold (seconds) for the ETH/USD feed.
    constructor(
        address ldo_,
        address ldoToEthChainlinkAddress_,
        address ethToUsdChainlinkAddress_,
        uint256 ldoToEthChainlinkHeartbeat_,
        uint256 ethToUsdChainlinkHeartbeat_
    )
        TwoFeedChainlinkPriceFeed(
            ldo_, ldoToEthChainlinkAddress_, ethToUsdChainlinkAddress_, ldoToEthChainlinkHeartbeat_, ethToUsdChainlinkHeartbeat_
        )
    {}
}
