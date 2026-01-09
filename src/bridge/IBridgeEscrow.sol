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
        uint64 destinationChainId
    );

    /// @notice Event emitted when invoice status changes
    event InvoiceStatusUpdated(bytes32 indexed invoiceId, InvoiceStatus oldStatus, InvoiceStatus newStatus);

    /// @notice Event emitted when assets are deposited into escrow
    event AssetsDeposited(bytes32 indexed invoiceId, address indexed asset, uint256 amount);

    /// @notice Event emitted when assets are released from escrow
    event AssetsReleased(bytes32 indexed invoiceId, uint64 indexed sourceChainId, address asset, uint256 amount, address recipient);

    /// @notice Event emitted when a portfolio safe is authorized
    event PortfolioSafeAuthorized(address indexed safe);

    /// @notice Event emitted when a portfolio safe is revoked
    event PortfolioSafeRevoked(address indexed safe);

    /// @notice Event emitted when an adapter is authorized
    event AdapterAuthorized(address indexed adapter);

    /// @notice Event emitted when an adapter is revoked
    event AdapterRevoked(address indexed adapter);

    /// @notice Event emitted when an asset is registered
    event AssetRegistered(bytes6 indexed symbol, address indexed asset);

    /// @notice Event emitted when an asset is unregistered
    event AssetUnregistered(bytes6 indexed symbol);

    /// @notice Event emitted when invoice completion attempts fail during batch operation
    event InvoiceCompletionFailed(bytes32[] invoiceIds);

    /// @notice Deposits assets from a portfolio safe and immediately bridges them
    /// @param destinationChainId The destination chain ID
    /// @param assetSymbol The asset symbol (bytes6, e.g., "USDC  " or "WETH  ")
    /// @param amount The amount to bridge
    /// @param adapter The bridge adapter address to use
    /// @param bridgeData Bridge-specific data
    /// @return invoiceId The unique invoice identifier
    function depositAndBridge(
        uint64 destinationChainId,
        bytes6 assetSymbol,
        uint256 amount,
        address adapter,
        bytes calldata bridgeData
    ) external payable returns (bytes32 invoiceId);

    /// @notice Releases funds based on invoice ID validation
    /// @param invoiceId The invoice ID to decode and validate
    /// @param portfolioSafe The portfolio safe address (must match decoded invoiceId)
    /// @param amount The amount to release
    /// @dev This function decodes the invoiceId, looks up asset from symbol, validates all parameters match,
    ///      checks for nonce replay, and releases the funds if all validations pass.
    function releaseByInvoiceId(
        bytes32 invoiceId,
        address portfolioSafe,
        uint256 amount
    ) external;

    /// @notice Cancels an invoice and returns assets (if still in escrow)
    /// @param invoiceId The invoice ID to cancel
    function cancelInvoice(bytes32 invoiceId) external;

    /// @notice Marks invoices as completed for bookkeeping purposes (source chain only)
    /// @param invoiceIds Array of invoice IDs to mark as completed
    /// @dev This function should be called by an operator after assets have been released on the destination chain.
    ///      It updates the invoice status on the source chain for bookkeeping purposes only.
    function markInvoiceCompleted(bytes32[] calldata invoiceIds) external;

    /// @notice Gets an invoice by ID
    /// @param invoiceId The invoice ID
    /// @return The invoice struct
    function getInvoice(bytes32 invoiceId) external view returns (Invoice memory);

    /// @notice Decodes an invoice ID into its components and validates the checksum
    /// @param invoiceId The invoice ID to decode
    /// @return sourceChainId Source chain ID (truncated to uint24)
    /// @return destinationChainId Destination chain ID (truncated to uint24)
    /// @return portfolioSafe Portfolio safe address (truncated to 10 bytes, padded with zeros)
    /// @return assetSymbol Asset symbol (bytes6)
    /// @dev Reverts if the checksum is invalid
    function decodeInvoiceId(bytes32 invoiceId)
        external
        pure
        returns (
            uint24 sourceChainId,
            uint24 destinationChainId,
            address portfolioSafe,
            bytes6 assetSymbol
        );

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

