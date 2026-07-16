// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {RealizabilityBaseline} from "./RealizabilityBaseline.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";

interface IStaderUserWithdrawalManager {
    /// @notice Next request id that will be created (queue head).
    function nextRequestId() external view returns (uint256);
    /// @notice Next request id awaiting finalization (queue tail being processed).
    function nextRequestIdToFinalize() external view returns (uint256);
}

/// @title StaderRealizabilitySource
/// @notice Realizability source for Stader ETHx: confirms the withdrawal manager is reachable and the finalization
///         cursor is not ahead of the request head (a coherent, non-halted queue), and reports a constructor ETA
///         baseline scaled up when the outstanding queue is deep.
/// @dev Stader does not expose an on-chain queue ETA in seconds; the pending-request depth
///      (`nextRequestId − nextRequestIdToFinalize`) is used only to pick the normal vs congested baseline.
/// @author KPK
contract StaderRealizabilitySource is RealizabilityBaseline {
    /// @notice The Stader UserWithdrawalManager.
    address public immutable WITHDRAWAL_MANAGER;

    /// @notice Baseline ETA under a normal-depth queue.
    uint256 public immutable NORMAL_ETA_SECONDS;

    /// @notice Baseline ETA when the pending queue exceeds `congestionThreshold`.
    uint256 public immutable CONGESTED_ETA_SECONDS;

    /// @notice Pending-request count above which the congested ETA applies.
    uint256 public immutable CONGESTION_THRESHOLD;

    constructor(
        address ethx,
        address withdrawalManager,
        uint256 normalEtaSeconds,
        uint256 congestedEtaSeconds,
        uint256 congestionThreshold
    ) RealizabilityBaseline(ethx) {
        AddressCheckLib.requireContract(withdrawalManager, "StaderWithdrawalManager");
        WITHDRAWAL_MANAGER = withdrawalManager;
        NORMAL_ETA_SECONDS = normalEtaSeconds;
        CONGESTED_ETA_SECONDS = congestedEtaSeconds;
        CONGESTION_THRESHOLD = congestionThreshold;
    }

    /// @notice Current redemption status for the pinned asset (see IRealizabilitySource).
    function realizability()
        external
        view
        override
        returns (bool withdrawalsEnabled, uint256 expectedRedemptionSeconds, bool healthy)
    {
        uint256 head = IStaderUserWithdrawalManager(WITHDRAWAL_MANAGER).nextRequestId();
        uint256 finalize = IStaderUserWithdrawalManager(WITHDRAWAL_MANAGER).nextRequestIdToFinalize();
        // A coherent queue has finalize <= head; withdrawals are enabled while the manager is reachable/coherent.
        // Guard the subtraction so an incoherent queue (finalize > head) reports disabled instead of underflow-
        // reverting — the revert would otherwise be swallowed fail-open and never surface as `withdrawalsEnabled=false`.
        withdrawalsEnabled = finalize <= head;
        healthy = true;
        uint256 pending = withdrawalsEnabled ? head - finalize : 0;
        expectedRedemptionSeconds = pending > CONGESTION_THRESHOLD ? CONGESTED_ETA_SECONDS : NORMAL_ETA_SECONDS;
    }
}
