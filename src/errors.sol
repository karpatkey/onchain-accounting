// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

error InvalidArguments();
error InvalidArgumentsWithContext(string context);
/// @notice A constructor argument expected to be a deployed contract has no code. `name` is the dependency label.
error NotAContract(string name);
error NotAuthorized();
error NotChainlinkOracle();
/// @notice Thrown when an entrypoint that must be delegatecalled is called directly on the singleton.
error NotDelegateCall();

// Assisted balance-adapter errors
error NotTokenOwner(address account, uint256 tokenId);
error TokenIdCacheFull(address account, uint256 maxTokenIds);
// Assisted exit-queue (ticket-keyed) errors — StakeWise V3 caches (vault, positionTicket, timestamp) tuples, not
// tokenIds, so it has its own cache-full / invalid-position errors (same fail-loud-write semantics as the NFT adapters).
error PositionCacheFull(address account, uint256 maxPositions);
error InvalidExitPosition(address account, address vault, uint256 positionTicket);

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

