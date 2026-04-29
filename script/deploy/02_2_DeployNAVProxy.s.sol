// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {AtomicNAVProxyDeployer} from "./AtomicNAVProxyDeployer.sol";
import {UUPSProxy} from "../../src/proxy/UUPSProxy.sol";
import {UUPSPlaceholder} from "../../src/utils/UUPSPlaceholder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MANAGER} from "../../src/constants.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployNAVProxy
/// @notice Deploys the NAVCalculator proxy only (no BridgeEscrow) via EOA using canonical CREATE2 for deterministic addresses.
/// @dev
///   - Default: one tx via AtomicNAVProxyDeployer (deploy placeholder + proxy + upgradeToAndCall) to avoid front-running.
///     Roles are granted and the deployer's admin role is renounced atomically — safe with a Safe as chainConfig.admin.
///   - Set env USE_LEGACY_DEPLOY=1 to use the legacy multi-tx path instead.
///     NOTE: legacy path does NOT grant MANAGER — have the admin Safe call grantRole(MANAGER, manager) afterwards.
///   - Proxy salts use version 2 (same as full 02_DeployProxies.s.sol — identical proxy address on all chains).
///   - Prerequisite: run 01_2_DeployNAVImplementation.s.sol first to populate NAVCalculatorImplementation in config.
contract DeployNAVProxy is BaseDeployScript {
    /// @notice Canonical CREATE2 deployer address (same on all chains)
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    function run() public override {
        setUp();
        validateAddresses();

        // Placeholder impl: same address on all chains (CREATE2).
        bytes32 saltPlaceholder = generateSalt("ProxyPlaceholderImpl", 2);
        bytes memory placeholderBytecode = type(UUPSPlaceholder).creationCode;
        address placeholder = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltPlaceholder, placeholderBytecode);

        // NAV proxy bytecode: (placeholder, "") — identical on every chain.
        bytes32 saltNavProxy = generateSalt("NAVCalculatorProxy", 2);
        bytes memory navProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(placeholder, ""));
        address navProxy = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltNavProxy, navProxyBytecode);

        console2.log("\n=== NAV Proxy Deployment (EOA) ===");
        console2.log("Placeholder impl (same on all chains):", placeholder);
        console2.log("  NAVCalculator proxy:", navProxy);

        // Warn if config has a stale NAVCalculatorProxy entry.
        address cfgNavProxy = readDeployedAddress("NAVCalculatorProxy");
        if (cfgNavProxy != address(0) && cfgNavProxy != navProxy) {
            console2.log(
                "[WARN] NAVCalculatorProxy in chain config differs from computed CREATE2 address. Config:",
                cfgNavProxy,
                "Computed:",
                navProxy
            );
        }

        address navImpl = readDeployedAddress("NAVCalculatorImplementation");
        require(
            navImpl != address(0),
            "NAVCalculator implementation address not configured. Run 01_2_DeployNAVImplementation.s.sol first."
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

            bytes memory navInitData = abi.encodeCall(
                NAVCalculator.initialize,
                (chainConfig.admin, chainConfig.chainlinkSequencerFeed, chainConfig.nativeTokenSymbol)
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
                            " must be executed by current admin (e.g. via Safe)."
                        )
                    )
                );
            }
        } else {
            // Atomic path: one transaction (no front-run window).
            // AtomicNAVProxyDeployer grants DEFAULT_ADMIN_ROLE to chainConfig.admin, grants MANAGER to
            // chainConfig.manager, then renounces its own DEFAULT_ADMIN_ROLE — safe when admin is a Safe.
            console2.log("[ATOMIC] Deploying placeholder + NAV proxy + upgrade in a single transaction");
            new AtomicNAVProxyDeployer(
                navImpl,
                chainConfig.chainlinkSequencerFeed,
                chainConfig.nativeTokenSymbol,
                chainConfig.admin,
                chainConfig.manager
            );
        }

        // MANAGER is granted inside AtomicNAVProxyDeployer (atomic path).
        // Legacy path: chainConfig.admin holds DEFAULT_ADMIN_ROLE; have the admin Safe call
        // grantRole(MANAGER, manager) on the NAV proxy after this script completes.
        if (useLegacy && chainConfig.manager != address(0)) {
            console2.log(
                "[WARN] Legacy path: MANAGER role NOT granted by this script.",
                "Have the admin Safe call grantRole(MANAGER, manager) on the NAV proxy."
            );
        }

        // Log actual role assignments (best-effort, never reverts).
        bytes32 adminRole = bytes32(0);
        {
            bytes memory payload = abi.encodeWithSignature("hasRole(bytes32,address)", adminRole, chainConfig.admin);
            (bool ok, bytes memory data) = navProxy.staticcall(payload);
            if (ok && data.length >= 32) {
                console2.log("NAVCalculator: admin has DEFAULT_ADMIN_ROLE:", abi.decode(data, (bool)));
            } else {
                console2.log("NAVCalculator: admin role unknown (hasRole reverted)");
            }

            payload = abi.encodeWithSignature("hasRole(bytes32,address)", MANAGER, chainConfig.manager);
            (ok, data) = navProxy.staticcall(payload);
            if (ok && data.length >= 32) {
                console2.log("NAVCalculator: manager has MANAGER role:", abi.decode(data, (bool)));
            } else {
                console2.log("NAVCalculator: manager role unknown (hasRole reverted)");
            }
        }

        vm.stopBroadcast();

        require(navProxy.code.length > 0, "NAV proxy deployment failed - no code at address");
        console2.log("[OK] NAV proxy verified with code");

        // Index ERC20Default oracle (created in NAVCalculator.initialize()) and write to config.
        address defaultOracle = NAVCalculator(navProxy).erc20DefaultOracle();
        console2.log("  ERC20Default oracle (from NAV init):", defaultOracle);
        if (defaultOracle != address(0)) {
            if (shouldBroadcast) {
                ConfigReader.writeAdapterAddress(vm, currentChainId, "balanceAdapters", "ERC20Default", defaultOracle);
                console2.log("  balanceAdapters.ERC20Default.deployed written to config");
            } else {
                console2.log("  (Set PERSIST_DEPLOYMENTS=1 to write balanceAdapters.ERC20Default.deployed to config)");
            }
        }

        saveDeployedAddress("NAVCalculatorProxy", navProxy);

        console2.log("\n=== NAV Deployment Complete ===");
        console2.log("Proxy address saved to deployment config.");
        console2.log("NAVCalculator proxy has been upgraded and initialized via EOA.");
        console2.log("\nProxy address (same on all chains, regardless of EOA):");
        console2.log("  NAVCalculator proxy:", navProxy);
        console2.log("    admin:", chainConfig.admin);
        console2.log("    manager:", chainConfig.manager);
    }
}
