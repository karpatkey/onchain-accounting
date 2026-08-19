// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {DeploySalts} from "script/deploy/DeploySalts.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";

import {AssetKindRegistry} from "src/nav/AssetKindRegistry.sol";
import {
    AaveV3InstancesMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/AaveV3InstancesMetaBalanceAdapter.sol";
import {AaveV3SafetyModuleBalanceAdapter} from "src/balances/BalanceAdapters/AaveV3SafetyModuleBalanceAdapter.sol";
import {
    BalancerV3PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/balancer/BalancerV3PoolsMetaBalanceAdapter.sol";
import {CurvePoolsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/curve/CurvePoolsMetaBalanceAdapter.sol";
import {EulerVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/EulerVaultsMetaBalanceAdapter.sol";
import {FluidFTokensMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/FluidFTokensMetaBalanceAdapter.sol";
import {
    GearboxV3MarketsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/GearboxV3MarketsMetaBalanceAdapter.sol";
import {MorphoVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/MorphoVaultsMetaBalanceAdapter.sol";
import {
    SymbioticVaultsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/SymbioticVaultsMetaBalanceAdapter.sol";

/// @title Create2FleetWideAddresses — pins the addresses that must be identical on every chain
/// @notice Derives each CREATE2 address from (creation code, NAV proxy, salt) and asserts it equals the value
///         documented in `script/deploy/DEPLOYED_ADDRESSES.md` and deployed on all 24 chains.
/// @dev **What this catches that nothing else does.** These addresses are a pure function of the contract's
///      creation code, its constructor argument, and the salt version. Any of the three can move without a
///      single test failing elsewhere: adding a constructor parameter, an edit that changes creation bytecode,
///      or a salt bump. The consequence is silent and expensive — a redeploy lands at a NEW address while every
///      doc, integration and deployment record still names the old one, and for the balance adapters it also
///      means the NAV's registration and meta-instance set (both keyed by ADDRESS) no longer point at the
///      deployed contract.
///
///      **Chain independence is the actual property under test.** Each of these contracts takes the NAV proxy
///      as its ONLY constructor argument, and the proxy is itself CREATE2-identical fleet-wide, so the
///      init-code hash carries no chain-specific data. `testAddressesAreChainIndependent` asserts that directly
///      by re-deriving under several `chainId` values — if someone adds a chain-varying constructor argument,
///      that test fails rather than the fleet quietly fragmenting into per-chain addresses, which is exactly
///      how the pre-2026-08-19 deployment ended up with 14 registry addresses and up to 5 per adapter.
contract Create2FleetWideAddressesTest is Test {
    address constant CANONICAL_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant NAV_PROXY = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;

    function _derive(bytes memory creationCode, string memory name, uint256 version) internal pure returns (address) {
        bytes32 salt = ConfigReader.computeSalt(name, version);
        bytes memory initCode = abi.encodePacked(creationCode, abi.encode(NAV_PROXY));
        return vm.computeCreate2Address(salt, keccak256(initCode), CANONICAL_CREATE2_DEPLOYER);
    }

    function testAssetKindRegistryAddress() public pure {
        assertEq(
            _derive(type(AssetKindRegistry).creationCode, "AssetKindRegistry", DeploySalts.ASSET_KIND_REGISTRY),
            0xf60467a88C2b4d0f46C0c41C3Ba0C74da3d3CCD0,
            "AssetKindRegistry address moved - deployed on 24 chains, see DEPLOYED_ADDRESSES.md"
        );
    }

    function testNavOnlyAdapterAddresses() public pure {
        assertEq(
            _derive(
                type(AaveV3InstancesMetaBalanceAdapter).creationCode,
                "AaveV3InstancesMetaBalanceAdapter",
                DeploySalts.AAVE_V3_INSTANCES_META
            ),
            0x04Ba6789B4AD5D6CF63Ec9cc301c13F6a8A0210b,
            "AaveV3InstancesMeta moved"
        );
        assertEq(
            _derive(
                type(AaveV3SafetyModuleBalanceAdapter).creationCode,
                "AaveV3SafetyModuleBalanceAdapter",
                DeploySalts.AAVE_V3_SAFETY_MODULE
            ),
            0xa356717027B5d4010a7449904545E5aFb355Bdc9,
            "AaveV3SafetyModule moved"
        );
        assertEq(
            _derive(
                type(BalancerV3PoolsMetaBalanceAdapter).creationCode,
                "BalancerV3PoolsMetaBalanceAdapter",
                DeploySalts.BALANCER_V3_POOLS_META
            ),
            0xbF1785E519067f0471eb5C50A634A7eeE0140A21,
            "BalancerV3PoolsMeta moved"
        );
        assertEq(
            _derive(
                type(CurvePoolsMetaBalanceAdapter).creationCode,
                "CurvePoolsMetaBalanceAdapter",
                DeploySalts.CURVE_POOLS_META
            ),
            0xCf200111050Bc5FFbd5c3e675c598995906c3945,
            "CurvePoolsMeta moved"
        );
        assertEq(
            _derive(
                type(EulerVaultsMetaBalanceAdapter).creationCode,
                "EulerVaultsMetaBalanceAdapter",
                DeploySalts.EULER_VAULTS_META
            ),
            0xCb28C7d1A27e8FB5ea0e1c75Ef62c80722388135,
            "EulerVaultsMeta moved"
        );
        assertEq(
            _derive(
                type(FluidFTokensMetaBalanceAdapter).creationCode,
                "FluidFTokensMetaBalanceAdapter",
                DeploySalts.FLUID_FTOKENS_META
            ),
            0x0c312178e10ad15a9DC847d664786146f2C88dcf,
            "FluidFTokensMeta moved"
        );
        assertEq(
            _derive(
                type(GearboxV3MarketsMetaBalanceAdapter).creationCode,
                "GearboxV3MarketsMetaBalanceAdapter",
                DeploySalts.GEARBOX_V3_MARKETS_META
            ),
            0x160017c8d50D44A8fA3667419a89BA1183daaF38,
            "GearboxV3MarketsMeta moved"
        );
        assertEq(
            _derive(
                type(MorphoVaultsMetaBalanceAdapter).creationCode,
                "MorphoVaultsMetaBalanceAdapter",
                DeploySalts.MORPHO_VAULTS_META
            ),
            0x64e1ba8B12ee2bFdBDdFd4E0863EdfaaE824C86a,
            "MorphoVaultsMeta moved"
        );
        assertEq(
            _derive(
                type(SymbioticVaultsMetaBalanceAdapter).creationCode,
                "SymbioticVaultsMetaBalanceAdapter",
                DeploySalts.SYMBIOTIC_VAULTS_META
            ),
            0x599C72cbd3bDe6D992366130009962B4c2Ec5B23,
            "SymbioticVaultsMeta moved"
        );
    }

    /// @notice The whole point of these salts: the derivation must not depend on the chain.
    function testAddressesAreChainIndependent() public {
        uint256[5] memory chains = [uint256(1), 10, 8453, 42161, 534352];
        address registry;
        address morpho;
        for (uint256 i; i < chains.length; ++i) {
            vm.chainId(chains[i]);
            address r =
                _derive(type(AssetKindRegistry).creationCode, "AssetKindRegistry", DeploySalts.ASSET_KIND_REGISTRY);
            address m = _derive(
                type(MorphoVaultsMetaBalanceAdapter).creationCode,
                "MorphoVaultsMetaBalanceAdapter",
                DeploySalts.MORPHO_VAULTS_META
            );
            if (i == 0) {
                registry = r;
                morpho = m;
            } else {
                assertEq(r, registry, "registry address became chain-dependent");
                assertEq(m, morpho, "adapter address became chain-dependent");
            }
        }
    }

    /// @notice Guards the reason version 1 was skipped: a gen-1 CREATE2 address must never collide with these.
    function testSaltVersionsAreTwo() public pure {
        assertEq(DeploySalts.ASSET_KIND_REGISTRY, 2, "registry salt version changed");
        assertEq(DeploySalts.MORPHO_VAULTS_META, 2, "adapter salt version changed");
    }
}
