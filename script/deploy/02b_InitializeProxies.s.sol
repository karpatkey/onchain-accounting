// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {console2} from "forge-std/console2.sol";

/// @title InitializeProxies
/// @notice Generates Safe transactions per chain: initialize NAV + Bridge proxies (proxies must be deployed first via 02a_DeployProxies.s.sol).
/// @dev Run after 02a_DeployProxies has been executed. Run this script per chain (--chain-id) for chain-specific init.
///      This script only generates initialization transactions for the Safe.
contract InitializeProxies is BaseDeployScript {
    function run() public override {
        setUp();
        validateAddresses();

        // Read proxy addresses from config (deployed by EOA via 02a_DeployProxies.s.sol)
        address navProxy = readDeployedAddress("NAVCalculatorProxy");
        address bridgeProxy = readDeployedAddress("BridgeEscrowProxy");

        // Verify proxy addresses are configured
        require(navProxy != address(0), "NAVCalculator proxy address not found. Run 02a_DeployProxies.s.sol first.");
        require(bridgeProxy != address(0), "BridgeEscrow proxy address not found. Run 02a_DeployProxies.s.sol first.");

        bytes memory navInitData = abi.encodeCall(
            NAVCalculator.initialize,
            (chainConfig.admin, chainConfig.chainlinkSequencerFeed, chainConfig.nativeTokenSymbol)
        );
        address[] memory initialAccounts = new address[](0);
        address[] memory initialAdapters = new address[](0);
        bytes memory bridgeInitData = abi.encodeCall(
            BridgeEscrow.initialize,
            (
                chainConfig.admin,
                // casting to 'uint64' is safe because we check currentChainId <= type(uint64).max first
                // forge-lint: disable-next-line(unsafe-typecast)
                currentChainId > type(uint64).max ? uint64(0) : uint64(currentChainId),
                initialAccounts,
                initialAdapters
            )
        );

        // Create array of 2 transactions for initialization only
        // Proxies should already be deployed via 02a_DeployProxies.s.sol
        SafeTxBuilder.Transaction[] memory allTxs = new SafeTxBuilder.Transaction[](2);

        // 1. Initialize NAV proxy via CALL
        allTxs[0] = SafeTxBuilder.call(navProxy, 0, navInitData);

        // 2. Initialize Bridge proxy via CALL
        allTxs[1] = SafeTxBuilder.call(bridgeProxy, 0, bridgeInitData);

        // Generate transaction file with initialization transactions only
        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-initialize-proxies.json"));
        SafeTxBuilder.writeSafeTx(
            vm,
            currentChainId,
            filename,
            "Initialize NAVCalculator + BridgeEscrow proxies",
            string(
                abi.encodePacked(
                    "Chain ",
                    vm.toString(currentChainId),
                    ": initialize NAV + Bridge proxies. ",
                    "Proxies must be deployed first via 02a_DeployProxies.s.sol. ",
                    "NAV proxy: ",
                    vm.toString(navProxy),
                    ", Bridge proxy: ",
                    vm.toString(bridgeProxy)
                )
            ),
            chainConfig.safeMultisig,
            allTxs
        );

        // Note: All operations are CALL (0), no DELEGATECALL needed

        console2.log("\n=== Transaction File Generated ===");
        console2.log("File: safe-transactions/", filename);
        console2.log("\nThis transaction file contains 2 individual transactions:");
        console2.log("  1. CALL: Initialize NAVCalculator proxy");
        console2.log("  2. CALL: Initialize BridgeEscrow proxy");
        console2.log("\n[NOTE] Proxies must be deployed first via 02a_DeployProxies.s.sol");
        console2.log("\n=== Safe CLI Command (Ready to Execute) ===");
        console2.log("Using tx-builder command:");
        string memory txBuilderCommand = string(
            abi.encodePacked(
                "safe-cli tx-builder ",
                vm.toString(chainConfig.safeMultisig),
                " ",
                chainConfig.rpc,
                " ./safe-transactions/",
                filename,
                " --private-key <KEY1> --private-key <KEY2> [--non-interactive]"
            )
        );
        console2.log(txBuilderCommand);
        console2.log("\n[INFO] This transaction file contains multiple individual transactions (not MultiSend).");
        console2.log("  The Safe UI will execute them as a batch. All operations use CALL (no DELEGATECALL required).");
        console2.log("\n  To simulate transactions before submission, run:");
        console2.log("    forge test --match-path script/test/SimulateSafeTransactions.fork.t.sol --fork-url <RPC_URL>");

        console2.log("\nProxy addresses (from deployment config):");
        console2.log("  NAVCalculator proxy:", navProxy);
        console2.log("  BridgeEscrow proxy:", bridgeProxy);
        console2.log("\nRun this script per chain (--chain-id <id>), then execute the transaction on that chain.");
    }
}
