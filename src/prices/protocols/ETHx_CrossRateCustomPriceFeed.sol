// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {CrossRateCustomPriceFeed} from "src/prices/protocols/CrossRateCustomPriceFeed.sol";

/// @title ETHx Cross-Rate Custom Price Oracle
/// @notice Returns the USD price of ETHx as `(ETHx/ETH) × (ETH/USD)`, the rate from a Chainlink-ABI feed and the
///         `ETH/USD` leg from the NAV's own selector (ADR 0019).
/// @dev Thin {CrossRateCustomPriceFeed} subclass — the cross-rate compose/staleness math lives in the base; this
///      only pins ETHx's feeds and gives the deployment its own named contract.
///
///      **Registered as a `monitorFeed`, NOT as a price feed.** It never prices the NAV: monitors are read only to
///      compute `divergenceBps` against the primary {ETHx_CustomPriceFeed} (Stader `getExchangeRate`), which carries
///      a 250 bps divergence tolerance. PR #151 replaced freshest-wins redundancy for this instance with the
///      primary-plus-monitors model, so this feed is not a fallback source and cannot win a selection.
///
///      **The `ETHx/ETH` rate leg is CHAINLINK, not RedStone.** It was migrated on 2026-07-27 from the Redstone
///      Classic Push ETHx/ETH feed to Chainlink's ETHx/ETH feed (`0xC499ec76…`, `description() == "ETHx / ETH"`,
///      18-dec) because RedStone is sunsetting all its ETHx feeds. There is no Chainlink ETHx/USD feed, so the
///      ETH-quoted cross-rate is the only Chainlink route. The 18 decimals need no config change — the base captures
///      `10 ** RATE_FEED.decimals()` in its constructor, so the rate decimals cancel into `NAV_DECIMALS`. This is a
///      genuine market quote, independent of Stader's on-chain rate in both source and methodology.
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
