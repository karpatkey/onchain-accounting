// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title IBridgeAdapter Interface
/// @notice Interface for bridge adapter implementations
/// @author kpk
interface IBridgeAdapter {
    /// @notice Initiates a bridge operation
    /// @param invoiceId The invoice ID from BridgeEscrow
    /// @param bridgeData Encoded BridgeParams (asset, amount, destinationChainId, recipient, messagePayload)
    function bridge(bytes32 invoiceId, bytes calldata bridgeData) external;

    /// @notice Completes a bridge operation on destination chain
    /// @param invoiceId The invoice ID for the destination (can be extracted from bridgeData if adapter supports it)
    /// @param portfolioSafe The portfolio safe address (needed for releaseByInvoiceId)
    /// @param amount The amount received (needed for releaseByInvoiceId)
    /// @param bridgeData Encoded CompletionParams (messagePayload, protocolData)
    function completeBridge(
        bytes32 invoiceId,
        address portfolioSafe,
        uint256 amount,
        bytes calldata bridgeData
    ) external;

    /// @notice Returns the bridge provider name (e.g., "CCTP", "Gnosis")
    /// @return The bridge provider name
    function bridgeProvider() external view returns (string memory);

    /// @notice Returns the bridge adapter version
    /// @return The adapter version
    function version() external view returns (string memory);
}

