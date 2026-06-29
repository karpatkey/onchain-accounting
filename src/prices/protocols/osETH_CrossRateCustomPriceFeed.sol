// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {CrossRateCustomPriceFeed} from "src/prices/protocols/CrossRateCustomPriceFeed.sol";

/// @title osETH Cross-Rate Custom Price Oracle
/// @notice Returns the USD price of osETH as `(osETH/ETH) × (ETH/USD)` from two Chainlink-ABI feeds.
/// @dev Thin {CrossRateCustomPriceFeed} subclass — the cross-rate compose/staleness math lives in the base; this
///      only pins osETH's feeds and gives the deployment its own named contract. This is the **redundancy** feed for
///      osETH: registered alongside the primary osToken feed (StakeWise `osTokenVaultController` rate × ETH/USD) and
///      independent of it — the `osETH/ETH` rate here comes from a Redstone Classic Push market feed, not from
///      StakeWise's on-chain rate — so `Prices`'s freshest-wins selector has a genuinely separate source to fall back to.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract osETH_CrossRateCustomPriceFeed is CrossRateCustomPriceFeed {
    /// @param osEth_ The osETH token address.
    /// @param osEthToEthFeed_ The osETH/ETH feed (rate; Redstone Classic Push proxy, Chainlink ABI).
    /// @param ethToUsdFeed_ The ETH/USD Chainlink feed.
    /// @param osEthToEthHeartbeat_ Staleness threshold (seconds) for the osETH/ETH feed.
    /// @param ethToUsdHeartbeat_ Staleness threshold (seconds) for the ETH/USD feed.
    constructor(
        address osEth_,
        address osEthToEthFeed_,
        address ethToUsdFeed_,
        uint256 osEthToEthHeartbeat_,
        uint256 ethToUsdHeartbeat_
    ) CrossRateCustomPriceFeed(osEth_, osEthToEthFeed_, ethToUsdFeed_, osEthToEthHeartbeat_, ethToUsdHeartbeat_) {}
}
