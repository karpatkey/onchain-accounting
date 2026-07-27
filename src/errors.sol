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
/// @notice A balance adapter consumed the gas stipend the NAV read forwarded to it without answering.
/// @dev Deliberately NOT folded into the read's fail-open path. A revert means "this adapter has nothing to
///      report"; running out of gas means "this adapter's answer is unknown", and reporting an unknown answer as
///      an empty one drops the adapter's legs — a dropped debt leg RAISES the reported NAV.
///
///      `adapter` names the adapter that was running, which is not always the adapter at fault: the stipend is a
///      share of what the READ still holds, so an under-funded call starves whichever adapter happens to be
///      reached last. `stipend` and `consumed` are what separate the two cases. A large `stipend` fully consumed
///      means that adapter is genuinely runaway; a small `stipend` means the read itself was short of gas and the
///      fix is to supply more.
/// @param adapter The adapter that was executing when its gas ran out.
/// @param stipend Gas forwarded to it — 63/64 of what the read held at that point.
/// @param consumed Gas the call actually cost, including this frame's call overhead.
error AdapterGasExhausted(address adapter, uint256 stipend, uint256 consumed);

/// @notice One governed instance of a meta-adapter consumed its gas stipend without answering.
/// @dev The {AdapterGasExhausted} sibling, one frame in. A meta-adapter isolates each instance behind its own
///      `try`/`catch` so a single faulty instance cannot zero out the batch, and that isolation has the same
///      blind spot: an instance that runs out of gas is indistinguishable from one that reverted, and recording
///      it as "no positions" drops its legs while the meta-adapter still RETURNS SUCCESSFULLY — so the caller
///      sees a complete-looking answer. A dropped debt leg raises the reported NAV.
///
///      Raised rather than swallowed, and it names the instance because the adapter alone does not locate the
///      fault. `PriceFeedLib` keys on this selector explicitly rather than re-deriving exhaustion from gas, so a
///      cheap early raise here cannot be re-scored as a benign revert one frame out.
/// @param adapter The meta-adapter that was fanning out.
/// @param instance The governed instance coordinate whose read ran out of gas.
/// @param stipend Gas forwarded to that instance — 63/64 of what the fan-out held at that point.
/// @param consumed Gas the instance call actually cost, including the fan-out's call overhead.
error InstanceGasExhausted(address adapter, bytes32 instance, uint256 stipend, uint256 consumed);
error PriceFeedNotSet(address asset);
error AssetNotFound();
error OnlyNAVCalculator();
error ArrayLengthMismatch();
error InvalidAssetDecimals();
error InvalidDecimalExponent();

