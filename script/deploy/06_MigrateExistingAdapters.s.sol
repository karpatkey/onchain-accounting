// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {console2} from "forge-std/console2.sol";

import {BalanceAdapterRegistry} from "../../src/balances/factories/BalanceAdapterRegistry.sol";

/// @title MigrateExistingAdapters
/// @notice Absorbs the ~30 already-deployed balance adapters across the 5 chains into the new
///         `BalanceAdapterRegistry`, without redeploying any of them.
/// @dev
///   - For each adapter listed below, reads the per-chain config to find its already-deployed
///     address, then calls `Registry.registerExternal(protocolKey, deployedAddr)`.
///   - The registry detects `NAV.isOracleRegistered(addr) == true` and skips the redundant
///     `addBalanceOracle` call, so this script is a pure registry-side bookkeeping pass.
///   - Idempotent: re-running on a chain whose adapters are already registered is a no-op.
///   - Run after `05_DeployAdapterFactories.s.sol` and after the OIV Safe has granted
///     MANAGER on NAVCalculator to the registry. (Even though `addBalanceOracle` is skipped,
///     the registry's `_register` checks `NAV.isOracleRegistered` first — without MANAGER the
///     skip path is fine, but if any adapter happens to *not* be registered yet, the call
///     would revert. Granting MANAGER is the safe default.)
///   - Requires the registry owner to broadcast (since `registerExternal` is `onlyOwner`).
contract MigrateExistingAdapters is BaseDeployScript {
    /// @notice One adapter to migrate.
    /// @param configName The key under `balanceAdapters` in the per-chain JSON (e.g. "AaveV3_Core").
    /// @param protocolKey The protocol key the central registry should record.
    struct Migration {
        string configName;
        bytes32 protocolKey;
    }

    function run() public override {
        setUp();

        address registryAddr = readDeployedAddress("BalanceAdapterRegistry");
        require(registryAddr != address(0), "BalanceAdapterRegistry not deployed yet - run 05_ first");

        BalanceAdapterRegistry registry = BalanceAdapterRegistry(registryAddr);
        Migration[] memory migrations = _allMigrations();

        console2.log("\n=== Migrate Existing Adapters -> Registry ===");
        console2.log("Registry:", registryAddr);
        console2.log("Migrations to attempt:", migrations.length);

        startBroadcast();

        uint256 registered;
        uint256 skipped;
        for (uint256 i; i < migrations.length; ++i) {
            Migration memory m = migrations[i];
            address adapter = _readAdapterDeployedAddress(m.configName);
            if (adapter == address(0)) {
                // Not enabled on this chain — silently skip.
                continue;
            }
            if (registry.isAdapterRegistered(adapter)) {
                console2.log("  [skip] already registered:", m.configName, adapter);
                skipped++;
                continue;
            }
            registry.registerExternal(m.protocolKey, adapter);
            console2.log("  [add ]", m.configName, adapter);
            registered++;
        }

        stopBroadcast();

        console2.log("\nRegistered:", registered, "  Skipped:", skipped);
    }

    function _readAdapterDeployedAddress(string memory configName) internal view returns (address) {
        // Adapters use a "deployed" leaf inside `balanceAdapters.<name>`. The existing config
        // schema reads `balanceAdapters.<name>.deployed`. Re-use the same path.
        string memory raw = ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", configName, "deployed");
        if (bytes(raw).length == 0) return address(0);
        return vm.parseAddress(raw);
    }

    function _allMigrations() internal pure returns (Migration[] memory m) {
        // Mirror the order of `04_DeployBalanceAdapters.s.sol`. Adapter names that are not enabled
        // on a given chain just resolve to address(0) and are silently skipped.
        m = new Migration[](47);

        bytes32 K_AAVEV3 = keccak256("AaveV3Instance");
        // AaveV3SafetyModule is migrated by 07_MigrateSafetyModule.s.sol (multi-token consolidation).
        bytes32 K_AURA = keccak256("Aura");
        bytes32 K_BAL = keccak256("BalancerV3");
        bytes32 K_CAP = keccak256("Cap");
        bytes32 K_COMPV3 = keccak256("CompoundV3Comet");
        bytes32 K_CONVEX = keccak256("Convex");
        bytes32 K_CURVE = keccak256("Curve");
        bytes32 K_DSR = keccak256("DaiDsr");
        bytes32 K_GEARBOX = keccak256("GearboxMarket");
        bytes32 K_MORPHO_M = keccak256("MorphoMarket");
        bytes32 K_MORPHO_V = keccak256("MorphoVault");
        bytes32 K_SKY = keccak256("SkySavingsUsds");
        bytes32 K_SPARK = keccak256("SparkLend");
        bytes32 K_SW_VAULT = keccak256("StakeWiseV3Vault");
        bytes32 K_SW_OST = keccak256("StakeWiseV3OsToken");

        uint256 i;

        m[i++] = Migration("AaveV3_Core", K_AAVEV3);
        m[i++] = Migration("AaveV3_Prime", K_AAVEV3);
        m[i++] = Migration("AaveV3_Arbitrum", K_AAVEV3);
        m[i++] = Migration("AaveV3_Base", K_AAVEV3);
        m[i++] = Migration("AaveV3_Optimism", K_AAVEV3);
        m[i++] = Migration("AaveV3_Gnosis", K_AAVEV3);
        m[i++] = Migration("SparkLend", K_SPARK);
        // AaveV3 Safety Module is migrated separately via 07_MigrateSafetyModule.s.sol
        // (the legacy single-token stkGHO adapter at 0x191d… is being replaced by a single
        // multi-token adapter; see docs/decisions/0002-aave-safety-module-multi-token.md).
        m[i++] = Migration("Cap", K_CAP);
        m[i++] = Migration("DaiDsr", K_DSR);
        m[i++] = Migration("SkySavingsUsds", K_SKY);

        m[i++] = Migration("MorphoVault_kpkETHPrime_V1", K_MORPHO_V);
        m[i++] = Migration("MorphoVault_kpkETHPrime_V2", K_MORPHO_V);
        m[i++] = Migration("MorphoVault_kpkUSDCPrime_V1", K_MORPHO_V);
        m[i++] = Migration("MorphoVault_kpkUSDCPrime_V2", K_MORPHO_V);
        m[i++] = Migration("MorphoVault_kpkUSDCYieldV1", K_MORPHO_V);

        m[i++] = Migration("MorphoMarket_wstETH_USDC", K_MORPHO_M);
        m[i++] = Migration("MorphoMarket_cbBTC_USDC", K_MORPHO_M);
        m[i++] = Migration("MorphoMarket_wstUSR_USDC", K_MORPHO_M);
        m[i++] = Migration("MorphoMarket_ETHPlus_USDC", K_MORPHO_M);
        m[i++] = Migration("MorphoMarket_WBTC_USDC", K_MORPHO_M);
        m[i++] = Migration("MorphoMarket_RLP_USDC", K_MORPHO_M);
        m[i++] = Migration("MorphoMarket_syrupUSDC_USDC", K_MORPHO_M);
        m[i++] = Migration("MorphoMarket_sUSDS_USDT", K_MORPHO_M);
        m[i++] = Migration("MorphoMarket_sUSDS_USDC", K_MORPHO_M);
        m[i++] = Migration("MorphoMarket_ETHPlus_WETH", K_MORPHO_M);
        m[i++] = Migration("MorphoMarket_wstETH_WETH", K_MORPHO_M);
        m[i++] = Migration("MorphoMarket_weETH_WETH", K_MORPHO_M);
        m[i++] = Migration("MorphoMarket_rsETH_WETH", K_MORPHO_M);
        m[i++] = Migration("MorphoMarket_cbETH_USDC", K_MORPHO_M);

        m[i++] = Migration("GearboxMarket_kpkWETH", K_GEARBOX);
        m[i++] = Migration("GearboxMarket_kpkwstETH", K_GEARBOX);

        m[i++] = Migration("BalancerV3_rETH_WETH", K_BAL);
        m[i++] = Migration("BalancerV3_GHO_USDT_USDC", K_BAL);
        m[i++] = Migration("BalancerV3_GHO_USDC_USDT", K_BAL);
        m[i++] = Migration("BalancerV3_GHO_USDC", K_BAL);

        m[i++] = Migration("Aura_rETH_WETH", K_AURA);
        m[i++] = Migration("Aura_GHO_USDT_USDC", K_AURA);
        m[i++] = Migration("Aura_GHO_USDC_USDT", K_AURA);
        m[i++] = Migration("Aura_GHO_USDC", K_AURA);

        m[i++] = Migration("Curve_weETH_WETH", K_CURVE);
        m[i++] = Migration("Curve_crvUSD_USDC", K_CURVE);
        m[i++] = Migration("Curve_crvUSD_USDT", K_CURVE);
        m[i++] = Migration("Curve_RLUSD_USDC", K_CURVE);

        m[i++] = Migration("Convex_weETH_WETH", K_CONVEX);
        m[i++] = Migration("Convex_crvUSD_USDC", K_CONVEX);
        m[i++] = Migration("Convex_crvUSD_USDT", K_CONVEX);
        m[i++] = Migration("Convex_RLUSD_USDC", K_CONVEX);

        // CompoundV3 + StakeWise placeholders are supported by their factories but are not in any
        // chain config today. Re-running this script after registering them in the config will pick them up.
        require(i == m.length, "migration list length mismatch");
    }
}
