// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TwoFeedChainlinkPriceFeed} from "src/prices/TwoFeedChainlinkPriceFeed.sol";

/// @title wstETH L2 Custom Price Oracle
/// @notice Returns the USD price of wstETH on L2 as `(wstETH/ETH) × (ETH/USD)` from two Chainlink feeds (the
///         L2 wstETH/ETH exchange-rate feed composed with ETH/USD).
/// @dev Thin {TwoFeedChainlinkPriceFeed} subclass — the dual-feed compose/staleness math and `ICustomPriceFeed`
///      surface live in the base; this only pins the wstETH/ETH feed, the ETH/USD feed, and their heartbeats.
///      (The mainnet `wstETH_CustomPriceFeed` is bespoke — it reads `stEthPerToken` on-chain — and is unaffected.)
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract wstETH_L2_CustomPriceFeed is TwoFeedChainlinkPriceFeed {
    /// @param wstEth_ The wstETH token address.
    /// @param wstEthToEthChainlink_ The wstETH/ETH Chainlink feed.
    /// @param ethToUsdChainlinkOracle_ The ETH/USD Chainlink feed.
    /// @param wstEthToEthHeartbeat_ Staleness threshold (seconds) for the wstETH/ETH feed.
    /// @param ethToUsdChainlinkHeartbeat_ Staleness threshold (seconds) for the ETH/USD feed.
    constructor(
        address wstEth_,
        address wstEthToEthChainlink_,
        address ethToUsdChainlinkOracle_,
        uint256 wstEthToEthHeartbeat_,
        uint256 ethToUsdChainlinkHeartbeat_
    )
        TwoFeedChainlinkPriceFeed(
            wstEth_, wstEthToEthChainlink_, ethToUsdChainlinkOracle_, wstEthToEthHeartbeat_, ethToUsdChainlinkHeartbeat_
        )
    {}
}
