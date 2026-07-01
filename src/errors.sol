// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

error InvalidArguments();
error InvalidArgumentsWithContext(string context);
/// @notice A constructor argument expected to be a deployed contract has no code. `name` is the dependency label.
error NotAContract(string name);
error NotAuthorized();
error NotChainlinkOracle();

// Assisted balance-adapter errors
error NotTokenOwner(address account, uint256 tokenId);
error TokenIdCacheFull(address account, uint256 maxTokenIds);
// Assisted exit-queue (ticket-keyed) errors — StakeWise V3 caches (vault, positionTicket, timestamp) tuples, not
// tokenIds, so it has its own cache-full / invalid-position errors (same fail-loud-write semantics as the NFT adapters).
error PositionCacheFull(address account, uint256 maxPositions);
/// @notice `submit` was given a vault that is not StakeWise-registered.
error InvalidExitPosition(address account, address vault, uint256 positionTicket);
/// @notice `submit`'s `(vault, positionTicket, timestamp)` tuple does not resolve to a live exit position owned by
///         `account` (the on-chain ownership proxy `calculateExitedAssets(account, …)` returned zero).
error NotExitPositionOwner(address account, address vault, uint256 positionTicket);
/// @notice `remove` targeted a `(vault, positionTicket, timestamp)` tuple that is not in `account`'s tracked set.
error PositionNotTracked(address account, address vault, uint256 positionTicket);

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

