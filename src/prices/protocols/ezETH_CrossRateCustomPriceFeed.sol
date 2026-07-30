// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {CrossRateCustomPriceFeed} from "src/prices/protocols/CrossRateCustomPriceFeed.sol";

/// @title ezETH Cross-Rate Custom Price Oracle
/// @notice Returns the USD price of ezETH as `(ezETH/ETH) × (ETH/USD)`, the rate from a Chainlink-ABI feed and the
///         `ETH/USD` leg from the NAV's own selector (ADR 0019).
/// @dev Thin {CrossRateCustomPriceFeed} subclass — the cross-rate compose/staleness math lives in the base; this
///      only pins ezETH's feeds and gives the deployment its own named contract.
///
///      **Registered as a `monitorFeed`, NOT as a price feed.** It never prices the NAV: monitors are read only to
///      compute `divergenceBps` against the primary {ezETH_CustomPriceFeed} (Renzo `RestakeManager` rate), which
///      carries a 250 bps divergence tolerance. PR #151 replaced freshest-wins redundancy for this instance with the
///      primary-plus-monitors model, so this feed is not a fallback source and cannot win a selection.
///
///      **The `ezETH/ETH` rate leg is itself FUNDAMENTAL, not a market quote.** It was migrated on 2026-07-22 to
///      RedStone's multi-feed `ezETH_FUNDAMENTAL` feed (`0x701e83Bd…`, 8-dec) after RedStone sunset the Classic Push
///      ezETH/ETH market feed it previously used. The source is independent of the primary (RedStone's rate vs
///      Renzo's), but the *methodology* is not — so this monitor compares one fundamental rate against another and
///      cannot detect a market depeg of ezETH. Tracked as a known open gap; see the audit note in
///      `custom-price-feeds/1.json`. Restoring market-depeg detection needs a market-priced ezETH source.
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
