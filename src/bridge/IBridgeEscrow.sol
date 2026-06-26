// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @title IBridgeEscrow Interface
/// @notice Interface for BridgeEscrow contract
/// @author KPK
/// @dev Contract Invariants:
///      - `_inTransitBalances[safe][asset]` equals the sum of amounts from all BRIDGING invoices for that safe and asset
///      - `_inTransitBalancesAllAccounts[asset]` equals the sum of `_inTransitBalances[safe][asset]` across all safes
///      - `_activeInvoices[safe]` only contains invoice hashes with status BRIDGING
///      - `completedInvoices[invoiceHash]` is only true for valid invoice hashes that have been released
///      - All invoices in `_activeInvoices` have a corresponding entry in `invoices`
///      - Destination-side release (`releaseByInvoiceId`) is callable only by an authorized adapter — there is
///        no `fallback()` dispatcher and MANAGER cannot call it directly, so the release path is unreachable to
///        an attacker (ADR 0012, C1). In this PR release pays the account from the escrow's own balance; the
///        per-invoice *funded pass-through* (escrow pulls the amount from the calling adapter, no standing pool)
///        lands with the recipient→adapter change in the follow-up adapter-provenance PR.
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

    /// @notice Thrown when attempting to unregister or repoint an asset with active invoices
    /// @param symbol The asset symbol (string)
    error AssetHasActiveInvoices(string symbol);

    /// @notice Thrown when attempting to revoke an account that still has active (BRIDGING) invoices
    /// @param account The account address
    error AccountHasActiveInvoices(address account);

    /// @notice Thrown when attempting to unregister a symbol that was never registered
    /// @param symbol The asset symbol (string)
    error AssetNotRegistered(string symbol);

    /// @notice Thrown when the native value sent does not match the funded release/deposit amount
    error InvalidValue();

    //
    // Types
    //
    /// @notice Status of a bridge invoice
    enum InvoiceStatus {
        BRIDGING, // Bridge adapter has initiated the bridge
        COMPLETED, // Assets successfully received on destination
        CANCELLED // Invoice cancelled (e.g., bridge failure recovery)
    }

    /// @notice Invoice structure tracking a bridge operation (source-chain ledger)
    struct Invoice {
        bytes32 invoiceId; // Route+account+symbol identity (32 bytes, excludes amount and nonce)
        uint64 sourceChainId; // Chain ID where assets originate
        uint64 destinationChainId; // Chain ID where assets are destined
        address account; // Account address
        address asset; // Token address (address(0) for native)
        uint256 amount; // Amount being bridged
        uint256 nonce; // Per-account monotonic nonce (unique per operation)
        uint256 timestamp; // Block timestamp when invoice created
        InvoiceStatus status; // Current status of the invoice
        address adapter; // Adapter address used for this invoice
    }

    //
    // Events
    //

    /// @notice Event emitted when a new invoice is created
    event InvoiceCreated(
        bytes32 indexed invoiceId,
        address indexed account,
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

    /// @notice Event emitted when an account is authorized
    event AccountAuthorized(address indexed safe);

    /// @notice Event emitted when an account is revoked
    event AccountRevoked(address indexed safe);

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

    /// @notice Event emitted when an invoice is completed (before assets are released)
    event InvoiceCompleted(bytes32 indexed invoiceHash, bytes32 indexed invoiceId);

    /// @notice Event emitted when emergency withdrawal is performed
    event EmergencyWithdrawal(address indexed asset, uint256 amount, address indexed to);

    //
    // Core
    //

    /// @notice Deposits assets from an account and immediately bridges them
    /// @param destinationChainId The destination chain ID
    /// @param assetSymbol The asset symbol as string (e.g. "USDC" or "WETH"; max 6 chars)
    /// @param amount The amount to bridge
    /// @param adapter The bridge adapter address to use
    /// @return invoiceHash The hashed invoice identifier (checksum: invoiceId + amount + timestamp + nonce)
    function depositAndBridge(uint64 destinationChainId, string calldata assetSymbol, uint256 amount, address adapter)
        external
        payable
        returns (bytes32 invoiceHash);

    /// @notice Releases funds to the account named by the invoice, funded by the calling adapter.
    /// @param messagePayload The message payload (invoiceId, amount, nonce, meta)
    /// @dev Destination-side funded pass-through (ADR 0012). Callable only by an authorized adapter; there is
    ///      no fallback dispatcher and MANAGER cannot call this directly (C1). The escrow pulls `amount` of
    ///      the asset from the caller (or requires `msg.value == amount` for native) and forwards it to the
    ///      account, after validating checksum (incl. nonce), destination chain, authorized account and replay.
    ///      It never pays from a standing balance (H2/H9).
    function releaseByInvoiceId(bytes calldata messagePayload) external payable;

    /// @notice Cancels an invoice and returns assets (source chain, bridge-failure recovery)
    /// @param invoiceHash The hashed invoice ID (checksum) to cancel
    function cancelInvoice(bytes32 invoiceHash) external;

    /// @notice Marks invoices as completed for bookkeeping purposes (source chain only)
    /// @param invoiceHashes Array of hashed invoice IDs to mark as completed
    function markInvoiceCompleted(bytes32[] calldata invoiceHashes) external;

    //
    // Views
    //

    /// @notice Gets an invoice by its hashed ID
    function getInvoice(bytes32 invoiceHash) external view returns (Invoice memory);

    /// @notice Returns the current (next) bridge nonce for an account
    function bridgeNonce(address account) external view returns (uint256);

    /// @notice Decodes a 32-byte invoice ID into its components
    function decodeInvoiceId(bytes32 invoiceId)
        external
        pure
        returns (uint24 sourceChainId, uint24 destinationChainId, address account, string memory assetSymbol);

    /// @notice Validates the (invoiceId, amount, timestamp, nonce) checksum
    function validateInvoiceIdChecksum(
        bytes32 invoiceId,
        uint256 amount,
        uint64 timestamp,
        uint256 nonce,
        bytes24 checksum24
    ) external pure returns (bool);

    /// @notice Gets all active invoices for an account
    function getActiveInvoices(address account) external view returns (Invoice[] memory);

    /// @notice Total in-transit balance for an asset (optionally filtered by account; address(0) = all)
    function getInTransitBalanceForAsset(address asset, address account) external view returns (uint256);

    /// @notice Checks if an account is authorized
    function isAuthorizedAccount(address safe) external view returns (bool);

    /// @notice Checks if an adapter is authorized
    function isAuthorizedAdapter(address adapter) external view returns (bool);

    /// @notice Checks if an invoice (by hash) has been completed
    function isInvoiceCompleted(bytes32 invoiceHash) external view returns (bool);

    /// @notice Gets the asset address for a given asset symbol
    function assetRegistry(string calldata symbol) external view returns (address);

    /// @notice Returns all registered asset symbol-address pairs
    function registeredAssets() external view returns (string[] memory symbols, address[] memory assets);

    /// @notice Returns all assets in-transit for a specific account with their amounts
    function getInTransitBalancesForAccount(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts);

    /// @notice Gets the completion status for an array of invoices
    function getInvoicesCompletionStatus(bytes32[] calldata invoiceHashes)
        external
        view
        returns (bool[] memory isCompleted);

    /// @notice Returns all authorized adapters
    function getAuthorizedAdapters() external view returns (address[] memory adapters);
}
