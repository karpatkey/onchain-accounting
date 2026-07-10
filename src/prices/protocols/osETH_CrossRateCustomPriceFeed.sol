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
    /// @param osEthToEthHeartbeat_ Staleness threshold (seconds) for the osETH/ETH feed.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(address osEth_, address osEthToEthFeed_, uint256 osEthToEthHeartbeat_, address nav_, address baseAsset_)
        CrossRateCustomPriceFeed(osEth_, osEthToEthFeed_, osEthToEthHeartbeat_, nav_, baseAsset_)
    {}
}
