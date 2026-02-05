// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {ICreate2Deployer} from "comet-contracts/Create2DeployerInterface.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployImplementations
/// @notice Generates one Safe multicall to deploy NAVCalculator and BridgeEscrow implementations only (CREATE2).
/// @dev Execute the generated JSON in Safe once; same impl addresses on all chains. Then run 02 per chain for proxies + init.
///      Uses canonical CREATE2 deployer (0x4e59b44847b379578588920cA78FbF26c0B4956C) via CALL.
contract DeployImplementations is BaseDeployScript {
    /// @notice Canonical CREATE2 deployer address (same on all chains)
    /// @dev 0x4e59b44847b379578588920cA78FbF26c0B4956C
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    function run() public override {
        setUp();
        validateAddresses();

        bytes32 saltNavImpl = generateSalt("NAVCalculatorImplementation", 1);
        bytes memory navImplBytecode = type(NAVCalculator).creationCode;
        // Compute address using canonical CREATE2 deployer (not Safe)
        address navImpl = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltNavImpl, navImplBytecode);

        bytes32 saltBridgeImpl = generateSalt("BridgeEscrowImplementation", 1);
        bytes memory bridgeImplBytecode = type(BridgeEscrow).creationCode;
        // Compute address using canonical CREATE2 deployer (not Safe)
        address bridgeImpl = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltBridgeImpl, bridgeImplBytecode);

        SafeTxBuilder.Transaction[] memory transactions = new SafeTxBuilder.Transaction[](2);
        // Use CALL (not DELEGATECALL) to canonical CREATE2 deployer
        transactions[0] = SafeTxBuilder.call(
            CANONICAL_CREATE2_DEPLOYER,
            0,
            abi.encodeWithSelector(ICreate2Deployer.deploy.selector, 0, saltNavImpl, navImplBytecode)
        );
        transactions[1] = SafeTxBuilder.call(
            CANONICAL_CREATE2_DEPLOYER,
            0,
            abi.encodeWithSelector(ICreate2Deployer.deploy.selector, 0, saltBridgeImpl, bridgeImplBytecode)
        );

        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-deploy-implementations.json"));
        writeSafeTx(
            filename,
            "Deploy NAVCalculator and BridgeEscrow implementations (CREATE2)",
            "Deploy both implementations via canonical CREATE2 deployer. Same addresses on all chains. Run once (e.g. on mainnet), then run 02 per chain for proxies + init.",
            transactions
        );

        saveDeployedAddress("NAVCalculatorImplementation", navImpl);
        saveDeployedAddress("BridgeEscrowImplementation", bridgeImpl);

        console2.log("\n=== Implementation Deployment (Safe) ===");
        console2.log("Canonical CREATE2 Deployer:", CANONICAL_CREATE2_DEPLOYER);
        console2.log("\nGenerated:", filename);
        console2.log("  Tx 1: Deploy NAVCalculator implementation");
        console2.log("  Tx 2: Deploy BridgeEscrow implementation");
        console2.log("\nComputed implementation addresses (same on all chains):");
        console2.log("  NAV Implementation:", navImpl);
        console2.log("  Bridge Implementation:", bridgeImpl);
        console2.log(
            "\nExecute this Safe batch once, then run 02a_DeployProxies.s.sol (EOA) and 02b_InitializeProxies.s.sol (Safe) per chain."
        );
    }
}
