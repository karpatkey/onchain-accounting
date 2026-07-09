// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {CrossRateCustomPriceFeed} from "src/prices/protocols/CrossRateCustomPriceFeed.sol";

/// @title ETHx Cross-Rate Custom Price Oracle
/// @notice Returns the USD price of ETHx as `(ETHx/ETH) × (ETH/USD)` from two Chainlink-ABI feeds.
/// @dev Thin {CrossRateCustomPriceFeed} subclass — the cross-rate compose/staleness math lives in the base; this
///      only pins ETHx's feeds and gives the deployment its own named contract. This is the **redundancy** feed for
///      ETHx: registered alongside the primary {ETHx_CustomPriceFeed} (Stader `getExchangeRate` × ETH/USD) and
///      independent of it — the `ETHx/ETH` rate here comes from a Redstone Classic Push market feed, not from Stader's
///      on-chain rate — so `Prices`'s freshest-wins selector has a genuinely separate source to fall back to.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract ETHx_CrossRateCustomPriceFeed is CrossRateCustomPriceFeed {
    /// @param ethx_ The ETHx token address.
    /// @param ethxToEthFeed_ The ETHx/ETH feed (rate; Redstone Classic Push proxy, Chainlink ABI).
    /// @param ethxToEthHeartbeat_ Staleness threshold (seconds) for the ETHx/ETH feed.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(address ethx_, address ethxToEthFeed_, uint256 ethxToEthHeartbeat_, address nav_, address baseAsset_)
        CrossRateCustomPriceFeed(ethx_, ethxToEthFeed_, ethxToEthHeartbeat_, nav_, baseAsset_)
    {}
}
