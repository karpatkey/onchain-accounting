// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title Across Protocol Interfaces
/// @notice Aggregated interfaces for Across Protocol SpokePool integration
/// @author kpk

// ============================================================================
// Across Receiver Interface
// ============================================================================

/// @title IAcrossReceiver Interface
/// @notice Interface for contracts that receive messages from Across Protocol
/// @dev Implemented by recipient contracts on destination chain
interface IAcrossReceiver {
    /// @notice Handles a message received from Across Protocol
    /// @param tokenSent The token address that was sent
    /// @param amount The amount of tokens sent
    /// @param fillCompleted Whether the fill was completed
    /// @param relayer The address of the relayer that filled the deposit
    /// @param message The message payload (contains messagePayload)
    function handleAcrossMessage(
        address tokenSent,
        uint256 amount,
        bool fillCompleted,
        address relayer,
        bytes memory message
    ) external;
}

// ============================================================================
// Across SpokePool Interface
// ============================================================================

/// @title ISpokePool Interface
/// @notice Interface for Across Protocol SpokePool contract
/// @dev Used for depositing tokens and messages across chains
interface ISpokePool {
    /// @notice Deposits tokens to be bridged to another chain
    /// @param recipient Address on destination chain to receive tokens
    /// @param originToken Token address on source chain
    /// @param amount Amount of tokens to bridge
    /// @param destinationChainId Destination chain ID
    /// @param relayerFeePct Relayer fee percentage (in 1e18, e.g., 0.01e18 = 1%)
    /// @param quoteTimestamp Timestamp for quote (usually block.timestamp)
    /// @param message Message payload to send to recipient (contains messagePayload)
    /// @param maxCount Maximum number of fills (usually type(uint256).max)
    function deposit(
        address recipient,
        address originToken,
        uint256 amount,
        uint256 destinationChainId,
        int64 relayerFeePct,
        uint32 quoteTimestamp,
        bytes memory message,
        uint256 maxCount
    ) external payable;

    /// @notice Event emitted when a deposit is made
    event FundsDeposited(
        uint256 amount,
        uint256 originChainId,
        uint256 destinationChainId,
        int64 relayerFeePct,
        uint32 depositId,
        uint32 quoteTimestamp,
        address originToken,
        address recipient,
        address depositor,
        bytes message
    );

    /// @notice Event emitted when a deposit is filled by a relayer
    event FilledRelay(
        uint256 amount,
        uint256 totalFilledAmount,
        uint256 fillAmount,
        uint256 destinationChainId,
        uint256 originChainId,
        int64 relayerFeePct,
        uint32 depositId,
        address destinationToken,
        address relayer,
        address depositor,
        address recipient,
        bytes message,
        int256 repaymentChainId
    );
}
