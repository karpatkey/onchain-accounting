// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title IBridgeEscrow Interface
/// @notice Interface for BridgeEscrow contract
/// @author kpk
/// @dev Contract Invariants:
///      - `_inTransitBalances[safe][asset]` should equal the sum of amounts from all BRIDGING invoices for that safe and asset
///      - `_inTransitBalancesAllSafes[asset]` should equal the sum of `_inTransitBalances[safe][asset]` across all safes
///      - `_activeInvoices[safe]` should only contain invoice hashes with status BRIDGING
///      - `completedInvoices[invoiceHash]` should only be true for valid invoice hashes that have been released
///      - All invoices in `_activeInvoices` must have a corresponding entry in `invoices` mapping
interface IBridgeEscrow {
    //
    // Errors
    //

    /// @notice Thrown when invalid arguments are provided
    error InvalidArguments();

    /// @notice Thrown when caller is not authorized
    error NotAuthorized();

    /// @notice Thrown when an invoice is not found
    error InvoiceNotFound();

    /// @notice Thrown when an invoice already exists (duplicate)
    error InvoiceAlreadyExists();

    /// @notice Thrown when invoice status is invalid for the operation
    error InvalidInvoiceStatus();

    /// @notice Thrown when transfer operation fails
    error TransferFailed();

    /// @notice Thrown when contract has insufficient balance
    /// @param asset The asset address
    /// @param required The required amount
    /// @param available The available amount
    error InsufficientBalance(address asset, uint256 required, uint256 available);

    /// @notice Thrown when completion data is invalid
    error InvalidCompletionData();

    /// @notice Thrown when checksum validation fails
    /// @param invoiceId The invoice ID
    /// @param provided The provided checksum
    /// @param calculated The calculated checksum
    error InvalidChecksum(bytes32 invoiceId, bytes24 provided, bytes24 calculated);

    /// @notice Thrown when timestamp is invalid
    /// @param provided The provided timestamp
    /// @param current The current timestamp
    error InvalidTimestamp(uint64 provided, uint64 current);

    /// @notice Thrown when attempting to unregister an asset with active invoices
    /// @param symbol The asset symbol
    error AssetHasActiveInvoices(bytes6 symbol);

    //
    // Types
    //
    /// @notice Status of a bridge invoice
    enum InvoiceStatus {
        BRIDGING, // Bridge adapter has initiated the bridge
        COMPLETED, // Assets successfully received on destination
        CANCELLED // Invoice cancelled (e.g., bridge failure recovery)
    }

    /// @notice Invoice structure tracking a bridge operation
    struct Invoice {
        bytes32 invoiceId; // Unique identifier (32 bytes, excludes amount)
        uint64 sourceChainId; // Chain ID where assets originate
        uint64 destinationChainId; // Chain ID where assets are destined
        address portfolioSafe; // Portfolio Safe address
        address asset; // Token address (address(0) for native)
        uint256 amount; // Amount being bridged
        uint256 timestamp; // Block timestamp when invoice created
        InvoiceStatus status; // Current status of the invoice
        address adapter; // Adapter address used for this invoice (for tracking and revocation handling)
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
    event AssetsReleased(
        bytes32 indexed invoiceId, uint64 indexed sourceChainId, address asset, uint256 amount, address recipient
    );

    /// @notice Event emitted when a portfolio safe is authorized
    event PortfolioSafeAuthorized(address indexed safe);

    /// @notice Event emitted when a portfolio safe is revoked
    event PortfolioSafeRevoked(address indexed safe);

    /// @notice Event emitted when an adapter is authorized
    event AdapterAuthorized(address indexed adapter);

    /// @notice Event emitted when an adapter is revoked
    event AdapterRevoked(address indexed adapter);

    /// @notice Event emitted when an adapter's callback config is updated
    event AdapterCallbackConfigUpdated(address indexed adapter, bytes4 selector, address module);

    /// @notice Event emitted when an asset is registered
    event AssetRegistered(bytes6 indexed symbol, address indexed asset);

    /// @notice Event emitted when an asset is unregistered
    event AssetUnregistered(bytes6 indexed symbol);

    /// @notice Event emitted when invoice completion attempts fail during batch operation
    event InvoiceCompletionFailed(bytes32[] invoiceIds);

    /// @notice Event emitted when an invoice is completed (before assets are released)
    event InvoiceCompleted(bytes32 indexed invoiceHash, bytes32 indexed invoiceId);

    /// @notice Event emitted when tokens are transferred from adapter to escrow
    event TokensTransferredToEscrow(bytes32 indexed invoiceId, address indexed asset, uint256 amount);

    /// @notice Event emitted when emergency withdrawal is performed
    event EmergencyWithdrawal(address indexed asset, uint256 amount, address indexed to);

    /// @notice Deposits assets from a portfolio safe and immediately bridges them
    /// @param destinationChainId The destination chain ID
    /// @param assetSymbol The asset symbol (bytes6, e.g., "USDC  " or "WETH  ")
    /// @param amount The amount to bridge
    /// @param adapter The bridge adapter address to use
    /// @return invoiceHash The hashed invoice identifier (checksum: invoiceId + amount + timestamp)
    function depositAndBridge(uint64 destinationChainId, bytes6 assetSymbol, uint256 amount, address adapter)
        external
        payable
        returns (bytes32 invoiceHash);

    /// @notice Releases funds based on invoice ID extracted from messagePayload
    /// @param messagePayload The message payload containing invoiceId, amount, timestamp, and checksum
    /// @dev Extracts these fields, validates checksum, and releases funds
    /// @dev This is the ONLY way to release funds - checksum validation is mandatory
    function releaseByInvoiceId(bytes memory messagePayload) external;

    /// @notice Cancels an invoice and returns assets (if still in escrow)
    /// @param invoiceHash The hashed invoice ID (checksum) to cancel
    function cancelInvoice(bytes32 invoiceHash) external;

    /// @notice Marks invoices as completed for bookkeeping purposes (source chain only)
    /// @param invoiceHashes Array of hashed invoice IDs to mark as completed
    /// @dev This function should be called by an operator after assets have been released on the destination chain.
    ///      It updates the invoice status on the source chain for bookkeeping purposes only.
    function markInvoiceCompleted(bytes32[] calldata invoiceHashes) external;

    /// @notice Gets an invoice by its hashed ID
    /// @param invoiceHash The hashed invoice ID (checksum)
    /// @return The invoice struct
    function getInvoice(bytes32 invoiceHash) external view returns (Invoice memory);

    /// @notice Decodes a 32-byte invoice ID into its components
    /// @param invoiceId The 32-byte invoice ID (excludes amount)
    /// @return sourceChainId Source chain ID
    /// @return destinationChainId Destination chain ID
    /// @return portfolioSafe Portfolio safe address (full 20 bytes)
    /// @return assetSymbol Asset symbol
    function decodeInvoiceId(bytes32 invoiceId)
        external
        pure
        returns (uint24 sourceChainId, uint24 destinationChainId, address portfolioSafe, bytes6 assetSymbol);

    /// @notice Validates invoiceId + amount + timestamp checksum from messagePayload
    /// @param invoiceId The 32-byte invoice ID (excludes amount)
    /// @param amount The amount being bridged
    /// @param timestamp The timestamp (uint64)
    /// @param checksum24 The 24-byte checksum from messagePayload (first 24 bytes of keccak256 hash)
    /// @return True if checksum is valid
    function validateInvoiceIdChecksum(bytes32 invoiceId, uint256 amount, uint64 timestamp, bytes24 checksum24)
        external
        pure
        returns (bool);

    /// @notice Gets all active invoices for a portfolio safe
    /// @param portfolioSafe The portfolio safe address
    /// @return Array of active Invoice structs (includes destination chain and all invoice details)
    function getActiveInvoices(address portfolioSafe) external view returns (Invoice[] memory);

    /// @notice Calculates the total in-transit balance for an asset by summing all active invoice amounts
    /// @param asset The asset address to calculate balance for
    /// @param portfolioSafe Optional portfolio safe address to filter by. If address(0), sums across all safes
    /// @return The total amount in transit for this asset (optionally filtered by portfolio safe)
    function getInTransitBalanceForAsset(address asset, address portfolioSafe) external view returns (uint256);

    /// @notice Checks if a portfolio safe is authorized
    /// @param safe The portfolio safe address
    /// @return True if authorized
    function isAuthorizedPortfolioSafe(address safe) external view returns (bool);

    /// @notice Checks if an adapter is authorized
    /// @param adapter The adapter address
    /// @return True if authorized
    function isAuthorizedAdapter(address adapter) external view returns (bool);

    /// @notice Checks if an invoice (by hash) has been completed
    /// @param invoiceHash The hashed invoice ID
    /// @return True if completed
    function isInvoiceCompleted(bytes32 invoiceHash) external view returns (bool);

    /// @notice Gets the asset address for a given asset symbol
    /// @param symbol The asset symbol (bytes6)
    /// @return The asset address, or address(0) if not registered
    function assetRegistry(bytes6 symbol) external view returns (address);

    /// @notice Checks if an asset symbol has been registered
    /// @param symbol The asset symbol (bytes6)
    /// @return True if the symbol has been registered
    function registeredSymbols(bytes6 symbol) external view returns (bool);

    /// @notice Returns all assets in-transit for a specific portfolio safe with their amounts
    /// @param portfolioSafe The portfolio safe address
    /// @return assets Array of asset addresses
    /// @return amounts Array of amounts corresponding to each asset
    function getInTransitBalancesForSafe(address portfolioSafe)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts);

    /// @notice Gets the completion status for an array of invoices
    /// @param invoiceHashes Array of invoice hashes to check
    /// @return isCompleted Array of booleans indicating completion status (indexed by input array)
    function getInvoicesCompletionStatus(bytes32[] calldata invoiceHashes)
        external
        view
        returns (bool[] memory isCompleted);

    /// @notice Returns the adapter registered for a callback selector
    function getCallbackAdapter(bytes4 selector) external view returns (address);
}

