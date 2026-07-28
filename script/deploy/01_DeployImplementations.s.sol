// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {LibraryPins} from "../utils/LibraryPins.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {PriceFeedLib} from "../../src/prices/PriceFeedLib.sol";
import {NAVRegistryLib} from "../../src/nav/NAVRegistryLib.sol";
import {DeploySalts} from "./DeploySalts.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployImplementations
/// @notice Deploys PriceFeedLib + NAVRegistryLib (libraries), NAVCalculator, and BridgeEscrow implementations
///         (CREATE2) via an EOA broadcast.
/// @dev Uses canonical CREATE2 deployer (0x4e59...) with calldata = salt || init_code (Arachnid format).
///      Run with --broadcast --account $DEPLOYER_NAME: deploys via the deployer EOA (skips any already deployed),
///      then saves addresses. PriceFeedLib and NAVRegistryLib must be deployed before NAVCalculator because
///      NAVCalculator's bytecode references them via DELEGATECALL.
contract DeployImplementations is BaseDeployScript {
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    struct ImplPlan {
        address priceFeedLib;
        address navRegistryLib;
        address navImpl;
        address bridgeImpl;
        bytes priceFeedLibBytecode;
        bytes navRegistryLibBytecode;
        bytes navImplBytecode;
        bytes bridgeImplBytecode;
        bytes32 saltPriceFeedLib;
        bytes32 saltNavRegistryLib;
        bytes32 saltNavImpl;
        bytes32 saltBridgeImpl;
    }

    function run() public override {
        setUp();
        validateAddresses();

        ImplPlan memory plan = _computeImplPlan();

        // Fail fast if the library bytecode no longer maps to the addresses NAVCalculator is linked against. The
        // libraries then deploy SUCCESSFULLY at their COMPUTED (unpinned) addresses — the CREATE2 does not fail, so
        // `require(ok, ...)` below never fires — and the impl links the PINNED addresses instead. Two outcomes,
        // and the quiet one is the likelier:
        //   - fresh chain (nothing at the pinned addresses): `initialize()` reverts on the first library call
        //     (`call to non-contract address`), after the deploy was broadcast and recorded;
        //   - a chain that ALREADY holds the current pinned libraries — all 24 configured chains do — NOTHING reverts.
        //     A library-only source change leaves `NAVCalculator.creationCode` untouched (it embeds the unchanged
        //     pins), so the impl address is unchanged and this script logs `[SKIP] NAV implementation already at:`,
        //     the two new libraries land at their computed addresses as orphans, `_saveAndLog` overwrites
        //     `deployments/<id>.json` with those orphans, and the NAV keeps DELEGATECALLing the OLD library code.
        //     Silent wrong-version, which is why an assertion and not an eyeball is what is wanted here.
        //
        // These are the four assertions `01_2_DeployNAVImplementation` carries in its own `run()` — added there in
        // `62311fb7` and `a8d5dd73`, not from the start. `01` had none at all, so it was the only NUMBERED PROD NAV
        // deploy script that could broadcast library-linked bytecode unchecked. It is NOT the only script that can:
        // `script/upgrade/UpgradeNAVCalculator` does `new NAVCalculator()` inside a broadcast with no pin
        // check and then repoints a LIVE proxy at it, `UpgradeBridgeEscrow` and `05_DeployBridgeAdapters`
        // broadcast `InvoiceDataLib`-linked bytecode, and `01` still broadcasts the `InvoiceDataLib`-linked
        // `BridgeEscrow` impl below (that library is not pinned at all — see this PR's discussion).
        //
        // Copied rather than hoisted into `BaseDeployScript` for ONE reason only: in the shared base they would go red
        // on every branch whenever a pin regen is in flight, and would fire for `06_Configure`, `RegisterAssets` and
        // the `verify` scripts, which deploy nothing. The `upgrade` scripts are NOT such a case — they DO extend
        // `BaseDeployScript` and DO deploy library-linked bytecode, so hoisting would have covered them; they need a
        // different check anyway (they deploy via plain `new`, so assertions 1-2 do not apply — what they need is the
        // linkage assertions plus "the pinned address has code on THIS chain").
        //
        // This checks the OUTCOME — does the bytecode about to be broadcast map to the pins? — rather than trying to
        // enumerate the causes of a bad build. That distinction is why it supersedes the profile/env guard attempted in
        // PR #188; see this PR's description for the evidence that enumeration could not be completed.
        //
        // LibraryPins is the single Solidity source of truth for these pins (shared with the CI guard in
        // test/LibraryPinConsistency.t.sol); if these fire the library bytecode drifted — regenerate the pins
        // (LibraryPins + foundry.toml) for the pinned solc + bytecode_hash.
        require(
            plan.priceFeedLib == LibraryPins.PRICE_FEED_LIB,
            "PriceFeedLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)"
        );
        require(
            plan.navRegistryLib == LibraryPins.NAV_REGISTRY_LIB,
            "NAVRegistryLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)"
        );

        // End-to-end: the NAVCalculator impl bytecode about to be broadcast must actually be linked against both
        // pinned addresses. The two checks above only confirm the libs' own bytecode maps to LibraryPins; if
        // foundry.toml `libraries` drifts from LibraryPins, those still pass but NAVCalculator would DELEGATECALL the
        // wrong (empty) address and revert on initialize(). Mirrors the CI guard in test/LibraryPinConsistency.t.sol.
        require(
            LibraryPins.contains(plan.navImplBytecode, LibraryPins.PRICE_FEED_LIB),
            "NAVCalculator impl not linked against pinned PriceFeedLib (foundry.toml `libraries` drift)"
        );
        require(
            LibraryPins.contains(plan.navImplBytecode, LibraryPins.NAV_REGISTRY_LIB),
            "NAVCalculator impl not linked against pinned NAVRegistryLib (foundry.toml `libraries` drift)"
        );

        // EOA deploy: broadcast the four CREATE2 deploys (PriceFeedLib, NAVRegistryLib, NAVCalculator impl,
        // BridgeEscrow impl) directly via the deployer private key. Same deterministic addresses on every chain.
        // Run once (e.g. on mainnet), then run 02 per chain for proxies + init.
        vm.startBroadcast();
        _deployIfNeeded(plan);
        vm.stopBroadcast();

        _saveAndLog(plan);
    }

    function _computeImplPlan() internal pure returns (ImplPlan memory plan) {
        plan.saltPriceFeedLib = generateSalt("PriceFeedLib", 1);
        plan.priceFeedLibBytecode = type(PriceFeedLib).creationCode;
        plan.priceFeedLib =
            computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, plan.saltPriceFeedLib, plan.priceFeedLibBytecode);

        plan.saltNavRegistryLib = generateSalt("NavRegistryLib", 1);
        plan.navRegistryLibBytecode = type(NAVRegistryLib).creationCode;
        plan.navRegistryLib =
            computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, plan.saltNavRegistryLib, plan.navRegistryLibBytecode);

        plan.saltNavImpl = generateSalt("NAVCalculatorImplementation", DeploySalts.NAV_IMPL);
        plan.navImplBytecode = type(NAVCalculator).creationCode;
        plan.navImpl = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, plan.saltNavImpl, plan.navImplBytecode);

        plan.saltBridgeImpl = generateSalt("BridgeEscrowImplementation", 1);
        plan.bridgeImplBytecode = type(BridgeEscrow).creationCode;
        plan.bridgeImpl =
            computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, plan.saltBridgeImpl, plan.bridgeImplBytecode);
    }

    function _deployIfNeeded(ImplPlan memory plan) internal {
        if (plan.priceFeedLib.code.length == 0) {
            (bool ok,) =
                CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(plan.saltPriceFeedLib, plan.priceFeedLibBytecode));
            require(ok, "PriceFeedLib deploy failed");
            console2.log("[OK] PriceFeedLib deployed at:", plan.priceFeedLib);
        } else {
            console2.log("[SKIP] PriceFeedLib already at:", plan.priceFeedLib);
        }

        if (plan.navRegistryLib.code.length == 0) {
            (bool ok,) =
                CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(plan.saltNavRegistryLib, plan.navRegistryLibBytecode));
            require(ok, "NAVRegistryLib deploy failed");
            console2.log("[OK] NAVRegistryLib deployed at:", plan.navRegistryLib);
        } else {
            console2.log("[SKIP] NAVRegistryLib already at:", plan.navRegistryLib);
        }

        if (plan.navImpl.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(plan.saltNavImpl, plan.navImplBytecode));
            require(ok, "NAV impl deploy failed");
            console2.log("[OK] NAV implementation deployed at:", plan.navImpl);
        } else {
            console2.log("[SKIP] NAV implementation already at:", plan.navImpl);
        }

        if (plan.bridgeImpl.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(plan.saltBridgeImpl, plan.bridgeImplBytecode));
            require(ok, "Bridge impl deploy failed");
            console2.log("[OK] Bridge implementation deployed at:", plan.bridgeImpl);
        } else {
            console2.log("[SKIP] Bridge implementation already at:", plan.bridgeImpl);
        }
    }

    /// @dev Saves implementation addresses to config and logs the deployment summary.
    function _saveAndLog(ImplPlan memory plan) internal {
        saveDeployedAddress("PriceFeedLib", plan.priceFeedLib);
        saveDeployedAddress("NavRegistryLib", plan.navRegistryLib);
        saveDeployedAddress("NAVCalculatorImplementation", plan.navImpl);
        saveDeployedAddress("BridgeEscrowImplementation", plan.bridgeImpl);

        console2.log("\n=== Implementation Deployment ===");
        console2.log("Chain ID:", currentChainId);
        console2.log("  PriceFeedLib:", plan.priceFeedLib);
        console2.log("  NAVRegistryLib:", plan.navRegistryLib);
        console2.log("  NAV Implementation:", plan.navImpl);
        console2.log("  Bridge Implementation:", plan.bridgeImpl);
        console2.log("Addresses saved to config. Run 02_DeployProxies.s.sol per chain.");
    }
}
