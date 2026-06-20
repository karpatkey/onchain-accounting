// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {AtomicProxyDeployer} from "./AtomicProxyDeployer.sol";
import {DeploySalts} from "./DeploySalts.sol";
import {UUPSProxy} from "../../src/proxy/UUPSProxy.sol";
import {UUPSPlaceholder} from "../../src/utils/UUPSPlaceholder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MANAGER} from "../../src/constants.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployProxies
/// @notice Deploys NAV + Bridge proxies via EOA using canonical CREATE2 deployer for deterministic addresses.
/// @dev
///   - Default: one tx via AtomicProxyDeployer (deploy placeholder + proxies + upgradeToAndCall) to avoid front-running.
///   - Set env USE_LEGACY_DEPLOY=1 to use the legacy multi-tx path instead.
///   - Proxy salts and placeholder use version 2. See script/deploy/README.md.
contract DeployProxies is BaseDeployScript {
    /// @notice Canonical CREATE2 deployer address (same on all chains)
    /// @dev 0x4e59b44847b379578588920cA78FbF26c0B4956C
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    function run() public override {
        setUp();
        validateAddresses();

        // Placeholder impl: same address on all chains (CREATE2). Proxy bytecode uses this so it is chain-independent.
        // Uses UUPSPlaceholder which is UUPS-compatible (has upgradeToAndCall function)
        bytes32 saltPlaceholder = generateSalt("ProxyPlaceholderImpl", DeploySalts.PLACEHOLDER_IMPL);
        bytes memory placeholderBytecode = type(UUPSPlaceholder).creationCode;
        address placeholder = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltPlaceholder, placeholderBytecode);

        // Proxy bytecode: (placeholder, "") — identical on every chain; real impl is set via upgradeToAndCall.
        // Salt versions are centralized in DeploySalts (shared with 02_2_DeployNAVProxy + both atomic deployers)
        // so the proxy address is identical across chains AND across both deploy paths. History: v1 addresses were
        // front-run (proxy at 0xA76A... initialized by attacker with impl 0x013a...); bump the version in
        // DeploySalts to derive fresh addresses. UUPS pattern: upgrades go directly through proxy to implementation.
        bytes32 saltNavProxy = generateSalt("NAVCalculatorProxy", DeploySalts.NAV_PROXY);
        bytes memory navProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));
        address navProxy = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltNavProxy, navProxyBytecode);

        bytes32 saltBridgeProxy = generateSalt("BridgeEscrowProxy", DeploySalts.BRIDGE_PROXY);
        bytes memory bridgeProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));
        address bridgeProxy = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltBridgeProxy, bridgeProxyBytecode);

        console2.log("\n=== Proxy Deployment (EOA) ===");
        console2.log("Placeholder impl (same on all chains):", placeholder);
        console2.log("  NAVCalculator proxy:", navProxy);
        console2.log("  BridgeEscrow proxy:", bridgeProxy);

        // Validate chain config deployed entries (if present) against computed CREATE2 addresses.
        // This helps catch stale or inconsistent config before we broadcast transactions.
        address cfgNavProxy = readDeployedAddress("NAVCalculatorProxy");
        if (cfgNavProxy != address(0) && cfgNavProxy != navProxy) {
            console2.log(
                "[WARN] NAVCalculatorProxy in chain config differs from computed CREATE2 address. Config:",
                cfgNavProxy,
                "Computed:",
                navProxy
            );
        }
        address cfgBridgeProxy = readDeployedAddress("BridgeEscrowProxy");
        if (cfgBridgeProxy != address(0) && cfgBridgeProxy != bridgeProxy) {
            console2.log(
                "[WARN] BridgeEscrowProxy in chain config differs from computed CREATE2 address. Config:",
                cfgBridgeProxy,
                "Computed:",
                bridgeProxy
            );
        }

        address navImpl = readDeployedAddress("NAVCalculatorImplementation");
        address bridgeImpl = readDeployedAddress("BridgeEscrowImplementation");
        require(
            navImpl != address(0),
            "NAVCalculator implementation address not configured. Run 01_DeployImplementations.s.sol first."
        );
        require(
            bridgeImpl != address(0),
            "BridgeEscrow implementation address not configured. Run 01_DeployImplementations.s.sol first."
        );

        bool useLegacy = bytes(vm.envOr("USE_LEGACY_DEPLOY", string(""))).length > 0;

        vm.startBroadcast();

        if (useLegacy) {
            // Legacy multi-tx path (each step can be front-run).
            if (placeholder.code.length == 0) {
                (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(saltPlaceholder, placeholderBytecode));
                require(ok, "Placeholder deploy failed");
            }
            if (navProxy.code.length == 0) {
                (bool navOk,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(saltNavProxy, navProxyBytecode));
                require(navOk, "NAV proxy deploy call failed");
                console2.log("[OK] NAV proxy deployed at:", navProxy);
            } else {
                console2.log("[SKIP] NAV proxy already deployed at:", navProxy);
            }
            if (bridgeProxy.code.length == 0) {
                (bool bridgeOk,) =
                    CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(saltBridgeProxy, bridgeProxyBytecode));
                require(bridgeOk, "Bridge proxy deploy call failed");
                console2.log("[OK] Bridge proxy deployed at:", bridgeProxy);
            } else {
                console2.log("[SKIP] Bridge proxy already deployed at:", bridgeProxy);
            }

            bytes memory navInitData = abi.encodeCall(
                NAVCalculator.initialize,
                (chainConfig.admin, chainConfig.chainlinkSequencerFeed, chainConfig.nativeTokenSymbol)
            );
            address[] memory initialAccounts = new address[](0);
            address[] memory initialAdapters = new address[](0);
            // chainId fits in uint64 for all EVM chains
            bytes memory bridgeInitData = abi.encodeCall(
                BridgeEscrow.initialize,
                // forge-lint: disable-next-line(unsafe-typecast)
                (chainConfig.admin, uint64(currentChainId), initialAccounts, initialAdapters)
            );
            bytes32 implementationSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

            address currentNavImpl = address(uint160(uint256(vm.load(navProxy, implementationSlot))));
            console2.log("NAV proxy current impl:", currentNavImpl);
            if (currentNavImpl == navImpl) {
                console2.log("[SKIP] NAV proxy already at target impl:", navImpl);
            } else if (currentNavImpl == placeholder) {
                UUPSUpgradeable(navProxy).upgradeToAndCall(navImpl, navInitData);
                console2.log("[OK] NAV proxy upgraded & initialized via EOA. Impl:", navImpl);
            } else {
                revert(
                    string(
                        abi.encodePacked(
                            "NAV proxy impl is ",
                            vm.toString(currentNavImpl),
                            "; upgrade to ",
                            vm.toString(navImpl),
                            " must be executed by the current admin."
                        )
                    )
                );
            }

            address currentBridgeImpl = address(uint160(uint256(vm.load(bridgeProxy, implementationSlot))));
            console2.log("Bridge proxy current impl:", currentBridgeImpl);
            if (currentBridgeImpl == bridgeImpl) {
                console2.log("[SKIP] Bridge proxy already at target impl:", bridgeImpl);
            } else if (currentBridgeImpl == placeholder) {
                UUPSUpgradeable(bridgeProxy).upgradeToAndCall(bridgeImpl, bridgeInitData);
                console2.log("[OK] Bridge proxy upgraded & initialized via EOA. Impl:", bridgeImpl);
            } else {
                revert(
                    string(
                        abi.encodePacked(
                            "Bridge proxy impl is ",
                            vm.toString(currentBridgeImpl),
                            "; upgrade to ",
                            vm.toString(bridgeImpl),
                            " must be executed by the current admin."
                        )
                    )
                );
            }
        } else {
            // Atomic path: one transaction (no front-run window).
            console2.log("[ATOMIC] Deploying placeholder + proxies + upgrade in a single transaction");
            new AtomicProxyDeployer(
                navImpl,
                bridgeImpl,
                chainConfig.chainlinkSequencerFeed,
                chainConfig.nativeTokenSymbol,
                chainConfig.admin,
                chainConfig.manager
            );
        }

        // MANAGER is granted inside AtomicProxyDeployer (atomic path) or must be granted separately (legacy path).
        if (useLegacy && chainConfig.manager != address(0)) {
            console2.log(
                "[WARN] Legacy path: MANAGER role NOT granted by this script.",
                "chainConfig.admin holds DEFAULT_ADMIN_ROLE; have the admin EOA call grantRole(MANAGER, manager) on both proxies."
            );
        }

        // Log actual role assignments (best-effort, never reverts).
        // DEFAULT_ADMIN_ROLE is always bytes32(0) for AccessControl.
        bytes32 adminRole = bytes32(0);

        // NAVCalculator roles
        {
            // Admin
            bytes memory payload = abi.encodeWithSignature("hasRole(bytes32,address)", adminRole, chainConfig.admin);
            (bool ok, bytes memory data) = navProxy.staticcall(payload);
            if (ok && data.length >= 32) {
                bool has = abi.decode(data, (bool));
                console2.log("NAVCalculator: admin has DEFAULT_ADMIN_ROLE:", has);
            } else {
                console2.log("NAVCalculator: admin role unknown (hasRole reverted)");
            }

            // Manager
            payload = abi.encodeWithSignature("hasRole(bytes32,address)", MANAGER, chainConfig.manager);
            (ok, data) = navProxy.staticcall(payload);
            if (ok && data.length >= 32) {
                bool has = abi.decode(data, (bool));
                console2.log("NAVCalculator: manager has MANAGER role:", has);
            } else {
                console2.log("NAVCalculator: manager role unknown (hasRole reverted)");
            }
        }

        // BridgeEscrow roles
        {
            // Admin
            bytes memory payload = abi.encodeWithSignature("hasRole(bytes32,address)", adminRole, chainConfig.admin);
            (bool ok, bytes memory data) = bridgeProxy.staticcall(payload);
            if (ok && data.length >= 32) {
                bool has = abi.decode(data, (bool));
                console2.log("BridgeEscrow: admin has DEFAULT_ADMIN_ROLE:", has);
            } else {
                console2.log("BridgeEscrow: admin role unknown (hasRole reverted)");
            }

            // Manager
            payload = abi.encodeWithSignature("hasRole(bytes32,address)", MANAGER, chainConfig.manager);
            (ok, data) = bridgeProxy.staticcall(payload);
            if (ok && data.length >= 32) {
                bool has = abi.decode(data, (bool));
                console2.log("BridgeEscrow: manager has MANAGER role:", has);
            } else {
                console2.log("BridgeEscrow: manager role unknown (hasRole reverted)");
            }
        }

        vm.stopBroadcast();

        // Verify deployments
        require(navProxy.code.length > 0, "NAV proxy deployment failed - no code at address");
        require(bridgeProxy.code.length > 0, "Bridge proxy deployment failed - no code at address");
        console2.log("[OK] Both proxies verified with code");

        // Index ERC20Default adapter (created in NAVCalculator.initialize()) and write to config
        address defaultAdapter = NAVCalculator(navProxy).erc20DefaultAdapter();
        console2.log("  ERC20Default adapter (from NAV init):", defaultAdapter);
        if (defaultAdapter != address(0)) {
            if (shouldBroadcast) {
                ConfigReader.writeAdapterAddress(vm, currentChainId, "balanceAdapters", "ERC20Default", defaultAdapter);
                console2.log("  balanceAdapters.ERC20Default.deployed written to config");
            } else {
                console2.log("  (Set PERSIST_DEPLOYMENTS=1 to write balanceAdapters.ERC20Default.deployed to config)");
            }
        }

        // Save deployed addresses
        saveDeployedAddress("NAVCalculatorProxy", navProxy);
        saveDeployedAddress("BridgeEscrowProxy", bridgeProxy);

        console2.log("\n=== Deployment Complete ===");
        console2.log("Proxy addresses saved to deployment config.");
        console2.log("NAV + Bridge proxies have been upgraded and initialized via EOA.");
        console2.log("\nProxy addresses (same on all chains, regardless of EOA):");
        console2.log("  NAVCalculator proxy:", navProxy);
        console2.log("    admin:", chainConfig.admin);
        console2.log("    manager:", chainConfig.manager);
        console2.log("  BridgeEscrow proxy:", bridgeProxy);
        console2.log("    admin:", chainConfig.admin);
        console2.log("    manager:", chainConfig.manager);
    }
}
