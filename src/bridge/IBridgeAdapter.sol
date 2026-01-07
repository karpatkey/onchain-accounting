// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title IBridgeAdapter Interface
/// @notice Interface for bridge adapter implementations
/// @author kpk
interface IBridgeAdapter {
    /// @notice Initiates a bridge operation
    /// @param invoiceId The invoice ID from BridgeEscrow
    /// @param asset The token address (address(0) for native)
    /// @param amount The amount to bridge
    /// @param bridgeData Bridge-specific data (encoded parameters)
    function bridge(bytes32 invoiceId, address asset, uint256 amount, bytes calldata bridgeData) external;

    /// @notice Completes a bridge operation on destination chain
    /// @param invoiceId The invoice ID for the destination
    /// @param sourceInvoiceId The invoice ID from source chain
    /// @param sourceChainId The source chain ID
    /// @param portfolioSafe The portfolio safe address
    /// @param asset The token address
    /// @param amount The amount received
    /// @param bridgeData Bridge-specific completion data
    function completeBridge(
        bytes32 invoiceId,
        bytes32 sourceInvoiceId,
        uint64 sourceChainId,
        address portfolioSafe,
        address asset,
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

