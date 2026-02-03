// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @title DeployBridgeEscrow
/// @notice Deploys BridgeEscrow with UUPS proxy via Safe CREATE2
contract DeployBridgeEscrow is BaseDeployScript {
    using stdJson for string;

    function run() public override {
        setUp();
        validateAddresses();

        console2.log("\n=== Deploying BridgeEscrow ===");

        // Check if already deployed
        address existingProxy = readDeployedAddress("BridgeEscrowProxy");
        if (existingProxy != address(0) && existingProxy.code.length > 0) {
            console2.log("BridgeEscrow proxy already deployed at:", existingProxy);
            return;
        }

        // Step 1: Deploy implementation
        console2.log("\nStep 1: Deploying implementation...");
        vm.startBroadcast();
        BridgeEscrow implementation = new BridgeEscrow();
        vm.stopBroadcast();

        console2.log("Implementation deployed at:", address(implementation));
        saveDeployedAddress("BridgeEscrowImplementation", address(implementation));

        // Step 2: Read initial configuration from dev-input.json
        console2.log("\nStep 2: Reading configuration...");
        // Read initial accounts and adapters from chain config
        // For now, using empty arrays - these can be configured post-deployment
        address[] memory initialAccounts = new address[](0);
        address[] memory initialAdapters = new address[](0);

        console2.log("Initial accounts:", initialAccounts.length);
        console2.log("Initial adapters:", initialAdapters.length);

        // Step 3: Generate CREATE2 salt and compute proxy address
        console2.log("\nStep 3: Computing CREATE2 proxy address...");
        bytes32 salt = generateSalt("BridgeEscrowProxy", 1);

        // Prepare initialization data
        bytes memory initData = abi.encodeCall(
            BridgeEscrow.initialize,
            (
                chainConfig.admin,
                // forge-lint: disable-next-line(unsafe-typecast) - chain IDs fit in uint64
                uint64(currentChainId),
                initialAccounts,
                initialAdapters
            )
        );

        // Generate proxy creation bytecode
        bytes memory proxyBytecode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(implementation), initData));

        // Compute expected proxy address (deployed by Safe via delegatecall)
        address expectedProxy = computeCreate2Address(chainConfig.safeMultisig, salt, proxyBytecode);

        console2.log("Expected proxy address:", expectedProxy);
        console2.log("Salt:", vm.toString(salt));

        // Step 4: Generate Safe transaction for CREATE2 deployment
        console2.log("\nStep 4: Generating Safe transaction...");

        // Get Create2Deployer address
        address create2Deployer = readDeployedAddress("Create2Deployer");
        if (create2Deployer == address(0)) {
            console2.log("\nERROR: Create2Deployer not deployed on this chain!");
            console2.log("Run: forge script script/deploy/00_DeployCreate2Deployer.s.sol --broadcast");
            revert("Create2Deployer not deployed");
        }

        // Build Safe transaction for delegatecall to Create2Deployer
        SafeTxBuilder.Transaction[] memory transactions = new SafeTxBuilder.Transaction[](1);
        transactions[0] = SafeTxBuilder.delegateCall(
            create2Deployer, abi.encodeWithSignature("deploy(bytes32,bytes)", salt, proxyBytecode)
        );

        string memory filename =
            string(abi.encodePacked(vm.toString(currentChainId), "-deploy-bridgeescrow-proxy.json"));

        writeSafeTx(
            filename,
            "Deploy BridgeEscrow Proxy via CREATE2",
            string(
                abi.encodePacked(
                    "Deploys BridgeEscrow proxy at deterministic address: ",
                    vm.toString(expectedProxy),
                    ". This delegatecall makes Safe the deployer, ensuring the same address across all chains."
                )
            ),
            transactions
        );

        // Save expected proxy address
        saveDeployedAddress("BridgeEscrowProxy", expectedProxy);

        console2.log("\n=== Deployment Instructions ===");
        console2.log("1. Go to Safe UI: https://app.safe.global");
        console2.log("2. Select your Safe:", chainConfig.safeMultisig);
        console2.log("3. New Transaction -> Transaction Builder -> Import JSON");
        console2.log("4. Upload file:", filename);
        console2.log("5. Review and execute the transaction");
        console2.log("\nAfter execution:");
        console2.log("- Proxy will be deployed at:", expectedProxy);
        console2.log("- Proxy will be initialized with admin:", chainConfig.admin);
        console2.log("- Chain ID:", currentChainId);
        console2.log("- Run verification script to verify on Etherscan");
        console2.log("\n=================================");
    }
}
