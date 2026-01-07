// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

error InvalidArguments();
error NotAuthorized();
error NotChainlinkOracle();

// Bridge-specific errors
error InvoiceNotFound();
error InvoiceAlreadyExists();
error InvalidInvoiceStatus();
error TransferFailed();
error InsufficientBalance();
error InvalidChainId();
error InvalidNonce();
