// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {PriceFeedLib} from "../../src/prices/PriceFeedLib.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployImplementations
/// @notice Deploys PriceFeedLib, NAVCalculator, and BridgeEscrow implementations (CREATE2). Safe JSON and/or EOA broadcast.
/// @dev Uses canonical CREATE2 deployer (0x4e59...) with calldata = salt || init_code (Arachnid format).
///      Run without --broadcast: generates safe-transactions/{chainId}-deploy-implementations.json and saves addresses.
///      Run with --broadcast --account $DEPLOYER_NAME: deploys via EOA (skips if already deployed), then saves addresses.
///      PriceFeedLib must be deployed before NAVCalculator because NAVCalculator's bytecode references it
///      via DELEGATECALL. All three are included in the Safe batch so the batch is self-contained.
contract DeployImplementations is BaseDeployScript {
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    struct ImplPlan {
        address priceFeedLib;
        address navImpl;
        address bridgeImpl;
        bytes priceFeedLibBytecode;
        bytes navImplBytecode;
        bytes bridgeImplBytecode;
        bytes32 saltPriceFeedLib;
        bytes32 saltNavImpl;
        bytes32 saltBridgeImpl;
    }

    function run() public override {
        setUp();
        validateAddresses();

        ImplPlan memory plan = _computeImplPlan();

        SafeTxBuilder.Transaction[] memory txs = new SafeTxBuilder.Transaction[](3);
        txs[0] = SafeTxBuilder.call(
            CANONICAL_CREATE2_DEPLOYER, 0, abi.encodePacked(plan.saltPriceFeedLib, plan.priceFeedLibBytecode)
        );
        txs[1] =
            SafeTxBuilder.call(CANONICAL_CREATE2_DEPLOYER, 0, abi.encodePacked(plan.saltNavImpl, plan.navImplBytecode));
        txs[2] = SafeTxBuilder.call(
            CANONICAL_CREATE2_DEPLOYER, 0, abi.encodePacked(plan.saltBridgeImpl, plan.bridgeImplBytecode)
        );

        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-deploy-implementations.json"));
        writeSafeTx(
            filename,
            "Deploy PriceFeedLib + NAVCalculator + BridgeEscrow implementations (CREATE2)",
            "Deploy PriceFeedLib external library, NAVCalculator, and BridgeEscrow implementations via canonical CREATE2 deployer. Same addresses on all chains. Run once (e.g. on mainnet), then run 02 per chain for proxies + init.",
            txs
        );

        vm.startBroadcast();
        _deployIfNeeded(plan);
        vm.stopBroadcast();

        _saveAndLog(plan.priceFeedLib, plan.navImpl, plan.bridgeImpl, filename);
    }

    function _computeImplPlan() internal pure returns (ImplPlan memory plan) {
        plan.saltPriceFeedLib = generateSalt("PriceFeedLib", 1);
        plan.priceFeedLibBytecode = type(PriceFeedLib).creationCode;
        plan.priceFeedLib =
            computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, plan.saltPriceFeedLib, plan.priceFeedLibBytecode);

        plan.saltNavImpl = generateSalt("NAVCalculatorImplementation", 1);
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
    function _saveAndLog(address priceFeedLib, address navImpl, address bridgeImpl, string memory filename) internal {
        saveDeployedAddress("PriceFeedLib", priceFeedLib);
        saveDeployedAddress("NAVCalculatorImplementation", navImpl);
        saveDeployedAddress("BridgeEscrowImplementation", bridgeImpl);

        console2.log("\n=== Implementation Deployment ===");
        console2.log("Chain ID:", currentChainId);
        console2.log("Generated:", filename);
        console2.log("  PriceFeedLib:", priceFeedLib);
        console2.log("  NAV Implementation:", navImpl);
        console2.log("  Bridge Implementation:", bridgeImpl);
        console2.log("Addresses saved to config. Run 02_DeployProxies.s.sol per chain.");
    }
}
