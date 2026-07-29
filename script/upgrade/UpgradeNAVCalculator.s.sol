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
    string internal constant LAYOUT_BASELINE = "script/upgrade/storage-layout/NAVCalculator.json";

    /// @notice Refuses to proceed unless the operator has run the storage-layout check against THIS baseline.
    /// @dev    A UUPS upgrade keeps the proxy's storage and replaces only the code, so an implementation that
    ///         assigns a different meaning to an occupied slot does not revert - it reinterprets live state from the
    ///         next block. This script had no layout check of any kind.
    ///
    ///         Solidity cannot compute a storage layout at runtime, so the real comparison lives in
    ///         `script/upgrade/check_storage_layout.py`. What this function CAN do is refuse a stale
    ///         acknowledgement: `STORAGE_LAYOUT_VERIFIED` must equal the keccak256 of the baseline file, which the
    ///         Python check prints only when it passes. A first version accepted the literal `1`, which forge
    ///         auto-loads from `.env` - so one line in an untracked file satisfied the gate permanently, on every
    ///         future upgrade, while logging exactly like a deliberate act. Keying it to the baseline's hash means
    ///         the value dies the moment the baseline changes.
    ///
    ///         Be clear about what remains unproven: if the baseline is unchanged but the SOURCE moved, the hash
    ///         still matches. This gate proves the operator ran the check against the current baseline, never that
    ///         the current source is compatible. Only the Python check is evidence of that.
    function _requireStorageLayoutVerified() internal view {
        bytes32 expected = keccak256(bytes(vm.readFile(LAYOUT_BASELINE)));
        string memory supplied = vm.envOr("STORAGE_LAYOUT_VERIFIED", string(""));
        if (keccak256(bytes(supplied)) == keccak256(bytes(vm.toString(expected)))) {
            console2.log("Storage layout: acknowledgement matches the committed baseline.");
            return;
        }
        console2.log("\nREFUSING TO UPGRADE: the storage layout has not been checked against this baseline.");
        console2.log("  A UUPS upgrade swaps code and KEEPS storage. A moved, removed or retyped variable");
        console2.log("  silently reinterprets live state on every chain this is applied to -- no revert, no log.");
        console2.log("  Run:   python3 script/upgrade/check_storage_layout.py");
        console2.log("  It prints the token to pass as STORAGE_LAYOUT_VERIFIED. Expected for this baseline:");
        console2.log("   ", vm.toString(expected));
        if (bytes(supplied).length != 0) {
            console2.log("  Supplied instead:", supplied);
            console2.log("  A mismatch usually means the baseline changed since you ran the check -- re-run it.");
        }
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

        // The canonical `NAVCalculatorImplementation` key is written here, deliberately, even though the proxy
        // does not point at this implementation yet.
        //
        // An earlier revision of this file renamed it to `...Pending` on the reasoning that the record should not
        // assert an untrue state. That was wrong, and review caught it: four consumers read the canonical key and
        // all of them want "the implementation we just deployed and must now verify", not "what the proxy currently
        // delegates to" -- `script/verify/VerifyEtherscan.s.sol`, `script/verify/sweeps/make_targets.py`,
        // `chainlib.CANONICAL_KEYS` (which gives `bytecode_audit.py` its artifact-name expectation) and
        // `snapshot_production.py`. Renaming the key silently pointed every one of them at the OLD implementation,
        // so this script's own "run verification" instruction would have re-verified the superseded contract and
        // reported success while the live one went unverified and unaudited. The rename also made
        // `verify_step.py 1.3` hard-fail a chain that had upgraded correctly.
        //
        // The residual inaccuracy -- a window where the record names an implementation the Safe has not yet
        // activated -- is real but strictly smaller, and it belongs to the tooling that interprets the key rather
        // than to the key itself. It is called out loudly below instead of being encoded in a name.
        string memory implName = string(abi.encodePacked("NAVCalculatorImplementation_v", vm.toString(block.timestamp)));
        saveDeployedAddress(implName, address(newImplementation));
        saveDeployedAddress("NAVCalculatorImplementation", address(newImplementation));

        console2.log("\nNOTE: the deployment record now names the implementation just deployed, which the proxy does");
        console2.log("      NOT yet delegate to. It becomes live only when the Safe batch below is executed.");
        console2.log("      Until then, preflight checks that compare the record against the proxy's EIP-1967 slot");
        console2.log("      (verify_step.py 1.3) will correctly report a mismatch. Confirm with:");
        console2.log(
            "        cast storage", proxy, "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
        );

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
        console2.log("- Confirm the proxy actually moved:");
        console2.log("    cast storage", proxy, "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc");
        console2.log("  It must equal the new implementation below. No JSON edit is needed -- the record already");
        console2.log("  names it, and every verification and audit tool reads it from there.");
        console2.log("- Run verification script to verify new implementation");
        console2.log("- Test upgraded contract functionality");
        console2.log("===============================");
    }
}
