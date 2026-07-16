// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {RealizabilityBaseline} from "./RealizabilityBaseline.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";

interface IrETHCollateral {
    /// @notice ETH currently available in the rETH contract for instant burns.
    function getTotalCollateral() external view returns (uint256);
}

/// @title RocketPoolRealizabilitySource
/// @notice Realizability source for Rocket Pool rETH: redemptions are always enabled; when the rETH contract holds
///         instant-burn collateral, redemption is ~instant, otherwise it waits on the deposit pool (baseline ETA).
/// @dev `getTotalCollateral()` is the on-chain instant-burn liquidity; below `minCollateral` the deposit-pool wait
///      applies (a constructor baseline, since the exact refill time is not on-chain).
/// @author KPK
contract RocketPoolRealizabilitySource is RealizabilityBaseline {
    /// @notice Minimum instant-burn collateral (wei) for redemption to count as instant.
    uint256 public immutable MIN_COLLATERAL;

    /// @notice Baseline ETA when instant-burn collateral is insufficient (deposit-pool wait).
    uint256 public immutable WAIT_ETA_SECONDS;

    /// @param rEth The rETH token this source is pinned to (read it back via `UNDERLYING`).
    /// @param minCollateral Minimum instant-burn collateral for redemption to be considered instant.
    /// @param waitEtaSeconds Baseline ETA when collateral is below `minCollateral`.
    constructor(address rEth, uint256 minCollateral, uint256 waitEtaSeconds) RealizabilityBaseline(rEth) {
        MIN_COLLATERAL = minCollateral;
        WAIT_ETA_SECONDS = waitEtaSeconds;
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
        expectedRedemptionSeconds =
            IrETHCollateral(UNDERLYING).getTotalCollateral() >= MIN_COLLATERAL ? 0 : WAIT_ETA_SECONDS;
    }
}
