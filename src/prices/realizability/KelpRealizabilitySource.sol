// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {RealizabilityBaseline} from "./RealizabilityBaseline.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";

interface ILRTWithdrawalManager {
    /// @notice Global withdrawal delay (in blocks) before a Kelp withdrawal request is claimable.
    function withdrawalDelayBlocks() external view returns (uint256);
}

/// @title KelpRealizabilitySource
/// @notice Realizability source for Kelp rsETH: expected redemption time = `withdrawalDelayBlocks() × secondsPerBlock`.
/// @dev Withdrawals are enabled; the ETA is the protocol's on-chain delay. `secondsPerBlock` is chain-configured
///      (12 on Ethereum L1).
/// @author KPK
contract KelpRealizabilitySource is RealizabilityBaseline {
    /// @notice The Kelp LRTWithdrawalManager exposing `withdrawalDelayBlocks()`.
    address public immutable WITHDRAWAL_MANAGER;

    /// @notice Seconds per block, used to convert the block-denominated delay to seconds.
    uint256 public immutable SECONDS_PER_BLOCK;

    /// @param rsEth The rsETH token this source is pinned to.
    /// @param withdrawalManager The Kelp LRTWithdrawalManager.
    /// @param secondsPerBlock Seconds per block (e.g. 12 on Ethereum L1).
    constructor(address rsEth, address withdrawalManager, uint256 secondsPerBlock) RealizabilityBaseline(rsEth) {
        AddressCheckLib.requireContract(withdrawalManager, "KelpWithdrawalManager");
        WITHDRAWAL_MANAGER = withdrawalManager;
        SECONDS_PER_BLOCK = secondsPerBlock;
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
        expectedRedemptionSeconds = ILRTWithdrawalManager(WITHDRAWAL_MANAGER).withdrawalDelayBlocks() * SECONDS_PER_BLOCK;
    }
}
