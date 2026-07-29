// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {LibraryPins} from "../utils/LibraryPins.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {console2} from "forge-std/console2.sol";

/// @title UpgradeNAVCalculator
/// @notice Upgrades NAVCalculator implementation via Safe multisig
contract UpgradeNAVCalculator is BaseDeployScript {
    /// @notice Refuses to broadcast a NAVCalculator implementation that is not usable on THIS chain.
    /// @dev    This script does `new NAVCalculator()` inside a broadcast and then repoints a LIVE proxy at the
    ///         result, so an impl linked against the wrong library addresses is worse here than in the numbered
    ///         deploy scripts: there is already value behind the proxy.
    ///
    ///         The failure is quiet, not loud. `NAVCalculator`'s creation bytecode embeds whatever foundry.toml's
    ///         `libraries` array says, and the CREATE succeeds regardless of what lives at those addresses:
    ///           - on the 24 configured chains the pinned addresses ALREADY hold library bytecode, so nothing
    ///             reverts at any point. The impl deploys, the Safe TX is written, the upgrade executes, and the
    ///             proxy quietly DELEGATECALLs a library version nobody intended. That is the likely outcome.
    ///           - on a fresh chain, or after a pin regen that has not been deployed there yet, the pinned address
    ///             holds nothing and the first library call reverts — after the impl was broadcast and recorded.
    ///
    ///         Hence two kinds of assertion. The linkage pair mirrors `01_DeployImplementations` (and the CI guard
    ///         in `test/LibraryPinConsistency.t.sol`): the bytecode about to be broadcast must actually embed both
    ///         pins. `01`'s other two assertions — that each library's own CREATE2 address equals its pin — do not
    ///         transfer, because this script deploys via plain `new` (CREATE) and deploys no libraries at all. What
    ///         replaces them is the check `01` does not need: the pinned addresses must hold code ON THIS CHAIN,
    ///         since linked-but-empty is a DELEGATECALL into nothing.
    ///
    ///         Addresses come from `LibraryPins`, never hardcoded, so a pin regeneration propagates here with no
    ///         edit to this file.
    /// @param  implBytecode The creation bytecode this script is about to broadcast.
    function _assertPinnedLibrariesUsable(bytes memory implBytecode) internal view {
        require(
            LibraryPins.contains(implBytecode, LibraryPins.PRICE_FEED_LIB),
            "NAVCalculator impl not linked against pinned PriceFeedLib (foundry.toml `libraries` drift)"
        );
        require(
            LibraryPins.contains(implBytecode, LibraryPins.NAV_REGISTRY_LIB),
            "NAVCalculator impl not linked against pinned NAVRegistryLib (foundry.toml `libraries` drift)"
        );
        require(
            LibraryPins.PRICE_FEED_LIB.code.length > 0,
            "pinned PriceFeedLib has no code on this chain (deploy the libraries here before upgrading)"
        );
        require(
            LibraryPins.NAV_REGISTRY_LIB.code.length > 0,
            "pinned NAVRegistryLib has no code on this chain (deploy the libraries here before upgrading)"
        );
    }

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
        _assertPinnedLibrariesUsable(type(NAVCalculator).creationCode);
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
        console2.log("3. Select your Safe:", chainConfig.securityCouncil);
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
