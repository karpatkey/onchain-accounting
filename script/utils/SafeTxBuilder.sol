// SPDX-License-Identifier: MIT
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

    /// @notice Writes a Safe transaction to a JSON file
    /// @param vm The Foundry Vm instance
    /// @param chainId The chain ID
    /// @param filename The filename (without path) to save the transaction
    /// @param name Transaction name for Safe UI
    /// @param description Transaction description for Safe UI
    /// @param transactions Array of transactions to include
    function writeSafeTx(
        Vm vm,
        uint256 chainId,
        string memory filename,
        string memory name,
        string memory description,
        Transaction[] memory transactions
    ) internal {
        string memory obj = "safeTx";

        // Metadata
        vm.serializeString(obj, "version", "1.0");
        vm.serializeString(obj, "chainId", vm.toString(chainId));

        // Meta object
        string memory metaObj = "meta";
        vm.serializeString(metaObj, "name", name);
        string memory metaJson = vm.serializeString(metaObj, "description", description);
        vm.serializeString(obj, "meta", metaJson);

        // Transactions array
        string memory txsObj = "transactions";
        for (uint256 i = 0; i < transactions.length; i++) {
            string memory txObj = string(abi.encodePacked("tx", vm.toString(i)));
            vm.serializeAddress(txObj, "to", transactions[i].to);
            vm.serializeString(txObj, "value", vm.toString(transactions[i].value));
            vm.serializeString(txObj, "data", vm.toString(transactions[i].data));
            string memory txJson = vm.serializeUint(txObj, "operation", transactions[i].operation);

            if (i == transactions.length - 1) {
                vm.serializeString(txsObj, vm.toString(i), txJson);
            } else {
                vm.serializeString(txsObj, vm.toString(i), txJson);
            }
        }

        // Serialize transactions as array
        string memory txsArray = "[";
        for (uint256 i = 0; i < transactions.length; i++) {
            string memory txObj = string(abi.encodePacked("tx", vm.toString(i)));
            vm.serializeAddress(txObj, "to", transactions[i].to);
            vm.serializeString(txObj, "value", vm.toString(transactions[i].value));
            vm.serializeString(txObj, "data", vm.toString(transactions[i].data));
            string memory txJson = vm.serializeUint(txObj, "operation", transactions[i].operation);

            txsArray = string(abi.encodePacked(txsArray, txJson));
            if (i < transactions.length - 1) {
                txsArray = string(abi.encodePacked(txsArray, ","));
            }
        }
        txsArray = string(abi.encodePacked(txsArray, "]"));

        vm.serializeString(obj, "transactions", txsArray);

        // Write to file
        string memory finalJson = vm.serializeString(obj, "chainId", vm.toString(chainId));
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
}
