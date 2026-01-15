// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Types} from "@optimism/libraries/Types.sol";

/// @title IOptimismPortal Interface
/// @notice Interface for Optimism Portal (used for proving and finalizing withdrawals)
/// @dev Used for the two-step withdrawal process from L2 to L1
interface IOptimismPortal {
    /// @notice Proves a withdrawal transaction
    /// @param _tx Withdrawal transaction to prove
    /// @param _l2OutputIndex Index of the L2 output
    /// @param _outputRootProof Proof of the L2 output root
    /// @param _withdrawalProof Proof of the withdrawal
    function proveWithdrawalTransaction(
        Types.WithdrawalTransaction memory _tx,
        uint256 _l2OutputIndex,
        Types.OutputRootProof memory _outputRootProof,
        bytes[] calldata _withdrawalProof
    ) external;

    /// @notice Finalizes a withdrawal transaction
    /// @param _tx Withdrawal transaction to finalize
    function finalizeWithdrawalTransaction(Types.WithdrawalTransaction memory _tx) external;

    /// @notice Checks if a withdrawal transaction has been proven
    /// @param _withdrawalHash Hash of the withdrawal transaction
    /// @return True if proven, false otherwise
    function provenWithdrawals(bytes32 _withdrawalHash) external view returns (bool);

    /// @notice Gets the minimum time between proving and finalizing a withdrawal
    /// @return The minimum time in seconds
    function minimumWithdrawalDelay() external view returns (uint256);
}
