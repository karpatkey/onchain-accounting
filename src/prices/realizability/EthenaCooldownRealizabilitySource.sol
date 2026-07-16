// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {RealizabilityBaseline} from "./RealizabilityBaseline.sol";

interface IStakedUSDeCooldown {
    /// @notice Seconds a redeemer must wait after starting a cooldown before assets are claimable. 0 = instant.
    function cooldownDuration() external view returns (uint24);
}

/// @title EthenaCooldownRealizabilitySource
/// @notice Realizability source for Ethena sUSDe (and USDe positions routed through it): the expected redemption
///         time is the live `cooldownDuration()`. When the protocol sets `cooldownDuration == 0`, redemptions are
///         instant.
/// @dev Withdrawals are always enabled (staked USDe can always start a cooldown); the signal that matters is the
///      cooldown length vs the per-asset limit.
/// @author KPK
contract EthenaCooldownRealizabilitySource is RealizabilityBaseline {
    /// @notice The StakedUSDeV2 contract exposing `cooldownDuration()`.
    address public immutable STAKED_USDE;

    /// @param stakedUSDe The StakedUSDeV2 (sUSDe) contract — also the asset this source is pinned to.
    constructor(address stakedUSDe) RealizabilityBaseline(stakedUSDe) {
        STAKED_USDE = stakedUSDe;
    }

    /// @notice Current redemption status for the pinned asset (see IRealizabilitySource).
    function realizability()
        external
        view
        override
        returns (bool withdrawalsEnabled, uint256 expectedRedemptionSeconds, bool healthy)
    {
        withdrawalsEnabled = true;
        healthy = true;
        expectedRedemptionSeconds = uint256(IStakedUSDeCooldown(STAKED_USDE).cooldownDuration());
    }
}
