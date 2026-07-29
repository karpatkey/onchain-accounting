// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TwoFeedChainlinkPriceFeed} from "src/prices/TwoFeedChainlinkPriceFeed.sol";

/// @title cbETH L2 Custom Price Oracle
/// @notice Returns the USD price of cbETH on L2 as `(cbETH/ETH) × (ETH/USD)` from a Chainlink cbETH/ETH feed and the
///         NAV's ETH/USD price.
/// @dev Thin {TwoFeedChainlinkPriceFeed} subclass — the compose/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the cbETH/ETH feed + its heartbeat, and the NAV and base asset.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract cbETH_L2_CustomPriceFeed is TwoFeedChainlinkPriceFeed {
    /// @param cbEth_ The cbETH token address.
    /// @param cbEthToEthChainlink_ The cbETH/ETH Chainlink feed.
    /// @param cbEthToEthHeartbeat_ Staleness threshold (seconds) for the cbETH/ETH feed.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(
        address cbEth_,
        address cbEthToEthChainlink_,
        uint256 cbEthToEthHeartbeat_,
        address nav_,
        address baseAsset_
    ) TwoFeedChainlinkPriceFeed(cbEth_, cbEthToEthChainlink_, cbEthToEthHeartbeat_, nav_, baseAsset_) {}
}
