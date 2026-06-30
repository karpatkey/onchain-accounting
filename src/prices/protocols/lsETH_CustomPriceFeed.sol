// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {CrossRateCustomPriceFeed} from "src/prices/protocols/CrossRateCustomPriceFeed.sol";

/// @title lsETH Custom Price Oracle
/// @notice Returns the USD price of lsETH as `(lsETH/ETH) × (ETH/USD)` from two Chainlink feeds.
/// @dev Thin {CrossRateCustomPriceFeed} subclass — the cross-rate compose/staleness math lives in the base; this
///      only pins lsETH's feeds and gives the deployment its own named contract.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract lsETH_CustomPriceFeed is CrossRateCustomPriceFeed {
    /// @param lsEth_ The lsETH token address.
    /// @param lsEthToEthFeed_ The lsETH/ETH Chainlink feed (rate).
    /// @param ethToUsdFeed_ The ETH/USD Chainlink feed.
    /// @param lsEthToEthHeartbeat_ Staleness threshold (seconds) for the lsETH/ETH feed.
    /// @param ethToUsdHeartbeat_ Staleness threshold (seconds) for the ETH/USD feed.
    constructor(
        address lsEth_,
        address lsEthToEthFeed_,
        address ethToUsdFeed_,
        uint256 lsEthToEthHeartbeat_,
        uint256 ethToUsdHeartbeat_
    ) CrossRateCustomPriceFeed(lsEth_, lsEthToEthFeed_, ethToUsdFeed_, lsEthToEthHeartbeat_, ethToUsdHeartbeat_) {}
}
