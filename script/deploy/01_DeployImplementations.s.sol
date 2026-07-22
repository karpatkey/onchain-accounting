// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
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

        // Bridge-only mode: for a clean bridge redeploy on a chain where NAV is already LIVE, deploy + persist ONLY
        // the (freshly re-addressed) BridgeEscrow impl. The NAV impl + libraries are left untouched — neither
        // re-deployed nor re-saved — so this branch's differing NAV/lib bytecode can't overwrite the live NAV
        // implementation/library addresses recorded in deployments/<chainId>.json.
        bool bridgeOnly = vm.envOr("BRIDGE_ONLY_IMPL", false);

        // EOA deploy: broadcast the CREATE2 deploys directly via the deployer private key. Same deterministic
        // addresses on every chain. Run once (e.g. on mainnet), then run 02 per chain for proxies + init.
        vm.startBroadcast();
        _deployIfNeeded(plan, bridgeOnly);
        vm.stopBroadcast();

        _saveAndLog(plan, bridgeOnly);
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

    function _deployIfNeeded(ImplPlan memory plan, bool bridgeOnly) internal {
        if (!bridgeOnly) {
            if (plan.priceFeedLib.code.length == 0) {
                (bool ok,) =
                    CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(plan.saltPriceFeedLib, plan.priceFeedLibBytecode));
                require(ok, "PriceFeedLib deploy failed");
                console2.log("[OK] PriceFeedLib deployed at:", plan.priceFeedLib);
            } else {
                console2.log("[SKIP] PriceFeedLib already at:", plan.priceFeedLib);
            }

            if (plan.navRegistryLib.code.length == 0) {
                (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(
                    abi.encodePacked(plan.saltNavRegistryLib, plan.navRegistryLibBytecode)
                );
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
        } else {
            console2.log("[BRIDGE-ONLY] Skipping PriceFeedLib / NAVRegistryLib / NAV impl (NAV untouched)");
        }

        if (plan.bridgeImpl.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(plan.saltBridgeImpl, plan.bridgeImplBytecode));
            require(ok, "Bridge impl deploy failed");
            console2.log("[OK] Bridge implementation deployed at:", plan.bridgeImpl);
        } else {
            console2.log("[SKIP] Bridge implementation already at:", plan.bridgeImpl);
        }
    }

    /// @dev Saves implementation addresses to config and logs the deployment summary. In bridge-only mode, ONLY the
    ///      BridgeEscrow impl address is persisted — the NAV impl + library addresses recorded for a live NAV
    ///      deployment are left as-is (this branch's differing bytecode must not overwrite them).
    function _saveAndLog(ImplPlan memory plan, bool bridgeOnly) internal {
        if (!bridgeOnly) {
            saveDeployedAddress("PriceFeedLib", plan.priceFeedLib);
            saveDeployedAddress("NavRegistryLib", plan.navRegistryLib);
            saveDeployedAddress("NAVCalculatorImplementation", plan.navImpl);
        }
        saveDeployedAddress("BridgeEscrowImplementation", plan.bridgeImpl);

        console2.log("\n=== Implementation Deployment ===");
        console2.log("Chain ID:", currentChainId);
        if (!bridgeOnly) {
            console2.log("  PriceFeedLib:", plan.priceFeedLib);
            console2.log("  NAVRegistryLib:", plan.navRegistryLib);
            console2.log("  NAV Implementation:", plan.navImpl);
        }
        console2.log("  Bridge Implementation:", plan.bridgeImpl);
        console2.log("Addresses saved to config. Run 02_DeployProxies.s.sol per chain.");
    }
}
