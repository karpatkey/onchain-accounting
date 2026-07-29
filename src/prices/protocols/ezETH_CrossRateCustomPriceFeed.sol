// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {CrossRateCustomPriceFeed} from "src/prices/protocols/CrossRateCustomPriceFeed.sol";

/// @title ezETH Cross-Rate Custom Price Oracle
/// @notice Returns the USD price of ezETH as `(ezETH/ETH) × (ETH/USD)` from two Chainlink-ABI feeds.
/// @dev Thin {CrossRateCustomPriceFeed} subclass — the cross-rate compose/staleness math lives in the base; this
///      only pins ezETH's feeds and gives the deployment its own named contract. This is the **redundancy** feed for
///      ezETH: it is registered alongside the primary {ezETH_CustomPriceFeed} (Renzo `RestakeManager` rate × ETH/USD)
///      and is independent of it — the `ezETH/ETH` rate here comes from a Redstone Classic Push market feed, not from
///      Renzo's on-chain rate — so `Prices`'s freshest-wins selector has a genuinely separate source to fall back to.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract ezETH_CrossRateCustomPriceFeed is CrossRateCustomPriceFeed {
    /// @param ezEth_ The ezETH token address.
    /// @param ezEthToEthFeed_ The ezETH/ETH feed (rate; Redstone Classic Push proxy, Chainlink ABI).
    /// @param ezEthToEthHeartbeat_ Staleness threshold (seconds) for the ezETH/ETH feed.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(address ezEth_, address ezEthToEthFeed_, uint256 ezEthToEthHeartbeat_, address nav_, address baseAsset_)
        CrossRateCustomPriceFeed(ezEth_, ezEthToEthFeed_, ezEthToEthHeartbeat_, nav_, baseAsset_)
    {}
}
