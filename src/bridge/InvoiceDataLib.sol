// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title InvoiceDataLib
/// @notice Library for encoding and decoding invoice message payloads
/// @dev Provides a standardized way to encode/decode invoice data across bridge components
/// @author kpk
library InvoiceDataLib {
    /// @notice Struct containing all invoice data components
    struct InvoiceData {
        bytes32 invoiceId;              // The full invoice ID (32 bytes)
        uint24 sourceChainId;            // Source chain ID
        uint24 destinationChainId;      // Destination chain ID
        address portfolioSafe;          // Portfolio safe address
        bytes6 assetSymbol;             // Asset symbol
        uint256 amount;                  // Amount being bridged
        uint8 timestampByte;             // Timestamp truncated to uint8
        bytes24 checksum24;              // 24-byte checksum
    }

    /// @notice Decodes a message payload into a complete InvoiceData struct
    /// @param messagePayload The message payload to decode
    /// @return data The complete invoice data struct
    function decode(bytes memory messagePayload)
        internal
        pure
        returns (InvoiceData memory data)
    {
        // Decode messagePayload (exactly 3 slots: invoiceId, amount, meta)
        bytes32 meta;
        (data.invoiceId, data.amount, meta) = abi.decode(messagePayload, (bytes32, uint256, bytes32));
        
        // Decode meta: timestampByte (uint8) + checksum24 (bytes24)
        data.timestampByte = uint8(uint256(meta) >> 248);
        data.checksum24 = bytes24(uint192(uint256(meta)));
        
        // Decode invoiceId into its components
        uint256 id = uint256(data.invoiceId);
        data.sourceChainId = uint24(id >> 232);           // Bits 232-255 (3 bytes)
        data.destinationChainId = uint24(id >> 208);      // Bits 208-231 (3 bytes)
        data.portfolioSafe = address(uint160(id >> 48));  // Bits 48-207 (20 bytes)
        data.assetSymbol = bytes6(uint48(id));            // Bits 0-47 (6 bytes)
    }

    /// @notice Encodes an InvoiceData struct into a message payload
    /// @param data The invoice data struct to encode
    /// @return messagePayload The encoded message payload
    function encode(InvoiceData memory data)
        internal
        pure
        returns (bytes memory messagePayload)
    {
        // Encode meta from timestampByte and checksum24
        bytes32 meta = bytes32(uint256(uint256(data.timestampByte) << 248 | uint256(uint192(data.checksum24))));
        
        // Encode messagePayload
        return abi.encode(data.invoiceId, data.amount, meta);
    }
}
