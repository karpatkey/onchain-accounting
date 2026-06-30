// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title InvoiceDataLib
/// @notice Library for encoding and decoding invoice message payloads and symbol conversion
/// @dev Provides a standardized way to encode/decode invoice data and convert bytes6/string symbols.
///      The wire format is `abi.encode(invoiceId, amount, nonce, meta)` (4 slots), where
///      `meta = timestamp (uint64, bits 192-255) || checksum24 (bytes24, bits 0-191)`.
///      The `nonce` is a per-account monotonic counter included in the checksum preimage so that
///      invoice identity is unique per bridge operation (see ADR 0012). The checksum is
///      `bytes24(keccak256(invoiceId, amount, timestamp, nonce))`.
/// @author KPK
library InvoiceDataLib {
    /// @notice Converts a bytes6 symbol (e.g. right-padded "USDC  ") to a string, trimming trailing spaces and null bytes
    function bytes6ToStr(bytes6 symbol) public pure returns (string memory) {
        bytes memory b = abi.encodePacked(symbol);
        uint256 length = 6;
        while (length > 0 && (b[length - 1] == 0x20 || b[length - 1] == 0)) {
            length--;
        }
        if (length == 0) return "";
        bytes memory trimmed = new bytes(length);
        for (uint256 i; i < length; i++) {
            trimmed[i] = b[i];
        }
        return string(trimmed);
    }

    /// @notice Converts a string symbol to bytes6, right-padding with spaces to 6 bytes
    /// @param symbol The symbol string (max 6 characters); reverts with SymbolTooLong if length > 6
    function strToBytes6(string memory symbol) public pure returns (bytes6) {
        bytes memory b = bytes(symbol);
        if (b.length > 6) revert SymbolTooLong();
        bytes memory padded = new bytes(6);
        for (uint256 i; i < 6; i++) {
            padded[i] = i < b.length ? b[i] : bytes1(0x20);
        }
        uint256 word;
        for (uint256 i; i < 6; i++) {
            word |= uint256(uint8(padded[i])) << (8 * (5 - i));
        }
        return bytes6(uint48(word));
    }

    error SymbolTooLong();

    //
    /// @notice Struct containing all invoice data components
    struct InvoiceData {
        bytes32 invoiceId; // The route+account+symbol identity (32 bytes, excludes amount and nonce)
        uint24 sourceChainId; // Source chain ID
        uint24 destinationChainId; // Destination chain ID
        address account; // Account address
        bytes6 assetSymbol; // Asset symbol
        uint256 amount; // Amount being bridged
        uint256 nonce; // Per-account monotonic nonce (unique per bridge operation)
        uint64 timestamp; // Timestamp (uint64, 8 bytes)
        bytes24 checksum24; // 24-byte checksum over (invoiceId, amount, timestamp, nonce)
    }

    /// @notice Decodes a message payload into a complete InvoiceData struct
    /// @param messagePayload The message payload to decode
    /// @return data The complete invoice data struct
    function decode(bytes memory messagePayload) internal pure returns (InvoiceData memory data) {
        // Decode messagePayload (exactly 4 slots: invoiceId, amount, nonce, meta)
        bytes32 meta;
        (data.invoiceId, data.amount, data.nonce, meta) =
            abi.decode(messagePayload, (bytes32, uint256, uint256, bytes32));

        // Decode meta: timestamp (uint64, 8 bytes) + checksum24 (bytes24, 24 bytes) = 32 bytes total
        // timestamp is in the first 8 bytes (bits 192-255, shifted right by 192 to get first 8 bytes)
        data.timestamp = uint64(uint256(meta) >> 192);
        // checksum24 is in the last 24 bytes (bits 0-191)
        // Truncation to 24 bytes by design (checksum layout)
        // forge-lint: disable-next-line(unsafe-typecast)
        data.checksum24 = bytes24(uint192(uint256(meta)));

        // Decode invoiceId into its components
        uint256 id = uint256(data.invoiceId);
        data.sourceChainId = SafeCast.toUint24(id >> 232); // Bits 232-255 (3 bytes)
        data.destinationChainId = SafeCast.toUint24((id >> 208) & type(uint24).max); // Bits 208-231 (3 bytes); mask to avoid 48-bit value overflowing uint24
        data.account = address(uint160((id >> 48) & type(uint160).max)); // Bits 48-207 (20 bytes); mask so chain IDs don't overflow uint160
        // casting to uint48/bytes6 is safe: id & type(uint48).max keeps only low 48 bits, so no truncation
        // forge-lint: disable-next-line(unsafe-typecast)
        data.assetSymbol = bytes6(uint48(id & type(uint48).max)); // Bits 0-47 (6 bytes)
    }

    /// @notice Encodes an InvoiceData struct into a message payload
    /// @param data The invoice data struct to encode
    /// @return messagePayload The encoded message payload
    function encode(InvoiceData memory data) internal pure returns (bytes memory messagePayload) {
        // Encode meta from timestamp (uint64, 8 bytes) and checksum24 (bytes24, 24 bytes)
        // timestamp goes in bits 192-255 (leftmost 8 bytes), checksum24 goes in bits 0-191 (rightmost 24 bytes)
        bytes32 meta = bytes32(uint256(uint256(data.timestamp) << 192 | uint256(uint192(data.checksum24))));

        // Encode messagePayload (4 slots: invoiceId, amount, nonce, meta)
        return abi.encode(data.invoiceId, data.amount, data.nonce, meta);
    }

    /// @notice Calculates the 24-byte checksum over (invoiceId, amount, timestamp, nonce)
    /// @dev Single source of truth for the checksum preimage, shared by escrow and any validator.
    ///      The nonce makes the preimage unique per bridge operation; it is NOT a security
    ///      authenticator (all inputs are public) — provenance is enforced by the adapter layer
    ///      (ADR 0012). The checksum only guards payload integrity + replay (completedInvoices).
    /// @param invoiceId The 32-byte invoice ID (route+account+symbol identity)
    /// @param amount The amount being bridged
    /// @param timestamp The timestamp (uint64)
    /// @param nonce The per-account monotonic nonce
    /// @return checksum24 The first 24 bytes of keccak256(invoiceId, amount, timestamp, nonce)
    function calculateChecksum(bytes32 invoiceId, uint256 amount, uint64 timestamp, uint256 nonce)
        internal
        pure
        returns (bytes24 checksum24)
    {
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 fullHash = keccak256(abi.encodePacked(invoiceId, amount, timestamp, nonce));
        // casting to 'bytes24' is safe because we're truncating the last 8 bytes of a 32-byte hash
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes24(fullHash);
    }
}
