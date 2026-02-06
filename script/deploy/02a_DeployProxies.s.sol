// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {TransparentProxy} from "../../src/proxy/TransparentProxy.sol";
import {Empty} from "../../src/utils/Empty.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployProxies
/// @notice Deploys NAV + Bridge proxies via EOA using canonical CREATE2 deployer for deterministic addresses.
/// @dev
///   - Proxy bytecode uses a placeholder implementation (same CREATE2 address on all chains), so proxy addresses
///     are identical across chains regardless of where real NAV/Bridge implementations are deployed.
///   - 02a deploys placeholder (Empty) then both proxies; 02b upgrades each proxy to real impl and initializes.
///   - Uses canonical CREATE2 deployer (0x4e59...) with calldata = salt (32 bytes) || init_code (Arachnid ABI).
///   - See script/deploy/README.md for full docs and commands.
contract DeployProxies is BaseDeployScript {
    /// @notice Canonical CREATE2 deployer address (same on all chains)
    /// @dev 0x4e59b44847b379578588920cA78FbF26c0B4956C
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    function run() public override {
        setUp();
        validateAddresses();

        require(chainConfig.safeMultisig != address(0), "Safe multisig address not configured");

        // Placeholder impl: same address on all chains (CREATE2). Proxy bytecode uses this so it is chain-independent.
        bytes32 saltPlaceholder = generateSalt("ProxyPlaceholderImpl", 1);
        bytes memory placeholderBytecode = type(Empty).creationCode;
        address placeholder = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltPlaceholder, placeholderBytecode);

        // Proxy bytecode: (placeholder, safe, "") — identical on every chain; real impl is set in 02b via upgradeAndCall.
        bytes32 saltNavProxy = generateSalt("NAVCalculatorProxy", 1);
        bytes memory navProxyBytecode = abi.encodePacked(
            type(TransparentProxy).creationCode, abi.encode(placeholder, chainConfig.safeMultisig, "")
        );
        address navProxy = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltNavProxy, navProxyBytecode);

        bytes32 saltBridgeProxy = generateSalt("BridgeEscrowProxy", 1);
        bytes memory bridgeProxyBytecode = abi.encodePacked(
            type(TransparentProxy).creationCode, abi.encode(placeholder, chainConfig.safeMultisig, "")
        );
        address bridgeProxy = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltBridgeProxy, bridgeProxyBytecode);

        console2.log("\n=== Proxy Deployment (EOA) ===");
        console2.log("Placeholder impl (same on all chains):", placeholder);
        console2.log("  NAVCalculator proxy:", navProxy);
        console2.log("  BridgeEscrow proxy:", bridgeProxy);

        vm.startBroadcast();

        // 1. Deploy placeholder so proxy constructor sees implementation with code
        if (placeholder.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(saltPlaceholder, placeholderBytecode));
            require(ok, "Placeholder deploy failed");
        }

        // 2. Deploy NAV proxy
        (bool navOk,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(saltNavProxy, navProxyBytecode));
        require(navOk, "NAV proxy deploy call failed");
        console2.log("[OK] NAV proxy deployed at:", navProxy);

        // 3. Deploy Bridge proxy
        (bool bridgeOk,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(saltBridgeProxy, bridgeProxyBytecode));
        require(bridgeOk, "Bridge proxy deploy call failed");
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
