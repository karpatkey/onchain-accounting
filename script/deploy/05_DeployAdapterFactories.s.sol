// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {console2} from "forge-std/console2.sol";

import {BalanceAdapterRegistry} from "../../src/balances/factories/BalanceAdapterRegistry.sol";
import {AaveV3InstanceAdapterFactory} from "../../src/balances/protocols/aave/AaveV3InstanceAdapterFactory.sol";
import {AaveV3SafetyModuleAdapterFactory} from "../../src/balances/protocols/aave/AaveV3SafetyModuleAdapterFactory.sol";
import {AuraAdapterFactory} from "../../src/balances/protocols/aura/AuraAdapterFactory.sol";
import {BalancerV3AdapterFactory} from "../../src/balances/protocols/balancer/BalancerV3AdapterFactory.sol";
import {CapAdapterFactory} from "../../src/balances/protocols/cap/CapAdapterFactory.sol";
import {CompoundV3CometAdapterFactory} from "../../src/balances/protocols/compound/CompoundV3CometAdapterFactory.sol";
import {ConvexAdapterFactory} from "../../src/balances/protocols/convex/ConvexAdapterFactory.sol";
import {CurveAdapterFactory} from "../../src/balances/protocols/curve/CurveAdapterFactory.sol";
import {DaiDsrAdapterFactory} from "../../src/balances/protocols/maker/DaiDsrAdapterFactory.sol";
import {GearboxMarketAdapterFactory} from "../../src/balances/protocols/gearbox/GearboxMarketAdapterFactory.sol";
import {MorphoMarketAdapterFactory} from "../../src/balances/protocols/morpho/MorphoMarketAdapterFactory.sol";
import {MorphoVaultAdapterFactory} from "../../src/balances/protocols/morpho/MorphoVaultAdapterFactory.sol";
import {SkySavingsUsdsAdapterFactory} from "../../src/balances/protocols/sky/SkySavingsUsdsAdapterFactory.sol";
import {SparkLendAdapterFactory} from "../../src/balances/protocols/spark/SparkLendAdapterFactory.sol";
import {
    StakeWiseV3OsTokenAdapterFactory
} from "../../src/balances/protocols/stakewise/StakeWiseV3OsTokenAdapterFactory.sol";
import {
    StakeWiseV3VaultAdapterFactory
} from "../../src/balances/protocols/stakewise/StakeWiseV3VaultAdapterFactory.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title DeployAdapterFactories
/// @notice Deploys the central `BalanceAdapterRegistry` + 16 per-protocol adapter factories via CREATE2.
/// @dev
///   - All 17 contracts land at identical addresses on every chain (same canonical CREATE2 deployer,
///     same constructor args, same salts).
///   - Initial owner is the deployer EOA (`chainConfig.admin`); ownership is transferred to the
///     OIV Safe (`chainConfig.safeMultisig`) at the end of this script. Mirrors the NAV v2 pattern.
///   - One manual step is still required after this script (one tx per chain, signed by the OIV Safe):
///       `NAVCalculator.grantRole(MANAGER, <Registry>)`
///     Without it, registry calls to `addBalanceOracle` revert. A Safe tx file is emitted as a hint.
///   - Idempotent: skips deploy if the predicted address already has code.
///   - Set `PERSIST_DEPLOYMENTS=1` to write addresses back to chain configs.
contract DeployAdapterFactories is BaseDeployScript {
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    /// @notice Salt scheme version. Bump if any factory's constructor or the registry's constructor changes.
    uint256 internal constant FACTORY_SALT_VERSION = 1;

    struct FactorySpec {
        string name; // Registry config key, e.g. "BalancerV3AdapterFactory"
        bytes32 protocolKey; // keccak256("<protocol>") used by the registry
        bytes creationCode; // Compile-time creation code for the factory
    }

    function run() public override {
        setUp();
        validateAddresses();

        address eoaOwner = chainConfig.admin;
        address finalOwner = chainConfig.safeMultisig;
        address nav = readDeployedAddress("NAVCalculatorProxy");
        require(nav != address(0), "NAVCalculatorProxy not in chain config - run the NAV deploy first");

        // 1. Predict the registry address.
        bytes32 saltRegistry = generateSalt("BalanceAdapterRegistry", FACTORY_SALT_VERSION);
        bytes memory regInitCode =
            abi.encodePacked(type(BalanceAdapterRegistry).creationCode, abi.encode(nav, eoaOwner));
        address registry = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, saltRegistry, regInitCode);

        // 2. Predict every factory address.
        FactorySpec[] memory specs = _allFactorySpecs(registry, nav, eoaOwner);
        address[] memory factories = new address[](specs.length);
        bytes32[] memory salts = new bytes32[](specs.length);

        console2.log("\n=== BalanceAdapter Factory Deployment (CREATE2) ===");
        console2.log("EOA (initial owner):", eoaOwner);
        console2.log("Final owner (Safe):  ", finalOwner);
        console2.log("NAVCalculator:       ", nav);
        console2.log("Registry (predicted):", registry);
        for (uint256 i; i < specs.length; ++i) {
            salts[i] = generateSalt(specs[i].name, FACTORY_SALT_VERSION);
            factories[i] = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, salts[i], specs[i].creationCode);
            console2.log(specs[i].name, factories[i]);
        }

        // 3. Broadcast.
        startBroadcast();

        if (registry.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(saltRegistry, regInitCode));
            require(ok && registry.code.length > 0, "registry deploy failed");
        }

        for (uint256 i; i < specs.length; ++i) {
            if (factories[i].code.length == 0) {
                (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(salts[i], specs[i].creationCode));
                require(ok && factories[i].code.length > 0, string.concat(specs[i].name, " deploy failed"));
            }
        }

        BalanceAdapterRegistry reg = BalanceAdapterRegistry(registry);

        // 4. Wire factories into the registry.
        for (uint256 i; i < specs.length; ++i) {
            if (reg.factory(specs[i].protocolKey) != factories[i]) {
                reg.setFactory(specs[i].protocolKey, factories[i]);
            }
        }

        // 5. Transfer ownership: registry + every factory → OIV Safe.
        if (reg.owner() != finalOwner) {
            reg.transferOwnership(finalOwner);
        }
        for (uint256 i; i < specs.length; ++i) {
            Ownable f = Ownable(factories[i]);
            if (f.owner() != finalOwner) {
                f.transferOwnership(finalOwner);
            }
        }

        stopBroadcast();

        // 6. Persist + post-flight assertions.
        saveDeployedAddress("BalanceAdapterRegistry", registry);
        for (uint256 i; i < specs.length; ++i) {
            saveDeployedAddress(specs[i].name, factories[i]);
        }

        require(reg.owner() == finalOwner, "registry owner not Safe");
        for (uint256 i; i < specs.length; ++i) {
            require(Ownable(factories[i]).owner() == finalOwner, string.concat(specs[i].name, " owner not Safe"));
            require(reg.factory(specs[i].protocolKey) == factories[i], string.concat(specs[i].name, " not wired"));
        }

        console2.log("\n=== Done ===");
        console2.log(
            "[reminder] OIV Safe must call NAVCalculator.grantRole(MANAGER, <Registry>) "
            "before any deploy/registerExternal call. Otherwise the registry's addBalanceOracle reverts."
        );
    }

    /// @dev Returns specs for every factory deployed in this PR. Order is stable across runs/chains
    ///      so predicted addresses don't shift if a single line is reordered.
    function _allFactorySpecs(address registry, address nav, address initialOwner)
        internal
        pure
        returns (FactorySpec[] memory specs)
    {
        specs = new FactorySpec[](16);
        bytes memory ctor = abi.encode(registry, nav, initialOwner);

        specs[0] = FactorySpec({
            name: "AaveV3InstanceAdapterFactory",
            protocolKey: keccak256("AaveV3Instance"),
            creationCode: abi.encodePacked(type(AaveV3InstanceAdapterFactory).creationCode, ctor)
        });
        specs[1] = FactorySpec({
            name: "AaveV3SafetyModuleAdapterFactory",
            protocolKey: keccak256("AaveV3SafetyModule"),
            creationCode: abi.encodePacked(type(AaveV3SafetyModuleAdapterFactory).creationCode, ctor)
        });
        specs[2] = FactorySpec({
            name: "AuraAdapterFactory",
            protocolKey: keccak256("Aura"),
            creationCode: abi.encodePacked(type(AuraAdapterFactory).creationCode, ctor)
        });
        specs[3] = FactorySpec({
            name: "BalancerV3AdapterFactory",
            protocolKey: keccak256("BalancerV3"),
            creationCode: abi.encodePacked(type(BalancerV3AdapterFactory).creationCode, ctor)
        });
        specs[4] = FactorySpec({
            name: "CapAdapterFactory",
            protocolKey: keccak256("Cap"),
            creationCode: abi.encodePacked(type(CapAdapterFactory).creationCode, ctor)
        });
        specs[5] = FactorySpec({
            name: "CompoundV3CometAdapterFactory",
            protocolKey: keccak256("CompoundV3Comet"),
            creationCode: abi.encodePacked(type(CompoundV3CometAdapterFactory).creationCode, ctor)
        });
        specs[6] = FactorySpec({
            name: "ConvexAdapterFactory",
            protocolKey: keccak256("Convex"),
            creationCode: abi.encodePacked(type(ConvexAdapterFactory).creationCode, ctor)
        });
        specs[7] = FactorySpec({
            name: "CurveAdapterFactory",
            protocolKey: keccak256("Curve"),
            creationCode: abi.encodePacked(type(CurveAdapterFactory).creationCode, ctor)
        });
        specs[8] = FactorySpec({
            name: "DaiDsrAdapterFactory",
            protocolKey: keccak256("DaiDsr"),
            creationCode: abi.encodePacked(type(DaiDsrAdapterFactory).creationCode, ctor)
        });
        specs[9] = FactorySpec({
            name: "GearboxMarketAdapterFactory",
            protocolKey: keccak256("GearboxMarket"),
            creationCode: abi.encodePacked(type(GearboxMarketAdapterFactory).creationCode, ctor)
        });
        specs[10] = FactorySpec({
            name: "MorphoMarketAdapterFactory",
            protocolKey: keccak256("MorphoMarket"),
            creationCode: abi.encodePacked(type(MorphoMarketAdapterFactory).creationCode, ctor)
        });
        specs[11] = FactorySpec({
            name: "MorphoVaultAdapterFactory",
            protocolKey: keccak256("MorphoVault"),
            creationCode: abi.encodePacked(type(MorphoVaultAdapterFactory).creationCode, ctor)
        });
        specs[12] = FactorySpec({
            name: "SkySavingsUsdsAdapterFactory",
            protocolKey: keccak256("SkySavingsUsds"),
            creationCode: abi.encodePacked(type(SkySavingsUsdsAdapterFactory).creationCode, ctor)
        });
        specs[13] = FactorySpec({
            name: "SparkLendAdapterFactory",
            protocolKey: keccak256("SparkLend"),
            creationCode: abi.encodePacked(type(SparkLendAdapterFactory).creationCode, ctor)
        });
        specs[14] = FactorySpec({
            name: "StakeWiseV3OsTokenAdapterFactory",
            protocolKey: keccak256("StakeWiseV3OsToken"),
            creationCode: abi.encodePacked(type(StakeWiseV3OsTokenAdapterFactory).creationCode, ctor)
        });
        specs[15] = FactorySpec({
            name: "StakeWiseV3VaultAdapterFactory",
            protocolKey: keccak256("StakeWiseV3Vault"),
            creationCode: abi.encodePacked(type(StakeWiseV3VaultAdapterFactory).creationCode, ctor)
        });
    }
}
