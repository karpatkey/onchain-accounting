// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TwoFeedChainlinkPriceFeed} from "src/prices/TwoFeedChainlinkPriceFeed.sol";

/// @title rsETH L2 Custom Price Oracle
/// @notice Returns the USD price of rsETH on L2 as `(rsETH/ETH) × (ETH/USD)` from a Chainlink rsETH/ETH feed and the
///         NAV's ETH/USD price.
/// @dev Thin {TwoFeedChainlinkPriceFeed} subclass — the compose/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the rsETH/ETH feed + its heartbeat, and the NAV and base asset.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract rsETH_L2_CustomPriceFeed is TwoFeedChainlinkPriceFeed {
    /// @param rsEth_ The rsETH token address.
    /// @param rsEthToEthChainlink_ The rsETH/ETH Chainlink feed.
    /// @param rsEthToEthHeartbeat_ Staleness threshold (seconds) for the rsETH/ETH feed.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(
        address rsEth_,
        address rsEthToEthChainlink_,
        uint256 rsEthToEthHeartbeat_,
        address nav_,
        address baseAsset_
    ) TwoFeedChainlinkPriceFeed(rsEth_, rsEthToEthChainlink_, rsEthToEthHeartbeat_, nav_, baseAsset_) {}
}
