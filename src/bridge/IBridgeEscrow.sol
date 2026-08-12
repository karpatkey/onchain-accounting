// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @title IBridgeEscrow Interface
/// @notice Interface for BridgeEscrow contract
/// @author KPK
/// @dev Contract Invariants:
///      - `_inTransitBalances[safe][asset]` equals the sum of amounts from all BRIDGING invoices for that safe and asset
///      - `_inTransitBalancesAllAccounts[asset]` equals the sum of `_inTransitBalances[safe][asset]` across all safes
///      - `_activeInvoices[safe]` only contains invoice hashes with status BRIDGING
///      - `completedInvoices[invoiceHash]` is true once a delivery has been recorded on the destination chain
///        (`recordDelivery`) or the invoice marked completed on the source chain (`markInvoiceCompleted`)
///      - All invoices in `_activeInvoices` have a corresponding entry in `invoices`
///      - Destination custody (ADR 0024, supersedes the ADR-0012 funded pass-through on the destination): the
///        delivered funds are HELD by the escrow in a per-invoice `destinationCustody` record and released to the
///        account only by `claim`. Invariants:
///        (I1) for every asset, `balanceOf(asset) >= _heldClaimable[asset]`, and `_heldClaimable[asset]` equals
///        both the sum of unclaimed `destinationCustody` amounts and `Σ _heldByAccount[*][asset]`;
///        (I2) a custody record is writable only via `recordDelivery`, callable only by an authorized adapter
///        (no `fallback()`; MANAGER cannot record) — provenance stays in the adapter, the checksum is
///        integrity/replay only; (I3) `claimed` flips once; (I4) `claim` pays only the recorded account exactly
///        the recorded amount; (I6) funds not recorded via `recordDelivery` are never claimable; (I7) the
///        recorded amount is the measured balance-delta received (≤ requested).
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

    /// @notice Thrown when attempting to revoke an adapter that still has in-flight (BRIDGING) invoices
    /// @param adapter The bridge adapter address
    error AdapterHasActiveInvoices(address adapter);

    /// @notice Thrown when attempting to unregister a symbol that was never registered
    /// @param symbol The asset symbol (string)
    error AssetNotRegistered(string symbol);

    /// @notice Thrown when the native value sent is wrong for the asset: `msg.value` must equal the
    ///         release/deposit amount for native assets, and must be zero for ERC20 assets
    error InvalidValue();

    /// @notice Thrown when attempting to claim a destination custody record that has already been claimed
    error AlreadyClaimed();

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

    /// @notice Destination-side custody record (ADR 0024). Written by `recordDelivery` when an authorized
    ///         adapter hands the escrow the delivered funds; the escrow HOLDS them until `claim`.
    struct DestinationCustody {
        address account; // Authenticated payee from the invoice — `claim` pays ONLY this
        address asset; // Resolved destination asset (address(0)/ERC7528 = native)
        uint256 amount; // MEASURED balance-delta actually received (fee-on-transfer / post-fee safe)
        address adapter; // msg.sender at recordDelivery — provenance stamp
        uint64 deliveredAt; // Block timestamp of recordDelivery
        bool claimed; // false = held in escrow; true = moved to the safe (terminal)
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

    /// @notice Event emitted when an invoice is completed (destination delivery recorded, or source marked)
    event InvoiceCompleted(bytes32 indexed invoiceHash, bytes32 indexed invoiceId);

    /// @notice Event emitted when a destination delivery is recorded and the funds held in escrow custody
    event DeliveryRecorded(
        bytes32 indexed invoiceId,
        bytes32 indexed invoiceHash,
        address indexed asset,
        uint256 amount,
        address account,
        address adapter
    );

    /// @notice Event emitted when held funds are claimed from escrow custody to the recorded account (the safe)
    event AssetsClaimed(bytes32 indexed invoiceHash, address indexed asset, uint256 amount, address indexed account);

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

    /// @notice Records a destination delivery and HOLDS the funds in escrow custody (ADR 0024).
    /// @param messagePayload The message payload (invoiceId, amount, nonce, meta)
    /// @dev Callable ONLY by an authorized adapter (the adapter has already authenticated the genuine inbound
    ///      protocol message + source sender); there is no fallback dispatcher and MANAGER cannot call this
    ///      directly (C1). The escrow pulls `amount` of the asset from the caller (or requires `msg.value ==
    ///      amount` for native), MEASURES the balance-delta actually received, writes a `destinationCustody`
    ///      record, and holds the funds. It does NOT pay the account — release happens only via `claim`.
    ///      Validates checksum (incl. nonce), destination chain, authorized account, and replay.
    function recordDelivery(bytes calldata messagePayload) external payable;

    /// @notice Releases a held destination delivery from escrow custody to the recorded account (the safe).
    /// @param invoiceHash The destination custody key (checksum-derived invoice hash)
    /// @dev MANAGER-gated. Because it can only ever pay the account recorded at `recordDelivery` (and exactly
    ///      the recorded amount), the gate controls only the TIMING of when funds enter the safe (NAV
    ///      sequencing), never the destination. Reverts if no record exists or it was already claimed.
    function claim(bytes32 invoiceHash) external;

    /// @notice Batch form of {claim} for keeper gas efficiency.
    /// @param invoiceHashes The destination custody keys to claim
    function claim(bytes32[] calldata invoiceHashes) external;

    /// @notice Cancels an invoice and returns assets (source chain, bridge-failure recovery)
    /// @param invoiceHash The hashed invoice ID (checksum) to cancel
    /// @dev Refunds only from the surplus over destination held custody (never touches funds backing a recorded
    ///      delivery, I1). There is NO on-chain source↔destination interlock, so this MUST only be called once the
    ///      destination has provably not delivered and will not: cancelling a still-live invoice while the escrow
    ///      holds unrelated surplus (e.g. stray funds) could refund the source AND let the destination later
    ///      deliver, double-paying from that surplus. Enforced by MANAGER / settlement-keeper discipline.
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

    /// @notice Held-but-unclaimed destination custody for an asset (optionally filtered by account;
    ///         address(0) = all accounts). Mirrors {getInTransitBalanceForAsset} for the destination side so a
    ///         balance adapter can count delivered-but-not-yet-claimed value in NAV.
    /// @dev Native dual-key: the aggregate (account == address(0)) path sums BOTH native representations
    ///      (`address(0)` + the ERC-7528 sentinel); the per-account path returns the single exact key.
    ///      `BridgeHeldBalanceAdapter` sums both native keys itself per account (so NAV is unaffected) — but a
    ///      direct caller reading a specific account's native custody should query both keys (or use the adapter),
    ///      otherwise it under-reports native held under the "other" key.
    function getHeldBalanceForAsset(address asset, address account) external view returns (uint256);

    /// @notice Returns all assets held-but-unclaimed for a specific account with their amounts (destination).
    function getHeldBalancesForAccount(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts);
}
