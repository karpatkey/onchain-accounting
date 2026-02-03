// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {console2} from "forge-std/console2.sol";

/// @title UpgradeNAVCalculator
/// @notice Upgrades NAVCalculator implementation via Safe multisig
contract UpgradeNAVCalculator is BaseDeployScript {
    function run() public override {
        setUp();
        validateAddresses();

        console2.log("\n=== Upgrading NAVCalculator ===");

        // Get proxy address
        address proxy = readDeployedAddress("NAVCalculatorProxy");
        if (proxy == address(0)) {
            console2.log("ERROR: NAVCalculator proxy not deployed!");
            revert("Proxy not deployed");
        }
        console2.log("Proxy address:", proxy);

        // Get current implementation
        address currentImpl = readDeployedAddress("NAVCalculatorImplementation");
        console2.log("Current implementation:", currentImpl);

        // Step 1: Deploy new implementation
        console2.log("\nStep 1: Deploying new implementation...");
        vm.startBroadcast();
        NAVCalculator newImplementation = new NAVCalculator();
        vm.stopBroadcast();

        console2.log("New implementation deployed at:", address(newImplementation));

        // Check if implementation is different
        if (address(newImplementation) == currentImpl) {
            console2.log("\nWARNING: New implementation has same address as current!");
            console2.log("This likely means you haven't made any changes to the contract.");
        }

        // Save new implementation address
        string memory implName = string(abi.encodePacked("NAVCalculatorImplementation_v", vm.toString(block.timestamp)));
        saveDeployedAddress(implName, address(newImplementation));
        saveDeployedAddress("NAVCalculatorImplementation", address(newImplementation));

        // Step 2: Generate Safe transaction for upgrade
        console2.log("\nStep 2: Generating Safe transaction for upgrade...");

        SafeTxBuilder.Transaction[] memory transactions = new SafeTxBuilder.Transaction[](1);

        // Call upgradeToAndCall on the proxy (no initialization data needed)
        transactions[0] = SafeTxBuilder.call(
            proxy, 0, abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(newImplementation), ""))
        );

        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-upgrade-navcalc.json"));

        writeSafeTx(
            filename,
            "Upgrade NAVCalculator Implementation",
            string(
                abi.encodePacked(
                    "Upgrades NAVCalculator from ",
                    vm.toString(currentImpl),
                    " to ",
                    vm.toString(address(newImplementation))
                )
            ),
            transactions
        );

        console2.log("\n=== Upgrade Instructions ===");
        console2.log("1. Review changes between old and new implementation");
        console2.log("2. Go to Safe UI: https://app.safe.global");
        console2.log("3. Select your Safe:", chainConfig.safeMultisig);
        console2.log("4. New Transaction -> Transaction Builder -> Import JSON");
        console2.log("5. Upload file:", filename);
        console2.log("6. Review and execute the transaction");
        console2.log("\nOld implementation:", currentImpl);
        console2.log("New implementation:", address(newImplementation));
        console2.log("\nAfter execution:");
        console2.log("- Run verification script to verify new implementation");
        console2.log("- Test upgraded contract functionality");
        console2.log("===============================");
    }
}
