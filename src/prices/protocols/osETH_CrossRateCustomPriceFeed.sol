// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {CrossRateCustomPriceFeed} from "src/prices/protocols/CrossRateCustomPriceFeed.sol";

/// @title osETH Cross-Rate Custom Price Oracle
/// @notice Returns the USD price of osETH as `(osETH/ETH) × (ETH/USD)`, the rate from a Chainlink-ABI feed and the
///         `ETH/USD` leg from the NAV's own selector (ADR 0019).
/// @dev Thin {CrossRateCustomPriceFeed} subclass — the cross-rate compose/staleness math lives in the base; this
///      only pins osETH's feeds and gives the deployment its own named contract.
///
///      **Registered as a `monitorFeed`, NOT as a price feed.** It never prices the NAV: monitors are read only to
///      compute `divergenceBps` against the primary osToken feed (StakeWise `osTokenVaultController` rate), which
///      carries a 250 bps divergence tolerance. PR #151 replaced freshest-wins redundancy for this instance with the
///      primary-plus-monitors model, so this feed is not a fallback source and cannot win a selection.
///
///      The `osETH/ETH` rate leg is the Redstone Classic Push osETH/ETH **market** feed (`0x66ac817f…`, verified at
///      99.34% of the StakeWise `osTokenVaultController` rate) — independent of the primary in both source and
///      methodology, so unlike ezETH's monitor this one can register a market depeg.
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
