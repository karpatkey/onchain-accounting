// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployNAVImplementation
/// @notice Deploys the NAVCalculator implementation only (no BridgeEscrow). Safe JSON and/or EOA broadcast.
/// @dev Uses canonical CREATE2 deployer (0x4e59...) with calldata = salt || init_code (Arachnid format).
///      Run without --broadcast: generates safe-transactions/{chainId}-deploy-nav-implementation.json.
///      Run with --broadcast --account $DEPLOYER_NAME: deploys via EOA (skips if already deployed), then saves address.
///      Same implementation address on all chains — run once, then run 02_2_DeployNAVProxy.s.sol per chain.
contract DeployNAVImplementation is BaseDeployScript {
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    struct ImplPlan {
        address navImpl;
        bytes navImplBytecode;
        bytes32 saltNavImpl;
    }

    function run() public override {
        setUp();
        validateAddresses();

        ImplPlan memory plan = _computeImplPlan();

        SafeTxBuilder.Transaction[] memory txs = new SafeTxBuilder.Transaction[](1);
        txs[0] =
            SafeTxBuilder.call(CANONICAL_CREATE2_DEPLOYER, 0, abi.encodePacked(plan.saltNavImpl, plan.navImplBytecode));

        string memory filename =
            string(abi.encodePacked(vm.toString(currentChainId), "-deploy-nav-implementation.json"));
        writeSafeTx(
            filename,
            "Deploy NAVCalculator implementation (CREATE2)",
            "Deploy NAVCalculator implementation via canonical CREATE2 deployer. Same address on all chains. Run once, then run 02_2_DeployNAVProxy.s.sol per chain.",
            txs
        );

        vm.startBroadcast();
        _deployIfNeeded(plan);
        vm.stopBroadcast();

        _saveAndLog(plan.navImpl, filename);
    }

    function _computeImplPlan() internal pure returns (ImplPlan memory plan) {
        plan.saltNavImpl = generateSalt("NAVCalculatorImplementation", 1);
        plan.navImplBytecode = type(NAVCalculator).creationCode;
        plan.navImpl = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, plan.saltNavImpl, plan.navImplBytecode);
    }

    function _deployIfNeeded(ImplPlan memory plan) internal {
        if (plan.navImpl.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(plan.saltNavImpl, plan.navImplBytecode));
            require(ok, "NAV impl deploy failed");
            console2.log("[OK] NAV implementation deployed at:", plan.navImpl);
        } else {
            console2.log("[SKIP] NAV implementation already at:", plan.navImpl);
        }
    }

    function _saveAndLog(address navImpl, string memory filename) internal {
        saveDeployedAddress("NAVCalculatorImplementation", navImpl);

        console2.log("\n=== NAV Implementation Deployment ===");
        console2.log("Chain ID:", currentChainId);
        console2.log("Generated:", filename);
        console2.log("  NAV Implementation:", navImpl);
        console2.log("Address saved to config. Run 02_2_DeployNAVProxy.s.sol per chain.");
    }
}
