// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {LibraryPins} from "../utils/LibraryPins.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {PriceFeedLib} from "../../src/prices/PriceFeedLib.sol";
import {NAVRegistryLib} from "../../src/nav/NAVRegistryLib.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {console2} from "forge-std/console2.sol";

/// @title UpgradeNAVCalculator
/// @notice Upgrades NAVCalculator implementation via Safe multisig
contract UpgradeNAVCalculator is BaseDeployScript {
    /// @dev Same constant `01_DeployImplementations` uses; the pins are CREATE2 addresses from this factory.
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

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
    ///         Hence three kinds of assertion, all six of which must hold. `01_DeployImplementations` carries the
    ///         first two families; the third is specific to upgrading.
    ///
    ///         Addresses come from `LibraryPins`, never hardcoded, so a pin regeneration propagates here with no
    ///         edit to this file.
    /// @param  implBytecode The creation bytecode this script is about to broadcast.
    function _assertPinnedLibrariesUsable(bytes memory implBytecode) internal view {
        _assertLibrarySourceMatchesPins();
        _assertImplLinkedAndLibrariesPresent(implBytecode);
    }

    /// @notice The pins must still correspond to the library source in THIS tree.
    /// @dev    Transferred verbatim from `01_DeployImplementations`. An earlier revision of this script omitted
    ///         these two on the grounds that it "deploys via plain `new` and deploys no libraries at all" — that
    ///         reasoning was wrong, and reviewers were right to reject it. These assertions are pure functions of
    ///         `type(PriceFeedLib).creationCode`, the canonical CREATE2 deployer and the salt; they say nothing
    ///         about who deploys what. What they answer is whether the pinned address still corresponds to the
    ///         library source here — and that is the ONLY one of the six checks that can catch a stale pin.
    ///
    ///         The other two families are structurally blind to it. `contains(implBytecode, PIN)` reads
    ///         foundry.toml's `libraries` back out of the bytecode foundry.toml just produced, so it detects
    ///         foundry.toml <-> LibraryPins disagreement and nothing else; it can never detect "both agree, and
    ///         both are stale". And `PIN.code.length > 0` is satisfied BY CONSTRUCTION in that case — the old
    ///         library is deployed at the old pin on all 24 chains, which is precisely why it is the old pin.
    ///
    ///         Without this, a library source change with no pin regeneration passes every other check: the impl
    ///         links the old pin, the old library answers there, and the live proxy is repointed at an
    ///         implementation DELEGATECALLing pre-change library code while the deployment record and the Safe TX
    ///         description both assert the new implementation shipped.
    ///
    ///         This goes red on any branch with a pin regeneration in flight. That is correct, not a nuisance:
    ///         upgrading a live proxy from such a tree is exactly the thing to refuse.
    function _assertLibrarySourceMatchesPins() internal view {
        require(
            computeCreate2Address(
                CANONICAL_CREATE2_DEPLOYER, generateSalt("PriceFeedLib", 1), type(PriceFeedLib).creationCode
            ) == LibraryPins.PRICE_FEED_LIB,
            "PriceFeedLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)"
        );
        require(
            computeCreate2Address(
                CANONICAL_CREATE2_DEPLOYER, generateSalt("NavRegistryLib", 1), type(NAVRegistryLib).creationCode
            ) == LibraryPins.NAV_REGISTRY_LIB,
            "NAVRegistryLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)"
        );
    }

    /// @notice The bytecode about to be broadcast must embed both pins, and both must hold code on this chain.
    /// @dev    The linkage pair mirrors `01_DeployImplementations` and the CI guard in
    ///         `test/LibraryPinConsistency.t.sol`. The code-presence pair is what `01` does not need and this
    ///         script does: `01` CREATE2-deploys the libraries itself, whereas this script deploys none, so
    ///         linked-but-empty here is a DELEGATECALL into nothing on the first library call — after the impl was
    ///         broadcast and the Safe TX written.
    function _assertImplLinkedAndLibrariesPresent(bytes memory implBytecode) internal view {
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

    /// @notice Deploys the new implementation, guard first. The ONLY path in this script that broadcasts.
    /// @dev    A separate function so the guard and the broadcast cannot drift apart: the coverage gap reviewers
    ///         found in the first revision was that deleting the guard CALL — not blanking its body — left every
    ///         test green. `test_guardedDeploy_reverts_whenPinnedLibrariesAbsent` fails if this call is removed or
    ///         moved below the broadcast, because `new NAVCalculator()` succeeds happily with absent libraries
    ///         (a DELEGATECALL into nothing only reverts on first use, long after this script is done).
    function _deployGuardedNavImplementation() internal returns (NAVCalculator impl) {
        _assertPinnedLibrariesUsable(type(NAVCalculator).creationCode);
        vm.startBroadcast();
        impl = new NAVCalculator();
        vm.stopBroadcast();
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
        NAVCalculator newImplementation = _deployGuardedNavImplementation();

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
