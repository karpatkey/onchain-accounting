// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title IBridgeAdapter Interface
/// @notice Interface for bridge adapter implementations
/// @author kpk
interface IBridgeAdapter {
    //
    // Events
    //

    /// @notice Event emitted when a bridge is initiated
    event BridgeInitiated(bytes32 indexed invoiceId, uint256 amount);

    /// @notice Event emitted when a bridge is completed
    event BridgeCompleted(bytes32 indexed invoiceId);

    //
    // Functions
    //

    /// @notice Initiates a bridge operation
    /// @param messagePayload Encoded payload from BridgeEscrow (exactly 3 slots: invoiceId, amount, meta)
    /// @dev Adapter should decode messagePayload to extract invoiceId, amount, and derive other needed data
    function bridge(bytes calldata messagePayload) external;

    /// @notice Completes a bridge operation on destination chain
    /// @param messagePayload The message payload (exactly 3 slots: invoiceId, amount, meta)
    /// @param protocolData Bridge-specific protocol data (e.g., CCTP message+attestation, CCIP Any2EVMMessage)
    /// @dev Extracts invoiceId and checksum from messagePayload and calls BridgeEscrow.releaseByInvoiceId()
    function completeBridge(bytes calldata messagePayload, bytes calldata protocolData) external;

    /// @notice Returns the bridge provider name (e.g., "CCTP", "Gnosis")
    /// @return The bridge provider name
    function bridgeProvider() external view returns (string memory);

    /// @notice Returns the bridge adapter version
    /// @return The adapter version
    function version() external view returns (string memory);
}

