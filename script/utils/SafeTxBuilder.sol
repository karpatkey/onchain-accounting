// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

/// @title SafeTxBuilder
/// @notice Utility library for building Safe transaction JSON files
/// @dev Generates transaction JSON files compatible with Safe Transaction Service API
library SafeTxBuilder {
    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        uint8 operation; // 0 = Call, 1 = DelegateCall
    }

    struct SafeTransaction {
        string version;
        string chainId;
        string name;
        string description;
        Transaction[] transactions;
    }

    /// @notice Formats bytes32 as a hex string with 0x prefix
    function _bytes32ToHexString(bytes32 value) private pure returns (string memory) {
        bytes memory buffer = new bytes(66);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            uint8 b = uint8(value[i]);
            buffer[2 + i * 2] = _getHexChar(b >> 4);
            buffer[3 + i * 2] = _getHexChar(b & 0x0f);
        }
        return string(buffer);
    }

    /// @notice Gets hex character for a 4-bit value
    function _getHexChar(uint8 value) private pure returns (bytes1) {
        if (value < 10) {
            // casting to 'bytes1' and 'uint8' is safe because value is 0-9, result is 0x30-0x39 ('0'-'9')
            // forge-lint: disable-next-line(unsafe-typecast)
            return bytes1(uint8(bytes1("0")) + value);
        } else {
            // casting to 'bytes1' and 'uint8' is safe because (value-10) is 0-5, result is 0x61-0x66 ('a'-'f')
            // forge-lint: disable-next-line(unsafe-typecast)
            return bytes1(uint8(bytes1("a")) + value - 10);
        }
    }

    /// @notice Writes a Safe transaction to a JSON file
    /// @param vm The Foundry Vm instance
    /// @param chainId The chain ID
    /// @param filename The filename (without path) to save the transaction
    /// @param name Transaction name for Safe UI
    /// @param description Transaction description for Safe UI
    /// @param safeAddress The Safe multisig address
    /// @param transactions Array of transactions to include
    function writeSafeTx(
        Vm vm,
        uint256 chainId,
        string memory filename,
        string memory name,
        string memory description,
        address safeAddress,
        Transaction[] memory transactions
    ) internal {
        // Build transactions array manually as JSON with proper null values
        // Include operation field so Safe UI uses regular MultiSend (not MultiSendCallOnly) for DELEGATECALL
        string memory txsArray = "[";
        for (uint256 i = 0; i < transactions.length; i++) {
            // Build each transaction object manually
            // Include operation field (0 = CALL, 1 = DELEGATECALL) for proper execution
            string memory txJson = string(
                abi.encodePacked(
                    "{\"to\":\"",
                    vm.toString(transactions[i].to),
                    "\",\"value\":\"",
                    vm.toString(transactions[i].value),
                    "\",\"data\":\"",
                    vm.toString(transactions[i].data),
                    "\",\"operation\":",
                    vm.toString(transactions[i].operation),
                    ",\"contractMethod\":null,\"contractInputsValues\":null"
                )
            );

            txJson = string(abi.encodePacked(txJson, "}"));

            txsArray = string(abi.encodePacked(txsArray, txJson));
            if (i < transactions.length - 1) {
                txsArray = string(abi.encodePacked(txsArray, ","));
            }
        }
        txsArray = string(abi.encodePacked(txsArray, "]"));

        // Build meta object manually
        string memory metaJson = string(
            abi.encodePacked(
                "{\"name\":\"",
                name,
                "\",\"description\":\"",
                description,
                "\",\"txBuilderVersion\":\"1.18.3\",\"createdFromSafeAddress\":\"",
                vm.toString(safeAddress),
                "\",\"createdFromOwnerAddress\":\"\",\"checksum\":\""
            )
        );

        // Compute checksum (keccak256 hash of transactions array)
        bytes memory txsBytes = abi.encode(transactions);
        bytes32 checksumHash = keccak256(txsBytes);
        string memory checksumHex = _bytes32ToHexString(checksumHash);
        metaJson = string(abi.encodePacked(metaJson, checksumHex, "\"}"));

        // Build root object manually
        uint256 createdAt = block.timestamp * 1000;
        string memory finalJson = string(
            abi.encodePacked(
                "{\"version\":\"1.0\",\"chainId\":\"",
                vm.toString(chainId),
                "\",\"createdAt\":",
                vm.toString(createdAt),
                ",\"meta\":",
                metaJson,
                ",\"transactions\":",
                txsArray,
                "}"
            )
        );

        string memory filepath = string(abi.encodePacked("safe-transactions/", filename));
        vm.writeJson(finalJson, filepath);

        console2.log("Safe transaction written to:", filepath);
    }

    /// @notice Helper to create a Call transaction (operation = 0)
    function call(address to, uint256 value, bytes memory data) internal pure returns (Transaction memory) {
        return Transaction({to: to, value: value, data: data, operation: 0});
    }

    /// @notice Helper to create a DelegateCall transaction (operation = 1)
    function delegateCall(address to, bytes memory data) internal pure returns (Transaction memory) {
        return Transaction({to: to, value: 0, data: data, operation: 1});
    }

    /// @notice Encodes transactions in MultiSend format
    /// @dev Format: operation (1 byte) | to (20 bytes) | value (32 bytes) | dataLength (32 bytes) | data (N bytes)
    /// @param transactions Array of transactions to encode
    /// @return encoded Packed transaction data for MultiSend
    function encodeMultiSend(Transaction[] memory transactions) internal pure returns (bytes memory encoded) {
        for (uint256 i = 0; i < transactions.length; i++) {
            encoded = abi.encodePacked(
                encoded,
                bytes1(transactions[i].operation), // operation (1 byte)
                transactions[i].to, // to (20 bytes)
                transactions[i].value, // value (32 bytes)
                uint256(transactions[i].data.length), // dataLength (32 bytes)
                transactions[i].data // data (N bytes)
            );
        }
    }

    /// @notice Writes a Safe transaction that calls MultiSend directly with encoded transactions
    /// @param vm The Foundry Vm instance
    /// @param chainId The chain ID
    /// @param filename The filename (without path) to save the transaction
    /// @param name Transaction name for Safe UI
    /// @param description Transaction description for Safe UI
    /// @param safeAddress The Safe multisig address
    /// @param multiSendAddress The address of the MultiSend contract
    /// @param transactions Array of transactions to encode and send via MultiSend
    /// @param useDelegateCall If true, use DELEGATECALL for MultiSend (needed for CREATE2 in Safe context). If false, use CALL.
    /// @return multiSendData The encoded data for MultiSend (for safe-cli command generation)
    function writeSafeTxViaMultiSend(
        Vm vm,
        uint256 chainId,
        string memory filename,
        string memory name,
        string memory description,
        address safeAddress,
        address multiSendAddress,
        Transaction[] memory transactions,
        bool useDelegateCall
    ) internal returns (bytes memory multiSendData) {
        // Encode transactions in MultiSend format
        bytes memory encodedTxs = encodeMultiSend(transactions);

        // Create the MultiSend call data
        multiSendData = abi.encodeWithSignature("multiSend(bytes)", encodedTxs);

        // Create a single Safe transaction that calls MultiSend
        // Use DELEGATECALL if needed for CREATE2 in Safe context, otherwise use CALL
        Transaction[] memory safeTxs = new Transaction[](1);
        if (useDelegateCall) {
            safeTxs[0] = delegateCall(multiSendAddress, multiSendData);
        } else {
            safeTxs[0] = call(multiSendAddress, 0, multiSendData);
        }

        // Write the Safe transaction
        writeSafeTx(vm, chainId, filename, name, description, safeAddress, safeTxs);
    }

    /// @notice Generates a safe-cli command string for executing a transaction
    /// @param safeAddress The Safe multisig address
    /// @param to The destination address
    /// @param data The transaction data
    /// @param operation The operation type (0 = CALL, 1 = DELEGATECALL)
    /// @return The safe-cli command string
    function generateSafeCliCommand(address safeAddress, address to, bytes memory data, uint8 operation)
        internal
        pure
        returns (string memory)
    {
        // Convert data to hex string
        string memory dataHex = _bytesToHexString(data);

        return string(
            abi.encodePacked(
                "safe-cli tx create --safe ",
                _addressToString(safeAddress),
                " --to ",
                _addressToString(to),
                " --data ",
                dataHex,
                " --operation ",
                _uint8ToString(operation)
            )
        );
    }

    /// @notice Converts bytes to hex string
    function _bytesToHexString(bytes memory data) private pure returns (string memory) {
        bytes memory hexString = new bytes(data.length * 2 + 2);
        hexString[0] = "0";
        hexString[1] = "x";
        for (uint256 i = 0; i < data.length; i++) {
            uint8 byteValue = uint8(data[i]);
            hexString[2 + i * 2] = _getHexChar(byteValue >> 4);
            hexString[3 + i * 2] = _getHexChar(byteValue & 0x0f);
        }
        return string(hexString);
    }

    /// @notice Converts address to string (with 0x prefix)
    function _addressToString(address addr) private pure returns (string memory) {
        bytes memory hexString = new bytes(42);
        hexString[0] = "0";
        hexString[1] = "x";
        uint160 addrValue = uint160(addr);
        for (uint256 i = 0; i < 20; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 byteValue = uint8(uint160(addrValue) >> (8 * (19 - i)));
            hexString[2 + i * 2] = _getHexChar(byteValue >> 4);
            hexString[3 + i * 2] = _getHexChar(byteValue & 0x0f);
        }
        return string(hexString);
    }

    /// @notice Converts uint8 to string
    function _uint8ToString(uint8 value) private pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint8 temp = value;
        uint8 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
