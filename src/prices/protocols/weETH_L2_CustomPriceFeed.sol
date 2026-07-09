// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TwoFeedChainlinkPriceFeed} from "src/prices/TwoFeedChainlinkPriceFeed.sol";

/// @title weETH L2 Custom Price Oracle
/// @notice Returns the USD price of weETH on L2 as `(weETH/eETH) × (ETH/USD)` from a Chainlink weETH/eETH feed and the
///         NAV's ETH/USD price (eETH is ~1:1 with ETH).
/// @dev Thin {TwoFeedChainlinkPriceFeed} subclass — the compose/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the weETH/eETH feed + its heartbeat, and the NAV and base asset.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract weETH_L2_CustomPriceFeed is TwoFeedChainlinkPriceFeed {
    /// @param weEth_ The weETH token address.
    /// @param weEthToEethChainlink_ The weETH/eETH Chainlink feed.
    /// @param weEthToEethHeartbeat_ Staleness threshold (seconds) for the weETH/eETH feed.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(
        address weEth_,
        address weEthToEethChainlink_,
        uint256 weEthToEethHeartbeat_,
        address nav_,
        address baseAsset_
    ) TwoFeedChainlinkPriceFeed(weEth_, weEthToEethChainlink_, weEthToEethHeartbeat_, nav_, baseAsset_) {}
}
