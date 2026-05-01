// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {console2} from "forge-std/console2.sol";

import {INAVCalculator} from "../../src/nav/INAVCalculator.sol";
import {BalanceAdapterRegistry} from "../../src/balances/factories/BalanceAdapterRegistry.sol";
import {AaveV3SafetyModuleAdapterFactory} from
    "../../src/balances/protocols/aave/AaveV3SafetyModuleAdapterFactory.sol";
import {AaveV3SafetyModuleBalanceOracle} from "../../src/balances/protocols/aave/AaveV3SafetyModule.sol";

/// @title MigrateSafetyModule
/// @notice One-time migration: swap the legacy single-token Aave V3 Safety Module adapter for the new
///         multi-token consolidated adapter (ADR 0002).
/// @dev Steps performed by this script (broadcast as the registry owner):
///       1. Predict and deploy the new multi-token adapter via the SM factory, seeded from chain config
///          (`balanceAdapters.AaveV3SafetyModule.constructor.{stakeTokenAddresses,stakeTokenDetails,admin,protocol}`).
///          The factory's `deploy(...)` ends with `BalanceAdapterRegistry.register(adapter)`, which calls
///          `NAVCalculator.addBalanceOracle` (registry holds MANAGER), so the new adapter becomes live in NAV.
///       2. Read the legacy adapter address from the chain config (`legacy_deployed`).
///       3. If the legacy adapter is not yet tracked by the central registry, call
///          `registry.registerExternal(K_AAVEV3_SM, legacy)` so the registry can manage it.
///       4. Call `registry.unregister(legacy)`. This removes the legacy adapter from NAV and notifies the
///          factory's `onAdapterUnregistered` hook (no-op for an external adapter not deployed by the factory,
///          but harmless because `registerExternal` set `isTracked=true`).
///       5. Sanity-check: NAV no longer reports the legacy adapter as registered; new adapter is registered.
///
///       Preconditions:
///         - `BalanceAdapterRegistry` exists and holds MANAGER on `NAVCalculator` (run after 05).
///         - `AaveV3SafetyModuleAdapterFactory` is wired to `keccak256("AaveV3SafetyModule")` in the registry.
///         - The chain config's `legacy_deployed` field carries the old single-token adapter address.
///         - Broadcaster is the registry owner (typically the OIV Safe).
///
///       Idempotency: the new adapter deployment is idempotent (CREATE2; same salt/initCode resolves to the
///       same address). Re-running this script after a partial run is safe but may revert on
///       `registry.unregister(legacy)` if it was already removed.
contract MigrateSafetyModule is BaseDeployScript {
    bytes32 internal constant FACTORY_VERSION_PROBE = bytes32(uint256(1));

    function run() public override {
        setUp();

        if (!ConfigReader.isAdapterEnabled(vm, currentChainId, "balanceAdapters", "AaveV3SafetyModule")) {
            console2.log("AaveV3SafetyModule not enabled on this chain -- nothing to migrate.");
            return;
        }

        // Resolve handles
        address registryAddr = readDeployedAddress("BalanceAdapterRegistry");
        require(registryAddr != address(0), "BalanceAdapterRegistry not deployed yet -- run 05_ first");
        BalanceAdapterRegistry registry = BalanceAdapterRegistry(registryAddr);

        bytes32 KEY_SM = keccak256("AaveV3SafetyModule");
        address factoryAddr = registry.factory(KEY_SM);
        require(factoryAddr != address(0), "AaveV3SafetyModuleAdapterFactory not registered with key");
        AaveV3SafetyModuleAdapterFactory factory = AaveV3SafetyModuleAdapterFactory(factoryAddr);

        address navAddr = readDeployedAddress("NAVCalculatorProxy");
        require(navAddr != address(0), "NAVCalculatorProxy address missing in chain config");
        INAVCalculator nav = INAVCalculator(navAddr);

        // Read constructor args from chain config
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "AaveV3SafetyModule", "protocol");
        address admin = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "AaveV3SafetyModule", "admin")
        );

        string memory root = vm.projectRoot();
        string memory path =
            string(abi.encodePacked(root, "/script/config/chains/", vm.toString(currentChainId), ".json"));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(path);
        address[] memory addrs = vm.parseJsonAddressArray(
            json, ".balanceAdapters.AaveV3SafetyModule.constructor.stakeTokenAddresses"
        );
        string[] memory details =
            vm.parseJsonStringArray(json, ".balanceAdapters.AaveV3SafetyModule.constructor.stakeTokenDetails");
        require(addrs.length == details.length, "stakeTokenAddresses/Details length mismatch");

        AaveV3SafetyModuleBalanceOracle.StakeTokenInit[] memory init =
            new AaveV3SafetyModuleBalanceOracle.StakeTokenInit[](addrs.length);
        for (uint256 i; i < addrs.length; ++i) {
            init[i] = AaveV3SafetyModuleBalanceOracle.StakeTokenInit({stakeToken: addrs[i], positionDetail: details[i]});
        }

        bytes32 salt = generateSalt("AaveV3SafetyModule", 1);

        address predicted = factory.predict(init, admin, protocol, salt);

        console2.log("\n=== Migrate Safety Module ===");
        console2.log("Factory:           ", factoryAddr);
        console2.log("Registry:          ", registryAddr);
        console2.log("New adapter (predicted):", predicted);
        console2.log("Admin (owner):     ", admin);
        console2.log("Stake tokens seeded:", addrs.length);

        // Resolve legacy address (only logged if present)
        address legacy = _readLegacyAddress();
        if (legacy != address(0)) {
            console2.log("Legacy adapter:    ", legacy);
            require(
                nav.isOracleRegistered(legacy),
                "legacy_deployed is set but NAV does not have it registered -- config drift?"
            );
        } else {
            console2.log("No legacy_deployed entry -- fresh deploy path.");
        }

        startBroadcast();

        // 1. Deploy (or reuse) the new adapter; auto-registers via factory + registry.
        address adapter;
        if (predicted.code.length == 0) {
            adapter = factory.deploy(init, admin, protocol, salt);
            console2.log("Deployed new adapter at:", adapter);
        } else {
            adapter = predicted;
            console2.log("New adapter already deployed at:", adapter);
            // The factory may not yet have it tracked; ensure the registry is aware.
            if (!registry.isAdapterRegistered(adapter)) {
                registry.registerExternal(KEY_SM, adapter);
                console2.log("Registered pre-existing adapter externally.");
            }
        }
        require(adapter == predicted, "address mismatch");

        // 2. Unregister legacy adapter (if any).
        if (legacy != address(0)) {
            if (!registry.isAdapterRegistered(legacy)) {
                registry.registerExternal(KEY_SM, legacy);
                console2.log("Registered legacy adapter externally so registry can manage it.");
            }
            registry.unregister(legacy);
            console2.log("Unregistered legacy adapter.");
        }

        stopBroadcast();

        // 3. Sanity checks
        require(nav.isOracleRegistered(adapter), "new adapter not registered in NAV");
        if (legacy != address(0)) {
            require(!nav.isOracleRegistered(legacy), "legacy adapter still registered in NAV");
        }

        // Persist new deployed address into chain config
        ConfigReader.writeAdapterAddress(vm, currentChainId, "balanceAdapters", "AaveV3SafetyModule", adapter);
        console2.log("Saved new adapter address to chain config.");
    }

    function _readLegacyAddress() internal view returns (address) {
        string memory raw = ConfigReader.readAdapterParam(
            vm, currentChainId, "balanceAdapters", "AaveV3SafetyModule", "legacy_deployed"
        );
        if (bytes(raw).length == 0) return address(0);
        return vm.parseAddress(raw);
    }
}
