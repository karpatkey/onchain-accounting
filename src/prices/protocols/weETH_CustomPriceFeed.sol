// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TwoFeedChainlinkPriceFeed} from "src/prices/TwoFeedChainlinkPriceFeed.sol";

/// @title weETH Custom Price Oracle
/// @notice Returns the USD price of weETH as `(weETH/ETH) × (ETH/USD)` from a Chainlink weETH/ETH feed and the NAV's
///         ETH/USD price.
/// @dev Thin {TwoFeedChainlinkPriceFeed} subclass — the compose/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the weETH/ETH feed + its heartbeat, and the NAV and base asset.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract weETH_CustomPriceFeed is TwoFeedChainlinkPriceFeed {
    /// @param weEth_ The weETH token address.
    /// @param weEthToEthChainlink_ The weETH/ETH Chainlink feed.
    /// @param weEthToEthHeartbeat_ Staleness threshold (seconds) for the weETH/ETH feed.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(
        address weEth_,
        address weEthToEthChainlink_,
        uint256 weEthToEthHeartbeat_,
        address nav_,
        address baseAsset_
    ) TwoFeedChainlinkPriceFeed(weEth_, weEthToEthChainlink_, weEthToEthHeartbeat_, nav_, baseAsset_) {}
}
