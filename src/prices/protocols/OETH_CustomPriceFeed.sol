// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {CrossRateCustomPriceFeed} from "src/prices/protocols/CrossRateCustomPriceFeed.sol";

/// @title OETH Custom Price Oracle
/// @notice Returns the USD price of OETH as `(OETH/ETH) × (ETH/USD)` from two Chainlink feeds.
/// @dev Thin {CrossRateCustomPriceFeed} subclass — the cross-rate compose/staleness math lives in the base; this
///      only pins OETH's feeds and gives the deployment its own named contract.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract OETH_CustomPriceFeed is CrossRateCustomPriceFeed {
    /// @param oeth_ The OETH token address.
    /// @param oethToEthFeed_ The OETH/ETH Chainlink feed (rate).
    /// @param ethToUsdFeed_ The ETH/USD Chainlink feed.
    /// @param oethToEthHeartbeat_ Staleness threshold (seconds) for the OETH/ETH feed.
    /// @param ethToUsdHeartbeat_ Staleness threshold (seconds) for the ETH/USD feed.
    constructor(
        address oeth_,
        address oethToEthFeed_,
        address ethToUsdFeed_,
        uint256 oethToEthHeartbeat_,
        uint256 ethToUsdHeartbeat_
    ) CrossRateCustomPriceFeed(oeth_, oethToEthFeed_, ethToUsdFeed_, oethToEthHeartbeat_, ethToUsdHeartbeat_) {}
}
