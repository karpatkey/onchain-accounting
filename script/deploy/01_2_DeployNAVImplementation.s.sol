// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {LibraryPins} from "../utils/LibraryPins.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {PriceFeedLib} from "../../src/prices/PriceFeedLib.sol";
import {NavRegistryLib} from "../../src/nav/NavRegistryLib.sol";
import {DeploySalts} from "./DeploySalts.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployNAVImplementation
/// @notice Deploys PriceFeedLib + NavRegistryLib (external libraries) then the NAVCalculator implementation, via an
///         EOA broadcast through the canonical CREATE2 deployer.
/// @dev Uses canonical CREATE2 deployer (0x4e59...) with calldata = salt || init_code (Arachnid format).
///      Run with --broadcast --account $DEPLOYER_NAME: deploys via the deployer EOA (skips any already deployed),
///      then saves addresses to config. Same implementation address on all chains — run once, then run
///      02_2_DeployNAVProxy.s.sol per chain.
///      PriceFeedLib and NavRegistryLib must be deployed before NAVCalculator because NAVCalculator's bytecode
///      references them via DELEGATECALL.
contract DeployNAVImplementation is BaseDeployScript {
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    struct ImplPlan {
        address priceFeedLib;
        bytes priceFeedLibBytecode;
        bytes32 saltPriceFeedLib;
        address navRegistryLib;
        bytes navRegistryLibBytecode;
        bytes32 saltNavRegistryLib;
        address navImpl;
        bytes navImplBytecode;
        bytes32 saltNavImpl;
    }

    function run() public override {
        setUp();
        validateAddresses();

        ImplPlan memory plan = _computeImplPlan();

        // Fail fast if the library bytecode no longer maps to the addresses NAVCalculator is linked
        // against — otherwise NAV would deploy fine but revert on initialize (DELEGATECALL to empty code).
        // LibraryPins is the single Solidity source of truth for these pins (shared with the CI guard in
        // test/LibraryPinConsistency.t.sol); if these fire the library bytecode drifted — regenerate the pins
        // (LibraryPins + foundry.toml) for the pinned solc + bytecode_hash.
        require(
            plan.priceFeedLib == LibraryPins.PRICE_FEED_LIB,
            "PriceFeedLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)"
        );
        require(
            plan.navRegistryLib == LibraryPins.NAV_REGISTRY_LIB,
            "NavRegistryLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)"
        );

        // End-to-end: the NAVCalculator impl bytecode about to be broadcast must actually be linked against
        // both pinned addresses. The two checks above only confirm the libs' own bytecode maps to LibraryPins;
        // if foundry.toml `libraries` drifts from LibraryPins, those still pass but NAVCalculator would
        // DELEGATECALL the wrong (empty) address and revert on initialize(). Mirrors the CI guard in
        // test/LibraryPinConsistency.t.sol.
        require(
            LibraryPins.contains(plan.navImplBytecode, LibraryPins.PRICE_FEED_LIB),
            "NAVCalculator impl not linked against pinned PriceFeedLib (foundry.toml `libraries` drift)"
        );
        require(
            LibraryPins.contains(plan.navImplBytecode, LibraryPins.NAV_REGISTRY_LIB),
            "NAVCalculator impl not linked against pinned NavRegistryLib (foundry.toml `libraries` drift)"
        );

        // EOA deploy: broadcast the three CREATE2 deploys (PriceFeedLib, NavRegistryLib, NAVCalculator impl) directly
        // via the deployer private key. Same deterministic addresses on every chain. Run once, then 02_2 per chain.
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

        // NOTE: NavRegistryLib is DELEGATECALL'd by NAVCalculator during initialize() (registerAsset), so the
        // address NAVCalculator is linked against (the foundry.toml `libraries` pin) MUST equal the CREATE2 address
        // computed here, or NAV init reverts on-chain. Same requirement as PriceFeedLib. Before signing the Safe
        // batch, confirm `plan.navRegistryLib` (logged below) matches the foundry.toml pin; if they diverge (e.g.
        // after a library source change shifts the bytecode), update the pin and rebuild so the link is consistent.
        plan.saltNavRegistryLib = generateSalt("NavRegistryLib", 1);
        plan.navRegistryLibBytecode = type(NavRegistryLib).creationCode;
        plan.navRegistryLib =
            computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, plan.saltNavRegistryLib, plan.navRegistryLibBytecode);

        plan.saltNavImpl = generateSalt("NAVCalculatorImplementation", DeploySalts.NAV_IMPL);
        plan.navImplBytecode = type(NAVCalculator).creationCode;
        plan.navImpl = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, plan.saltNavImpl, plan.navImplBytecode);
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
            require(ok, "NavRegistryLib deploy failed");
            console2.log("[OK] NavRegistryLib deployed at:", plan.navRegistryLib);
        } else {
            console2.log("[SKIP] NavRegistryLib already at:", plan.navRegistryLib);
        }

        if (plan.navImpl.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(plan.saltNavImpl, plan.navImplBytecode));
            require(ok, "NAV impl deploy failed");
            console2.log("[OK] NAV implementation deployed at:", plan.navImpl);
        } else {
            console2.log("[SKIP] NAV implementation already at:", plan.navImpl);
        }
    }

    function _saveAndLog(ImplPlan memory plan) internal {
        saveDeployedAddress("PriceFeedLib", plan.priceFeedLib);
        saveDeployedAddress("NavRegistryLib", plan.navRegistryLib);
        saveDeployedAddress("NAVCalculatorImplementation", plan.navImpl);

        console2.log("\n=== NAV Implementation Deployment ===");
        console2.log("Chain ID:", currentChainId);
        console2.log("  PriceFeedLib:", plan.priceFeedLib);
        console2.log("  NavRegistryLib:", plan.navRegistryLib);
        console2.log("  NAV Implementation:", plan.navImpl);
        console2.log("Addresses saved to config. Run 02_2_DeployNAVProxy.s.sol per chain.");
    }
}
