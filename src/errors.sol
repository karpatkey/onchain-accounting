// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

error InvalidArguments();
error InvalidArgumentsWithContext(string context);
/// @notice A constructor argument expected to be a deployed contract has no code. `name` is the dependency label.
error NotAContract(string name);
error NotAuthorized();
error NotChainlinkOracle();
/// @notice Thrown when a wrapper entrypoint that must be delegatecalled is called directly on the singleton
///         (`address(this) == SELF`). Canonical delegatecall-guard error for the wrapper-fed family (`BalanceAdapterWrapper`).
error NotDelegateCall();
/// @notice A wrapper entrypoint was told to track/act for an account other than the executing context
///         (`address(this)`, i.e. the delegatecalling Safe). Canonical wrapper self-scope check (`_requireSelf`).
error WrapperAccountMismatch(address expected, address provided);

// Legacy agent-fed assisted balance-adapter errors (ASSISTANT_ROLE family: Merkl, …). See {IAssistantFedBalanceAdapter}.
error NotTokenOwner(address account, uint256 tokenId);
error TokenIdCacheFull(address account, uint256 maxTokenIds);
// Legacy exit-queue (ticket-keyed) errors — still used by adapters not yet migrated onto the {AssistedCoordCache} base.
error PositionCacheFull(address account, uint256 maxPositions);
error InvalidExitPosition(address account, address vault, uint256 positionTicket);

// Permissionless wrapper-fed assisted balance-adapter family (ADR 0018) — shared coordinate-cache errors, used by both
// the uint256-id cache ({AssistedNftIdCache}) and the tuple cache ({AssistedCoordCache}). The coordinate is identified
// by `id` (a tokenId / requestId / positionTicket); the full tuple, where richer, rides in the cache's events.
/// @notice `submit` was given a coordinate not currently owned by the caller (`msg.sender`).
error CoordinateNotOwned(address account, uint256 id);
/// @notice `submit` would grow the caller's cache past its per-account cap.
error CoordinateCacheFull(address account, uint256 maxCoordinates);
/// @notice `remove` targeted a coordinate not in the caller's cache.
error CoordinateNotCached(address account, uint256 id);
/// @notice `remove` targeted a coordinate the caller still owns (a live position) — refused so a live position is never
///         dropped (would under-report the caller's own NAV). Only a claimed/consumed coordinate may be removed.
error CoordinateStillLive(address account, uint256 id);
/// @notice `submit` was given a coordinate that failed the adapter's write-time protocol validation (e.g. an
///         unregistered target). Distinct from {CoordinateNotOwned} (ownership) — this is a malformed/invalid coordinate.
error InvalidCoordinate(address account, uint256 id);

// Bridge-specific errors
error AlreadyInitialized();
error InvoiceNotFound();
error InvoiceAlreadyExists();
error InvalidInvoiceStatus();
error InvalidInvoice();
error TransferFailed();
error InsufficientBalance(address asset, uint256 required, uint256 available);
error InvalidChainId();
error InvalidNonce();
error InvalidCompletionData();
error InvalidChecksum(bytes32 invoiceId, bytes24 provided, bytes24 calculated);
error InvalidTimestamp(uint64 provided, uint64 current);
error AssetHasActiveInvoices(string symbol);
error AssetNotRegistered(string symbol);

// NAV Calculator / registry errors
error PriceFeedNotSet(address asset);
error AssetNotFound();
error OnlyNAVCalculator();
error ArrayLengthMismatch();
error InvalidAssetDecimals();
error InvalidDecimalExponent();

