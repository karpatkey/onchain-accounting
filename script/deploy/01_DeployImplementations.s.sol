// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployImplementations
/// @notice Deploys NAVCalculator and BridgeEscrow implementations (CREATE2). Safe JSON and/or EOA broadcast.
/// @dev Uses canonical CREATE2 deployer (0x4e59...) with calldata = salt || init_code (Arachnid format).
///      Run without --broadcast: generates safe-transactions/{chainId}-deploy-implementations.json and saves addresses.
///      Run with --broadcast --private-key: deploys via EOA (skips if already deployed), then saves addresses.
contract DeployImplementations is BaseDeployScript {
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    function run() public override {
        setUp();
        validateAddresses();

        bytes32 saltNavImpl = generateSalt("NAVCalculatorImplementation", 1);
        bytes memory navImplBytecode = type(NAVCalculator).creationCode;
        address navImpl = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltNavImpl, navImplBytecode);

        bytes32 saltBridgeImpl = generateSalt("BridgeEscrowImplementation", 1);
        bytes memory bridgeImplBytecode = type(BridgeEscrow).creationCode;
        address bridgeImpl = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltBridgeImpl, bridgeImplBytecode);

        // Safe TX: same calldata as EOA (salt || bytecode)
        SafeTxBuilder.Transaction[] memory transactions = new SafeTxBuilder.Transaction[](2);
        transactions[0] =
            SafeTxBuilder.call(CANONICAL_CREATE2_DEPLOYER, 0, abi.encodePacked(saltNavImpl, navImplBytecode));
        transactions[1] =
            SafeTxBuilder.call(CANONICAL_CREATE2_DEPLOYER, 0, abi.encodePacked(saltBridgeImpl, bridgeImplBytecode));

        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-deploy-implementations.json"));
        writeSafeTx(
            filename,
            "Deploy NAVCalculator and BridgeEscrow implementations (CREATE2)",
            "Deploy both implementations via canonical CREATE2 deployer. Same addresses on all chains. Run once (e.g. on mainnet), then run 02 per chain for proxies + init.",
            transactions
        );

        // EOA path: deploy when --broadcast is used
        vm.startBroadcast();
        if (navImpl.code.length == 0) {
            (bool navOk,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(saltNavImpl, navImplBytecode));
            require(navOk, "NAV impl deploy failed");
            console2.log("[OK] NAV implementation deployed at:", navImpl);
        } else {
            console2.log("[SKIP] NAV implementation already at:", navImpl);
        }
        if (bridgeImpl.code.length == 0) {
            (bool bridgeOk,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(saltBridgeImpl, bridgeImplBytecode));
            require(bridgeOk, "Bridge impl deploy failed");
            console2.log("[OK] Bridge implementation deployed at:", bridgeImpl);
        } else {
            console2.log("[SKIP] Bridge implementation already at:", bridgeImpl);
        }
        vm.stopBroadcast();

        saveDeployedAddress("NAVCalculatorImplementation", navImpl);
        saveDeployedAddress("BridgeEscrowImplementation", bridgeImpl);

        console2.log("\n=== Implementation Deployment ===");
        console2.log("Chain ID:", currentChainId);
        console2.log("Generated:", filename);
        console2.log("  NAV Implementation:", navImpl);
        console2.log("  Bridge Implementation:", bridgeImpl);
        console2.log("Addresses saved to config. Run 02a then 02b per chain.");
    }
}
