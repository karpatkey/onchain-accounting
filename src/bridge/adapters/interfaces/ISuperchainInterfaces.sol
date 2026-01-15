// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Types} from "@optimism/libraries/Types.sol";

/// @title Superchain (Optimism) Bridge Interfaces
/// @notice Aggregated interfaces for Optimism Superchain canonical bridge integration
/// @author kpk

// ============================================================================
// Optimism L1 Standard Bridge Interface
// ============================================================================

/// @title IL1StandardBridge Interface
/// @notice Interface for Optimism L1 Standard Bridge
/// @dev Used for bridging ETH and ERC20 tokens from L1 to L2
interface IL1StandardBridge {
    /// @notice Deposits ETH to a recipient's balance on L2
    /// @param _to Address on L2 to receive the ETH
    /// @param _l2Gas Gas limit for the L2 execution
    /// @param _data Optional data to forward to L2
    function depositETHTo(address _to, uint32 _l2Gas, bytes calldata _data) external payable;

    /// @notice Deposits an amount of ERC20 tokens to a recipient's balance on L2
    /// @param _l1Token Address of the L1 token
    /// @param _l2Token Address of the corresponding L2 token
    /// @param _to Address on L2 to receive the tokens
    /// @param _amount Amount of tokens to deposit
    /// @param _l2Gas Gas limit for the L2 execution
    /// @param _data Optional data to forward to L2
    function depositERC20To(
        address _l1Token,
        address _l2Token,
        address _to,
        uint256 _amount,
        uint32 _l2Gas,
        bytes calldata _data
    ) external;

    /// @notice Event emitted when ETH deposit is initiated
    event ETHDepositInitiated(address indexed _from, address indexed _to, uint256 _amount, bytes _data);

    /// @notice Event emitted when ERC20 deposit is initiated
    event ERC20DepositInitiated(
        address indexed _l1Token,
        address indexed _l2Token,
        address indexed _from,
        address _to,
        uint256 _amount,
        bytes _data
    );
}

// ============================================================================
// Optimism L2 Standard Bridge Interface
// ============================================================================

/// @title IL2StandardBridge Interface
/// @notice Interface for Optimism L2 Standard Bridge
/// @dev Used for bridging ETH and ERC20 tokens from L2 to L1
interface IL2StandardBridge {
    /// @notice Withdraws ETH to a recipient on L1
    /// @param _l1Gas Gas limit for the L1 execution
    /// @param _data Optional data to forward to L1
    function withdraw(uint32 _l1Gas, bytes calldata _data) external payable;

    /// @notice Withdraws ETH to a specific recipient on L1
    /// @param _to Address on L1 to receive the ETH
    /// @param _l1Gas Gas limit for the L1 execution
    /// @param _data Optional data to forward to L1
    function withdrawTo(address _to, uint32 _l1Gas, bytes calldata _data) external payable;

    /// @notice Withdraws ERC20 tokens to a recipient on L1
    /// @param _l2Token Address of the L2 token
    /// @param _amount Amount of tokens to withdraw
    /// @param _l1Gas Gas limit for the L1 execution
    /// @param _data Optional data to forward to L1
    function withdraw(address _l2Token, uint256 _amount, uint32 _l1Gas, bytes calldata _data) external payable;

    /// @notice Withdraws ERC20 tokens to a specific recipient on L1
    /// @param _l2Token Address of the L2 token
    /// @param _to Address on L1 to receive the tokens
    /// @param _amount Amount of tokens to withdraw
    /// @param _l1Gas Gas limit for the L1 execution
    /// @param _data Optional data to forward to L1
    function withdrawTo(address _l2Token, address _to, uint256 _amount, uint32 _l1Gas, bytes calldata _data)
        external
        payable;

    /// @notice Event emitted when ETH withdrawal is initiated
    event ETHWithdrawalInitiated(address indexed _from, address indexed _to, uint256 _amount, bytes _data);

    /// @notice Event emitted when ERC20 withdrawal is initiated
    event ERC20WithdrawalInitiated(
        address indexed _l1Token,
        address indexed _l2Token,
        address indexed _from,
        address _to,
        uint256 _amount,
        bytes _data
    );
}

// ============================================================================
// Optimism Portal Interface
// ============================================================================

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
