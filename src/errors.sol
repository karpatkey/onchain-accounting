// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

error InvalidArguments();
error InvalidArgumentsWithContext(string context);
/// @notice A constructor argument expected to be a deployed contract has no code. `name` is the dependency label.
error NotAContract(string name);
error NotAuthorized();
error NotChainlinkOracle();
/// @notice Thrown when an assistant entrypoint that must be delegatecalled is called directly on the singleton
///         (`address(this) == SELF`). Canonical delegatecall-guard error for the assistant-fed family (`BalanceAdapterAssistant`).
error NotDelegateCall();
/// @notice An assistant entrypoint was told to track/act for an account other than the executing context
///         (`address(this)`, i.e. the delegatecalling Safe). Canonical assistant self-scope check (`_requireSelf`).
error AssistantAccountMismatch(address expected, address provided);

// Permissionless assistant-fed assisted balance-adapter family (ADR 0018) — shared coordinate-cache errors, used by the
// single {AssistedCoordCache} base (every coordinate is an `abi.encode`d blob). The coordinate is identified by `id`
// (a tokenId / requestId / positionTicket, from `_coordId`); the full tuple, where richer, rides in the cache's events.
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

