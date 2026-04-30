// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";

import {BalanceAdapterRegistry} from "src/balances/factories/BalanceAdapterRegistry.sol";
import {AaveV3InstanceAdapterFactory} from "src/balances/protocols/aave/AaveV3InstanceAdapterFactory.sol";
import {MorphoVaultAdapterFactory} from "src/balances/protocols/morpho/MorphoVaultAdapterFactory.sol";
import {AaveV3InstanceBalanceOracle} from "src/balances/protocols/aave/AaveV3Instance.sol";
import {MorphoVaultBalanceOracle} from "src/balances/protocols/morpho/MorphoVault.sol";

/// @title AdapterFactoryFlow.fork
/// @notice End-to-end fork test for the new adapter factory + registry pipeline against the live
///         Mainnet NAVCalculator deployment. Exercises both write paths into the registry:
///         (1) factory.deploy(...) for a brand-new adapter, and
///         (2) registry.registerExternal(...) for an already-deployed adapter.
contract AdapterFactoryFlowForkTest is Test {
    /// @notice Live Mainnet NAVCalculator proxy from the NAV v2 deploy.
    address internal constant NAV = 0x07938ddDfACa63679c4d3F1d80BBe6aB1a6aEB19;

    /// @notice Live OIV Safe — current MANAGER on NAVCalculator.
    address internal constant OIV_SAFE = 0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537;

    /// @notice Aave V3 Core PoolDataProvider on Mainnet (used by the Aave Core adapter).
    address internal constant AAVE_V3_CORE_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;

    /// @notice Existing AaveV3_Core adapter on Mainnet (from script/config/chains/1.json).
    address internal constant EXISTING_AAVEV3_CORE = 0x1aee401c41bAE2a02aE39d9c969De44dbD8ca449;

    /// @notice Existing MorphoVault_kpkUSDCPrime_V2 adapter on Mainnet (from script/config/chains/1.json).
    address internal constant EXISTING_MORPHO_VAULT = 0xBF19e8568cbA837d3922a987f9E001787385575f;

    bytes32 internal constant K_AAVEV3 = keccak256("AaveV3Instance");
    bytes32 internal constant K_MORPHO_V = keccak256("MorphoVault");

    BalanceAdapterRegistry internal registry;
    AaveV3InstanceAdapterFactory internal aaveFactory;
    MorphoVaultAdapterFactory internal morphoFactory;

    address internal owner = address(0xC0DE);

    function setUp() public {
        string memory rpc = vm.rpcUrl("mainnet");
        vm.createSelectFork(rpc);

        // Deploy registry + factories from the test EOA so it's the initial owner.
        registry = new BalanceAdapterRegistry(NAV, owner);
        aaveFactory = new AaveV3InstanceAdapterFactory(address(registry), NAV, owner);
        morphoFactory = new MorphoVaultAdapterFactory(address(registry), NAV, owner);

        vm.startPrank(owner);
        registry.setFactory(K_AAVEV3, address(aaveFactory));
        registry.setFactory(K_MORPHO_V, address(morphoFactory));
        vm.stopPrank();

        // Grant MANAGER on NAV to the registry (the OIV Safe currently holds it).
        bytes32 MANAGER = keccak256("MANAGER");
        vm.prank(OIV_SAFE);
        NAVCalculator(NAV).grantRole(MANAGER, address(registry));
    }

    function test_deploy_newAaveAdapter_roundtrips_through_NAV() public {
        bytes32 salt = keccak256("aave-core-test");

        address predicted = aaveFactory.predict(AAVE_V3_CORE_DATA_PROVIDER, "Aave V3 Core", salt);

        vm.prank(owner);
        address adapter = aaveFactory.deploy(AAVE_V3_CORE_DATA_PROVIDER, "Aave V3 Core", salt);

        assertEq(adapter, predicted, "predict != actual deploy");
        assertGt(adapter.code.length, 0, "no code at deployed adapter");

        // Registry tracks under the right key.
        assertTrue(registry.isAdapterRegistered(adapter), "registry missing adapter");
        assertEq(registry.adapterProtocol(adapter), K_AAVEV3, "wrong protocol key");

        // NAVCalculator now has the oracle.
        assertTrue(INAVCalculator(NAV).isOracleRegistered(adapter), "NAV missing oracle");

        // The adapter knows about the right data provider.
        assertEq(
            address(AaveV3InstanceBalanceOracle(adapter).DATA_PROVIDER()), AAVE_V3_CORE_DATA_PROVIDER, "PDP mismatch"
        );
    }

    function test_registerExternal_existingAdapter_idempotentNAV() public {
        // Pre-condition: NAV already has the existing adapter registered.
        assertTrue(
            INAVCalculator(NAV).isOracleRegistered(EXISTING_AAVEV3_CORE), "test fixture: existing adapter not in NAV"
        );

        vm.prank(owner);
        registry.registerExternal(K_AAVEV3, EXISTING_AAVEV3_CORE);

        assertTrue(registry.isAdapterRegistered(EXISTING_AAVEV3_CORE));
        assertEq(registry.adapterProtocol(EXISTING_AAVEV3_CORE), K_AAVEV3);

        // NAV still has it (no double-add, no remove).
        assertTrue(INAVCalculator(NAV).isOracleRegistered(EXISTING_AAVEV3_CORE));
    }

    function test_registerExternal_morphoVault_factoryHook() public {
        // Pre-condition: existing morpho vault adapter is in NAV.
        if (!INAVCalculator(NAV).isOracleRegistered(EXISTING_MORPHO_VAULT)) {
            console2.log("skipping: EXISTING_MORPHO_VAULT not registered on this fork block");
            return;
        }

        vm.prank(owner);
        morphoFactory.registerExternal(EXISTING_MORPHO_VAULT);

        assertTrue(morphoFactory.isTracked(EXISTING_MORPHO_VAULT));
        assertFalse(morphoFactory.isFromFactory(EXISTING_MORPHO_VAULT));
        assertTrue(registry.isAdapterRegistered(EXISTING_MORPHO_VAULT));
        assertEq(registry.adapterProtocol(EXISTING_MORPHO_VAULT), K_MORPHO_V);
    }

    function test_unregister_dropsFromRegistryAndNAV() public {
        // First register an existing adapter.
        vm.prank(owner);
        registry.registerExternal(K_AAVEV3, EXISTING_AAVEV3_CORE);
        assertTrue(registry.isAdapterRegistered(EXISTING_AAVEV3_CORE));
        assertTrue(INAVCalculator(NAV).isOracleRegistered(EXISTING_AAVEV3_CORE));

        // Now unregister.
        vm.prank(owner);
        registry.unregister(EXISTING_AAVEV3_CORE);

        assertFalse(registry.isAdapterRegistered(EXISTING_AAVEV3_CORE));
        assertFalse(INAVCalculator(NAV).isOracleRegistered(EXISTING_AAVEV3_CORE));
    }
}
