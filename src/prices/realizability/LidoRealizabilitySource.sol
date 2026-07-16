// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {RealizabilityBaseline} from "./RealizabilityBaseline.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";

interface ILidoWithdrawalQueue {
    /// @notice True when Lido's oracle has declared "bunker mode" (a negative-rebase/incident state that slows or
    ///         reprices withdrawals) — treated as unhealthy.
    function isBunkerModeActive() external view returns (bool);
    /// @notice True when the withdrawal queue is paused — redemptions are disabled.
    function isPaused() external view returns (bool);
}

/// @title LidoRealizabilitySource
/// @notice Realizability source for Lido stETH / wstETH: reads the withdrawal queue's pause + bunker state.
///         `withdrawalsEnabled = !paused`, `healthy = !bunkerMode`, and the ETA is a constructor baseline
///         (normal vs bunker) — the queue length in seconds is not a single on-chain view.
/// @dev One instance per priced asset (stETH and wstETH share the same withdrawal queue).
/// @author KPK
contract LidoRealizabilitySource is RealizabilityBaseline {
    /// @notice The Lido WithdrawalQueue.
    address public immutable WITHDRAWAL_QUEUE;

    /// @notice Expected redemption seconds under normal operation.
    uint256 public immutable NORMAL_ETA_SECONDS;

    /// @notice Expected redemption seconds when bunker mode is active (longer).
    uint256 public immutable BUNKER_ETA_SECONDS;

    /// @param asset The priced asset (stETH or wstETH) this source is pinned to.
    /// @param withdrawalQueue The Lido WithdrawalQueue.
    /// @param normalEtaSeconds Baseline ETA under normal operation.
    /// @param bunkerEtaSeconds Baseline ETA when bunker mode is active.
    constructor(address asset, address withdrawalQueue, uint256 normalEtaSeconds, uint256 bunkerEtaSeconds)
        RealizabilityBaseline(asset)
    {
        AddressCheckLib.requireContract(withdrawalQueue, "LidoWithdrawalQueue");
        WITHDRAWAL_QUEUE = withdrawalQueue;
        NORMAL_ETA_SECONDS = normalEtaSeconds;
        BUNKER_ETA_SECONDS = bunkerEtaSeconds;
    }

    /// @notice Current redemption status for the pinned asset (see IRealizabilitySource).
    function realizability()
        external
        view
        override
        returns (bool withdrawalsEnabled, uint256 expectedRedemptionSeconds, bool healthy)
    {
        bool bunker = ILidoWithdrawalQueue(WITHDRAWAL_QUEUE).isBunkerModeActive();
        withdrawalsEnabled = !ILidoWithdrawalQueue(WITHDRAWAL_QUEUE).isPaused();
        healthy = !bunker;
        expectedRedemptionSeconds = bunker ? BUNKER_ETA_SECONDS : NORMAL_ETA_SECONDS;
    }
}
