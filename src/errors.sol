// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

error InvalidArguments();
error InvalidArgumentsWithContext(string context);
error NotAuthorized();
error NotChainlinkOracle();

// Bridge-specific errors
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

