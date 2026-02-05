// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployImplementations
/// @notice Generates one Safe multicall to deploy NAVCalculator and BridgeEscrow implementations only (CREATE2).
/// @dev Execute the generated JSON in Safe once; same impl addresses on all chains. Then run 02 per chain for proxies + init.
contract DeployImplementations is BaseDeployScript {
    function run() public override {
        setUp();
        validateAddresses();

        address create2Deployer = readDeployedAddress("Create2Deployer");
        if (create2Deployer == address(0)) {
            console2.log("ERROR: Create2Deployer not deployed. Run 00_DeployCreate2Deployer first.");
            revert("Create2Deployer not deployed");
        }

        bytes32 saltNavImpl = generateSalt("NAVCalculatorImplementation", 1);
        bytes memory navImplBytecode = type(NAVCalculator).creationCode;
        address navImpl = computeCreate2Address(chainConfig.safeMultisig, saltNavImpl, navImplBytecode);

        bytes32 saltBridgeImpl = generateSalt("BridgeEscrowImplementation", 1);
        bytes memory bridgeImplBytecode = type(BridgeEscrow).creationCode;
        address bridgeImpl = computeCreate2Address(chainConfig.safeMultisig, saltBridgeImpl, bridgeImplBytecode);

        SafeTxBuilder.Transaction[] memory transactions = new SafeTxBuilder.Transaction[](2);
        transactions[0] = SafeTxBuilder.delegateCall(
            create2Deployer, abi.encodeWithSignature("deploy(bytes32,bytes)", saltNavImpl, navImplBytecode)
        );
        transactions[1] = SafeTxBuilder.delegateCall(
            create2Deployer, abi.encodeWithSignature("deploy(bytes32,bytes)", saltBridgeImpl, bridgeImplBytecode)
        );

        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-deploy-implementations.json"));
        writeSafeTx(
            filename,
            "Deploy NAVCalculator and BridgeEscrow implementations (CREATE2)",
            "Deploy both implementations via CREATE2. Same addresses on all chains. Run once (e.g. on mainnet), then run 02 per chain for proxies + init.",
            transactions
        );

        saveDeployedAddress("NAVCalculatorImplementation", navImpl);
        saveDeployedAddress("BridgeEscrowImplementation", bridgeImpl);

        console2.log("\nGenerated:", filename);
        console2.log("  Tx 1: Deploy NAVCalculator implementation");
        console2.log("  Tx 2: Deploy BridgeEscrow implementation");
        console2.log("NAV impl (same on all chains):", navImpl);
        console2.log("Bridge impl (same on all chains):", bridgeImpl);
        console2.log("Execute this Safe batch once, then run 02_DeployProxiesAndInitialize per chain.");
    }
}
