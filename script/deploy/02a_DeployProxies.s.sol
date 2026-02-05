// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {TransparentProxy} from "../../src/proxy/TransparentProxy.sol";
import {ICreate2Deployer} from "comet-contracts/Create2DeployerInterface.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployProxies
/// @notice Deploys NAV + Bridge proxies via EOA using canonical CREATE2 deployer for deterministic addresses.
/// @dev Run after 01_DeployImplementations has been executed. Can be run by any EOA - addresses are deterministic.
///      Uses canonical CREATE2 deployer (0x4e59b44847b379578588920cA78FbF26c0B4956C) via CALL.
///      Proxies are deployed with real implementation and Safe as admin.
///      Same proxy addresses on all chains regardless of which EOA deploys them.
contract DeployProxies is BaseDeployScript {
    /// @notice Canonical CREATE2 deployer address (same on all chains)
    /// @dev 0x4e59b44847b379578588920cA78FbF26c0B4956C
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    function run() public override {
        setUp();
        validateAddresses();

        // Read implementation addresses from config (deployed by EOA, not via Safe CREATE2)
        address navImpl = readDeployedAddress("NAVCalculatorImplementation");
        address bridgeImpl = readDeployedAddress("BridgeEscrowImplementation");

        // Verify implementation addresses are configured
        require(navImpl != address(0), "NAVCalculator implementation address not configured in chain config");
        require(bridgeImpl != address(0), "BridgeEscrow implementation address not configured in chain config");

        // Compute proxy addresses using canonical CREATE2 deployer
        // Proxies are deployed directly with the real implementation and Safe as admin
        // This ensures deterministic addresses regardless of which EOA deploys them
        bytes32 saltNavProxy = generateSalt("NAVCalculatorProxy", 1);
        bytes memory navProxyBytecode =
            abi.encodePacked(type(TransparentProxy).creationCode, abi.encode(navImpl, chainConfig.safeMultisig, ""));
        bytes32 navProxyBytecodeHash = keccak256(navProxyBytecode);
        address navProxy = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltNavProxy, navProxyBytecode);

        bytes32 saltBridgeProxy = generateSalt("BridgeEscrowProxy", 1);
        bytes memory bridgeProxyBytecode =
            abi.encodePacked(type(TransparentProxy).creationCode, abi.encode(bridgeImpl, chainConfig.safeMultisig, ""));
        bytes32 bridgeProxyBytecodeHash = keccak256(bridgeProxyBytecode);
        address bridgeProxy = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltBridgeProxy, bridgeProxyBytecode);

        console2.log("\n=== Proxy Deployment (EOA) ===");
        console2.log("Deployer (EOA):", msg.sender);
        console2.log("Canonical CREATE2 Deployer:", CANONICAL_CREATE2_DEPLOYER);
        console2.log("\nComputed proxy addresses (deterministic, same regardless of EOA):");
        console2.log("  NAVCalculator proxy:", navProxy);
        console2.log("  BridgeEscrow proxy:", bridgeProxy);

        // Verify address computation using deployer's computeAddress function (if on-chain)
        try ICreate2Deployer(CANONICAL_CREATE2_DEPLOYER).computeAddress(saltNavProxy, navProxyBytecodeHash) returns (
            address computedAddress
        ) {
            require(computedAddress == navProxy, "NAV proxy address mismatch: computed != deployer.computeAddress");
            console2.log("[OK] Verified NAV proxy address matches deployer computation");
        } catch {
            console2.log("[WARN] Could not verify NAV proxy address with deployer (offline mode or deployer not found)");
        }

        try ICreate2Deployer(CANONICAL_CREATE2_DEPLOYER)
            .computeAddress(saltBridgeProxy, bridgeProxyBytecodeHash) returns (
            address computedAddress
        ) {
            require(
                computedAddress == bridgeProxy, "Bridge proxy address mismatch: computed != deployer.computeAddress"
            );
            console2.log("[OK] Verified Bridge proxy address matches deployer computation");
        } catch {
            console2.log(
                "[WARN] Could not verify Bridge proxy address with deployer (offline mode or deployer not found)"
            );
        }

        // Deploy proxies via EOA using canonical CREATE2 deployer
        // Start broadcast to enable transaction generation
        vm.startBroadcast();

        console2.log("\n=== Deploying Proxies ===");

        // Deploy NAV proxy
        ICreate2Deployer(CANONICAL_CREATE2_DEPLOYER).deploy(0, saltNavProxy, navProxyBytecode);
        console2.log("[OK] NAV proxy deployed at:", navProxy);

        // Deploy Bridge proxy
        ICreate2Deployer(CANONICAL_CREATE2_DEPLOYER).deploy(0, saltBridgeProxy, bridgeProxyBytecode);
        console2.log("[OK] Bridge proxy deployed at:", bridgeProxy);

        vm.stopBroadcast();

        // Verify deployments
        require(navProxy.code.length > 0, "NAV proxy deployment failed - no code at address");
        require(bridgeProxy.code.length > 0, "Bridge proxy deployment failed - no code at address");
        console2.log("[OK] Both proxies verified with code");

        // Save deployed addresses
        saveDeployedAddress("NAVCalculatorProxy", navProxy);
        saveDeployedAddress("BridgeEscrowProxy", bridgeProxy);

        console2.log("\n=== Deployment Complete ===");
        console2.log("Proxy addresses saved to deployment config.");
        console2.log("Next step: Run 02b_InitializeProxies.s.sol to generate Safe transactions for initialization.");
        console2.log("\nProxy addresses (same on all chains, regardless of EOA):");
        console2.log("  NAVCalculator proxy:", navProxy);
        console2.log("  BridgeEscrow proxy:", bridgeProxy);
    }
}
