// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {CrossRateCustomPriceFeed} from "src/prices/protocols/CrossRateCustomPriceFeed.sol";

/// @title stETH Custom Price Oracle
/// @notice Returns the USD price of stETH as `(stETH/ETH) × (ETH/USD)` from two Chainlink feeds.
/// @dev Thin {CrossRateCustomPriceFeed} subclass — the cross-rate compose/staleness math lives in the base; this
///      only pins stETH's feeds and gives the deployment its own named contract.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract stETH_CustomPriceFeed is CrossRateCustomPriceFeed {
    /// @param stEth_ The stETH token address.
    /// @param stEthToEthFeed_ The stETH/ETH Chainlink feed (rate).
    /// @param ethToUsdFeed_ The ETH/USD Chainlink feed.
    /// @param stEthToEthHeartbeat_ Staleness threshold (seconds) for the stETH/ETH feed.
    /// @param ethToUsdHeartbeat_ Staleness threshold (seconds) for the ETH/USD feed.
    constructor(
        address stEth_,
        address stEthToEthFeed_,
        address ethToUsdFeed_,
        uint256 stEthToEthHeartbeat_,
        uint256 ethToUsdHeartbeat_
    ) CrossRateCustomPriceFeed(stEth_, stEthToEthFeed_, ethToUsdFeed_, stEthToEthHeartbeat_, ethToUsdHeartbeat_) {}
}
