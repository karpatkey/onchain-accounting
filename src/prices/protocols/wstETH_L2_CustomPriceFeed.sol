// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TwoFeedChainlinkPriceFeed} from "src/prices/TwoFeedChainlinkPriceFeed.sol";

/// @title wstETH L2 Custom Price Oracle
/// @notice Returns the USD price of wstETH on L2 as `(wstETH/ETH) × (ETH/USD)` from a Chainlink wstETH/ETH
///         exchange-rate feed and the NAV's ETH/USD price.
/// @dev Thin {TwoFeedChainlinkPriceFeed} subclass — the compose/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the wstETH/ETH feed + its heartbeat, and the NAV and base asset.
///      (The mainnet `wstETH_CustomPriceFeed` is bespoke — it reads `stEthPerToken` on-chain — and is unaffected.)
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract wstETH_L2_CustomPriceFeed is TwoFeedChainlinkPriceFeed {
    /// @param wstEth_ The wstETH token address.
    /// @param wstEthToEthChainlink_ The wstETH/ETH Chainlink feed.
    /// @param wstEthToEthHeartbeat_ Staleness threshold (seconds) for the wstETH/ETH feed.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(
        address wstEth_,
        address wstEthToEthChainlink_,
        uint256 wstEthToEthHeartbeat_,
        address nav_,
        address baseAsset_
    ) TwoFeedChainlinkPriceFeed(wstEth_, wstEthToEthChainlink_, wstEthToEthHeartbeat_, nav_, baseAsset_) {}
}
