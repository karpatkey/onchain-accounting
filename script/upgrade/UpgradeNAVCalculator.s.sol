// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {console2} from "forge-std/console2.sol";

/// @title UpgradeNAVCalculator
/// @notice Upgrades NAVCalculator implementation via Safe multisig
contract UpgradeNAVCalculator is BaseDeployScript {
    /// @notice Refuses to proceed unless the operator has run the storage-layout check.
    /// @dev    A UUPS upgrade keeps the proxy's storage and replaces only the code, so an implementation that
    ///         assigns a different meaning to an occupied slot does not revert — it reinterprets live state from the
    ///         next block. This script had no layout check of any kind.
    ///
    ///         Solidity cannot compute a storage layout at runtime, so this is an ACKNOWLEDGEMENT, not a proof: it
    ///         forces the operator through `script/upgrade/check_storage_layout.py`, which does the real comparison
    ///         against the committed baseline and exits non-zero on anything but an append. Stated plainly because a
    ///         gate that looks like a proof and is not is worse than none — do not read a passing run here as
    ///         evidence the layout is compatible. Only the Python check is evidence.
    function _requireStorageLayoutVerified() internal view {
        if (vm.envOr("STORAGE_LAYOUT_VERIFIED", uint256(0)) == 1) {
            console2.log("Storage layout: operator asserts check_storage_layout.py passed on this tree.");
            return;
        }
        console2.log("\nREFUSING TO UPGRADE: the storage layout has not been checked.");
        console2.log("  A UUPS upgrade swaps code and KEEPS storage. A moved, removed or retyped variable");
        console2.log("  silently reinterprets live state on every chain this is applied to -- no revert, no log.");
        console2.log("  Run:      python3 script/upgrade/check_storage_layout.py");
        console2.log("  Then:     STORAGE_LAYOUT_VERIFIED=1 forge script <this script> ...");
        revert("storage layout unverified: see script/upgrade/check_storage_layout.py");
    }

    function run() public override {
        setUp();
        validateAddresses();

        console2.log("\n=== Upgrading NAVCalculator ===");

        _requireStorageLayoutVerified();

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

        // Is this upgrade a no-op? The previous check compared ADDRESSES, which can never match: `new` is CREATE,
        // whose address derives from the deployer's ever-incrementing nonce, so a fresh deploy cannot land on an
        // existing one. It was unreachable, and its absence read as "the contract changed" every time.
        // Comparing CODE answers the question that was actually being asked.
        if (currentImpl != address(0) && currentImpl.code.length > 0) {
            if (keccak256(address(newImplementation).code) == keccak256(currentImpl.code)) {
                console2.log("\nWARNING: the new implementation's runtime code is IDENTICAL to the current one.");
                console2.log("This upgrade would change nothing. Check you rebuilt after editing the source.");
            }
        }

        // Record the implementation as PENDING, not as the live one.
        //
        // Nothing has been upgraded at this point: the proxy still delegates to `currentImpl` and will keep doing so
        // until a Safe owner executes the batch written below, which may be hours later or never. Writing the
        // canonical `NAVCalculatorImplementation` key here made the deployment record — per CLAUDE.md the only place
        // addresses live — assert a state that is not yet true, and the record is what the preflight audits diff
        // against: `verify_step.py 1.3` compares the proxy's EIP-1967 slot to this key, and `bytecode_audit.py`
        // resolves it. Both would have reported drift against an upgrade that had not happened, or agreement with one
        // that silently failed.
        string memory implName = string(abi.encodePacked("NAVCalculatorImplementation_v", vm.toString(block.timestamp)));
        saveDeployedAddress(implName, address(newImplementation));
        saveDeployedAddress("NAVCalculatorImplementationPending", address(newImplementation));

        // Step 2: Generate Safe transaction for upgrade
        console2.log("\nStep 2: Generating Safe transaction for upgrade...");

        SafeTxBuilder.Transaction[] memory transactions = new SafeTxBuilder.Transaction[](1);

        // Call upgradeToAndCall on the proxy (no initialization data needed)
        transactions[0] = SafeTxBuilder.call(
            proxy, 0, abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(newImplementation), ""))
        );

        // The filename carries the target implementation. It used to be `<chainId>-upgrade-navcalc.json` for every
        // run on a chain, so a second run silently overwrote the first — including a batch already circulating for
        // signature. Safe owners would then be reviewing a file whose contents had changed underneath them, with
        // nothing in the UI or the filename to indicate it. `newImplementation` is unique per run (CREATE, from an
        // incrementing nonce), so this both prevents the collision and names the batch after what it does.
        string memory filename = string(
            abi.encodePacked(
                vm.toString(currentChainId), "-upgrade-navcalc-", vm.toString(address(newImplementation)), ".json"
            )
        );

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
        console2.log("- Confirm the proxy actually moved, then PROMOTE the recorded address:");
        console2.log("    cast storage", proxy, "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc");
        console2.log("  It must equal the new implementation below. Only then set");
        console2.log("  .NAVCalculatorImplementation in script/config/deployments/<chainId>.json to it and");
        console2.log("  clear .NAVCalculatorImplementationPending. Until you do, the record correctly still");
        console2.log("  describes the OLD implementation, which is what is actually running.");
        console2.log("- Run verification script to verify new implementation");
        console2.log("- Test upgraded contract functionality");
        console2.log("===============================");
    }
}
