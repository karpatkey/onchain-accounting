// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {TwoFeedChainlinkPriceFeed} from "src/prices/TwoFeedChainlinkPriceFeed.sol";

/// @title LDO Custom Price Oracle
/// @notice Returns the USD price of LDO as `(LDO/ETH) × (ETH/USD)` from a Chainlink LDO/ETH feed and the NAV's
///         ETH/USD price.
/// @dev Thin {TwoFeedChainlinkPriceFeed} subclass — the compose/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the LDO/ETH feed + its heartbeat, and the NAV and base asset.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract LDO_CustomPriceFeed is TwoFeedChainlinkPriceFeed {
    /// @param ldo_ The LDO token address.
    /// @param ldoToEthChainlinkAddress_ The LDO/ETH Chainlink feed.
    /// @param ldoToEthChainlinkHeartbeat_ Staleness threshold (seconds) for the LDO/ETH feed.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(
        address ldo_,
        address ldoToEthChainlinkAddress_,
        uint256 ldoToEthChainlinkHeartbeat_,
        address nav_,
        address baseAsset_
    ) TwoFeedChainlinkPriceFeed(ldo_, ldoToEthChainlinkAddress_, ldoToEthChainlinkHeartbeat_, nav_, baseAsset_) {}
}
