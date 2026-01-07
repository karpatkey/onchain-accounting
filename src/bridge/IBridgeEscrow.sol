// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title IBridgeEscrow Interface
/// @notice Interface for BridgeEscrow contract
/// @author kpk
interface IBridgeEscrow {
    /// @notice Status of a bridge invoice
    enum InvoiceStatus {
        BRIDGING, // Bridge adapter has initiated the bridge
        COMPLETED, // Assets successfully received on destination
        CANCELLED // Invoice cancelled (e.g., bridge failure recovery)
    }

    /// @notice Invoice structure tracking a bridge operation
    struct Invoice {
        bytes32 invoiceId; // Unique identifier
        uint64 sourceChainId; // Chain ID where assets originate
        uint64 destinationChainId; // Chain ID where assets are destined
        address portfolioSafe; // Portfolio Safe address
        uint256 globalNonce; // Incrementing counter per portfolioSafe
        address asset; // Token address (address(0) for native)
        uint256 amount; // Amount being bridged
        uint256 timestamp; // Block timestamp when invoice created
        InvoiceStatus status; // Current status of the invoice
    }

    /// @notice Event emitted when a new invoice is created
    event InvoiceCreated(
        bytes32 indexed invoiceId,
        address indexed portfolioSafe,
        address indexed asset,
        uint256 amount,
        uint64 sourceChainId,
        uint64 destinationChainId,
        uint256 nonce
    );

    /// @notice Event emitted when invoice status changes
    event InvoiceStatusUpdated(bytes32 indexed invoiceId, InvoiceStatus oldStatus, InvoiceStatus newStatus);

    /// @notice Event emitted when assets are deposited into escrow
    event AssetsDeposited(bytes32 indexed invoiceId, address indexed asset, uint256 amount);

    /// @notice Event emitted when assets are released from escrow
    event AssetsReleased(bytes32 indexed invoiceId, address indexed asset, uint256 amount, address indexed recipient);

    /// @notice Event emitted when a portfolio safe is authorized
    event PortfolioSafeAuthorized(address indexed safe);

    /// @notice Event emitted when a portfolio safe is revoked
    event PortfolioSafeRevoked(address indexed safe);

    /// @notice Event emitted when an adapter is authorized
    event AdapterAuthorized(address indexed adapter);

    /// @notice Event emitted when an adapter is revoked
    event AdapterRevoked(address indexed adapter);

    /// @notice Deposits assets from a portfolio safe and immediately bridges them
    /// @param destinationChainId The destination chain ID
    /// @param asset The token address (address(0) for native)
    /// @param amount The amount to bridge
    /// @param adapter The bridge adapter address to use
    /// @param bridgeData Bridge-specific data
    /// @return invoiceId The unique invoice identifier
    function depositAndBridge(
        uint64 destinationChainId,
        address asset,
        uint256 amount,
        address adapter,
        bytes calldata bridgeData
    ) external payable returns (bytes32 invoiceId);

    /// @notice Releases assets to the destination portfolio safe
    /// @param invoiceId The invoice ID for the destination
    /// @param sourceInvoiceId The invoice ID from source chain
    /// @param sourceChainId The source chain ID
    /// @param portfolioSafe The portfolio safe address
    /// @param asset The token address
    /// @param amount The amount received
    function release(
        bytes32 invoiceId,
        bytes32 sourceInvoiceId,
        uint64 sourceChainId,
        address portfolioSafe,
        address asset,
        uint256 amount
    ) external;

    /// @notice Cancels an invoice and returns assets (if still in escrow)
    /// @param invoiceId The invoice ID to cancel
    function cancelInvoice(bytes32 invoiceId) external;

    /// @notice Gets an invoice by ID
    /// @param invoiceId The invoice ID
    /// @return The invoice struct
    function getInvoice(bytes32 invoiceId) external view returns (Invoice memory);

    /// @notice Gets all active invoices for a portfolio safe
    /// @param portfolioSafe The portfolio safe address
    /// @return Array of active invoice IDs
    function getActiveInvoices(address portfolioSafe) external view returns (bytes32[] memory);

    /// @notice Gets the total in-transit balance for an asset
    /// @param asset The token address
    /// @return The total amount in transit
    function getInTransitBalance(address asset) external view returns (uint256);

    /// @notice Gets the in-transit balance for a specific portfolio safe and asset
    /// @param portfolioSafe The portfolio safe address
    /// @param asset The token address
    /// @return The amount in transit for this safe
    function getInTransitBalanceFor(address portfolioSafe, address asset) external view returns (uint256);

    /// @notice Gets the nonce for a portfolio safe
    /// @param portfolioSafe The portfolio safe address
    /// @return The current nonce
    function nonces(address portfolioSafe) external view returns (uint256);

    /// @notice Gets the in-transit balance by safe and asset
    /// @param portfolioSafe The portfolio safe address
    /// @param asset The token address
    /// @return The amount in transit
    function inTransitBalancesBySafe(address portfolioSafe, address asset) external view returns (uint256);

    /// @notice Checks if a portfolio safe is authorized
    /// @param safe The portfolio safe address
    /// @return True if authorized
    function isAuthorizedPortfolioSafe(address safe) external view returns (bool);

    /// @notice Checks if an adapter is authorized
    /// @param adapter The adapter address
    /// @return True if authorized
    function isAuthorizedAdapter(address adapter) external view returns (bool);
}

