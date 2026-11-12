// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {DeploySalts} from "script/deploy/DeploySalts.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";

import {AssetKindRegistry} from "src/nav/AssetKindRegistry.sol";
import {
    AaveV3InstancesMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/AaveV3InstancesMetaBalanceAdapter.sol";
import {AaveV4SpokesMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/AaveV4SpokesMetaBalanceAdapter.sol";
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
import {MorphoMarketsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/MorphoMarketsMetaBalanceAdapter.sol";
import {
    SymbioticVaultsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/SymbioticVaultsMetaBalanceAdapter.sol";
import {
    UniswapV3PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolsMetaBalanceAdapter.sol";
import {FluidVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/FluidVaultsMetaBalanceAdapter.sol";
import {YoVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/YoVaultsMetaBalanceAdapter.sol";

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

    /// @dev The Uniswap V3 NonfungiblePositionManager, on every chain that actually has the canonical one.
    ///      Verified by calling `name()` + `factory()` — NOT by codehash, which differs per chain because the
    ///      NPM stores `factory`/`WETH9` as immutables. Several other chains have unrelated code at this exact
    ///      address, so presence of code is not evidence of identity.
    address constant UNIV3_NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    /// @dev Gnosis hosts its own Uniswap V3 deployment; its NPM is NOT the canonical one above.
    address constant GNOSIS_UNIV3_NPM = 0xAE8fbE656a77519a7490054274910129c9244FA3;

    /// @dev Morpho on Ethereum and Base. Arbitrum deployed later at a different address (see below).
    address constant MORPHO_ETH_BASE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant MORPHO_ARBITRUM = 0x6c247b1F6182318877311737BaC0844bAa518F5e;

    /// @dev Fluid's VaultResolver — confirmed by calling `FACTORY()` (same `0x324c5Dc1…` everywhere) and
    ///      `getAllVaultsAddresses()` (real, per-chain vault sets) on Ethereum, BNB, Polygon, Base, Plasma and
    ///      Arbitrum. Fluid deploys it deterministically.
    address constant FLUID_VAULT_RESOLVER = 0xA5C3E16523eeeDDcC34706b0E6bE88b4c6EA95cC;

    function _derive(bytes memory creationCode, string memory name, uint256 version) internal pure returns (address) {
        return _deriveWithArgs(creationCode, abi.encode(NAV_PROXY), name, version);
    }

    function _deriveWithArgs(bytes memory creationCode, bytes memory ctorArgs, string memory name, uint256 version)
        internal
        pure
        returns (address)
    {
        bytes32 salt = ConfigReader.computeSalt(name, version);
        bytes memory initCode = abi.encodePacked(creationCode, ctorArgs);
        return vm.computeCreate2Address(salt, keccak256(initCode), CANONICAL_CREATE2_DEPLOYER);
    }

    /// @notice Pins the two protocol-arg adapter addresses, and asserts they collapse to one address exactly
    ///         where the configured protocol address is shared — no further.
    /// @dev **Read from config, not from constants, and deliberately so.** These adapters take
    ///      `(protocolAddress, nav)`, so their address is fleet-wide only across chains that configure the SAME
    ///      protocol address. Deriving from a hardcoded constant would assert nothing about the deployment; the
    ///      Morpho arguments are therefore read from
    ///      `script/config/contracts-deployment-config/meta-balance-adapters/<chainId>.json`, so the day someone
    ///      repoints one chain's `morpho` this test fails instead of a redeploy silently landing elsewhere.
    ///
    ///      Asserting Arbitrum DIFFERS matters as much as asserting Ethereum and Base match: Arbitrum's Morpho is
    ///      a separate deployment, and a change making all three equal would mean the adapter had stopped binding
    ///      Arbitrum to the Morpho that chain actually has.
    function testProtocolArgAdapterAddresses() public view {
        // Uniswap V3 — one address across every chain carrying the canonical NonfungiblePositionManager.
        // The constructor argument is READ FROM CONFIG, not from the constant: script 04 derives the CREATE2
        // address from whatever config holds, so a test deriving from a literal would stay green while a
        // repointed `positionManager` silently moved the deployed address. The constant is still asserted, so
        // an unintended config edit fails here naming the expected value rather than only a shifted address.
        address npm = _configAddr(1, "UniswapV3PoolsMeta", "positionManager");
        assertEq(npm, UNIV3_NPM, "chain 1 positionManager is no longer the canonical NonfungiblePositionManager");
        assertEq(
            _deriveWithArgs(
                type(UniswapV3PoolsMetaBalanceAdapter).creationCode,
                abi.encode(npm, NAV_PROXY),
                "UniswapV3PoolsMetaBalanceAdapter",
                DeploySalts.UNISWAP_V3_POOLS_META
            ),
            0x2F7e8f78FD8EE977F6D53752b03A79c77012Ba52,
            "UniswapV3PoolsMeta address moved - see DEPLOYED_ADDRESSES.md"
        );

        // Uniswap V3 on GNOSIS binds a DIFFERENT NonfungiblePositionManager, so it is NOT part of the ☆ set
        // above and gets its own address. Same shape as the Morpho-Arbitrum case below: derive from chain-100
        // config, pin the result, and assert it DIFFERS from the canonical-NPM address — the last assertion is
        // the one that would catch a config edit silently re-pointing Gnosis at Ethereum's NPM, which would
        // collapse the two addresses and leave the recorded Gnosis deployment orphaned.
        //
        // Added because nothing derived this address: `0xA336f717…` appeared only in
        // `script/config/deployments/100.json` and `DEPLOYED_ADDRESSES.md`, so creation-code drift or a salt
        // bump would move the real deployment while every record still named the old value — the exact
        // "silent and expensive" class this file's header exists to prevent.
        address npmGnosis = _configAddr(100, "UniswapV3PoolsMeta", "positionManager");
        assertEq(
            npmGnosis, GNOSIS_UNIV3_NPM, "chain 100 positionManager is no longer Gnosis's NonfungiblePositionManager"
        );
        address univ3OnGnosis = _deriveWithArgs(
            type(UniswapV3PoolsMetaBalanceAdapter).creationCode,
            abi.encode(npmGnosis, NAV_PROXY),
            "UniswapV3PoolsMetaBalanceAdapter",
            DeploySalts.UNISWAP_V3_POOLS_META
        );
        assertEq(
            univ3OnGnosis,
            0xaC47D9Cbe8B3EDc9c9d1a6c8092054299bBC1adE,
            "UniswapV3PoolsMeta (Gnosis) address moved - see DEPLOYED_ADDRESSES.md"
        );
        assertTrue(
            univ3OnGnosis != 0x2F7e8f78FD8EE977F6D53752b03A79c77012Ba52,
            "Gnosis must bind its OWN NonfungiblePositionManager, not the canonical one"
        );

        // Fluid Vaults — one address across all six chains carrying the deterministic VaultResolver.
        address resolver = _configAddr(1, "FluidVaultsMeta", "vaultResolver");
        assertEq(resolver, FLUID_VAULT_RESOLVER, "chain 1 vaultResolver is no longer Fluid's deterministic one");
        assertEq(
            _deriveWithArgs(
                type(FluidVaultsMetaBalanceAdapter).creationCode,
                abi.encode(resolver, NAV_PROXY),
                "FluidVaultsMetaBalanceAdapter",
                DeploySalts.FLUID_VAULTS_META
            ),
            0x161EB6952Ffc4319a05bd8FEBB1B90283F267005,
            "FluidVaultsMeta address moved - see DEPLOYED_ADDRESSES.md"
        );

        bytes memory code = type(MorphoMarketsMetaBalanceAdapter).creationCode;
        address onEth = _deriveForChain(code, 1);
        address onBase = _deriveForChain(code, 8453);
        address onArb = _deriveForChain(code, 42161);

        assertEq(onEth, 0x08e590BcFc753fC6383aFE327253558C962D3EB6, "MorphoMarketsMeta (Ethereum) address moved");
        assertEq(onEth, onBase, "MorphoMarketsMeta must share one address across Ethereum and Base");
        assertEq(onArb, 0xCFf47e28B51a7f4599150f73c348E1a155A93437, "MorphoMarketsMeta (Arbitrum) address moved");
        assertTrue(onArb != onEth, "Arbitrum must bind its OWN Morpho deployment, not Ethereum's address");
    }

    /// @dev One constructor address as the deploy config actually holds it — the same source script 04 reads.
    function _configAddr(uint256 chainId, string memory adapterKey, string memory param)
        internal
        view
        returns (address)
    {
        return vm.parseAddress(ConfigReader.readAdapterParam(vm, chainId, "balanceAdapters", adapterKey, param));
    }

    /// @dev Derives `MorphoMarketsMeta` for one chain using that chain's CONFIGURED `morpho` address.
    function _deriveForChain(bytes memory code, uint256 chainId) internal view returns (address) {
        address morpho = _configAddr(chainId, "MorphoMarketsMeta", "morpho");
        return _deriveWithArgs(
            code, abi.encode(morpho, NAV_PROXY), "MorphoMarketsMetaBalanceAdapter", DeploySalts.MORPHO_MARKETS_META
        );
    }

    /// @notice NOT YET DEPLOYED. Pins the address the yoUSD Edge governance batch registers
    ///         (`addMetaBalanceAdapter(<this>, [Edge])`, scheduled on the TimelockController BEFORE the deploy), so a
    ///         bytecode change that would move it — and silently invalidate the scheduled calldata — fails here. If it
    ///         moves on purpose, re-derive the batch calldata in the PR before scheduling.
    function testYoVaultsMetaAddress() public {
        address derived = _derive(
            type(YoVaultsMetaBalanceAdapter).creationCode, "YoVaultsMetaBalanceAdapter", DeploySalts.YO_VAULTS_META
        );
        emit log_named_address("YoVaultsMeta CREATE2 address", derived);
        assertEq(
            derived,
            0x72B0D33f8c2F783c1F9aa4A866Ba19604e3fF355,
            "YoVaultsMeta address moved - re-derive the governance batch calldata"
        );
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
            0xa1b3c695A768A6Ce571fF699F463224CB32260C1,
            "AaveV3InstancesMeta moved"
        );
        // GENERATION 2. Version 1 (`0x79cad958…`) is superseded: it left `positionInstanceId` at zero, so the two
        // legs a Spoke emits for the same underlying against two Hubs were indistinguishable in every identity
        // field — and being DEBT legs, a consumer de-duplicating by the reconciliation key over-reported NAV.
        // Both the creation code and the salt changed, so the address moves for two independent reasons; see
        // DeploySalts.AAVE_V4_SPOKES_META.
        assertEq(
            _derive(
                type(AaveV4SpokesMetaBalanceAdapter).creationCode,
                "AaveV4SpokesMetaBalanceAdapter",
                DeploySalts.AAVE_V4_SPOKES_META
            ),
            0xAd5b905ad5BB13909aE658a1910bC4cdFcD81dE3,
            "AaveV4SpokesMeta moved"
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
            0x8AE70624CB7729B0408C8f0ce8ffdac9974FE33A,
            "BalancerV3PoolsMeta moved"
        );
        assertEq(
            _derive(
                type(CurvePoolsMetaBalanceAdapter).creationCode,
                "CurvePoolsMetaBalanceAdapter",
                DeploySalts.CURVE_POOLS_META
            ),
            0x4c25B00401d28d5F6FC65a7Af8386b239FA5e735,
            "CurvePoolsMeta moved"
        );
        assertEq(
            _derive(
                type(EulerVaultsMetaBalanceAdapter).creationCode,
                "EulerVaultsMetaBalanceAdapter",
                DeploySalts.EULER_VAULTS_META
            ),
            0x331566e8F7b48Fa683fE865403Cf4311b50A7710,
            "EulerVaultsMeta moved"
        );
        assertEq(
            _derive(
                type(FluidFTokensMetaBalanceAdapter).creationCode,
                "FluidFTokensMetaBalanceAdapter",
                DeploySalts.FLUID_FTOKENS_META
            ),
            0xb1a03cDD28cAA91f409C417C9f56ab53bc9d7ae9,
            "FluidFTokensMeta moved"
        );
        assertEq(
            _derive(
                type(GearboxV3MarketsMetaBalanceAdapter).creationCode,
                "GearboxV3MarketsMetaBalanceAdapter",
                DeploySalts.GEARBOX_V3_MARKETS_META
            ),
            0xE338E5d4F7adF34107239D59828DEAD2fa2cfD86,
            "GearboxV3MarketsMeta moved"
        );
        assertEq(
            _derive(
                type(MorphoVaultsMetaBalanceAdapter).creationCode,
                "MorphoVaultsMetaBalanceAdapter",
                DeploySalts.MORPHO_VAULTS_META
            ),
            0x72a012B30b240458C3f79fd20E5c2A907d77e54f,
            "MorphoVaultsMeta moved"
        );
        assertEq(
            _derive(
                type(SymbioticVaultsMetaBalanceAdapter).creationCode,
                "SymbioticVaultsMetaBalanceAdapter",
                DeploySalts.SYMBIOTIC_VAULTS_META
            ),
            0x320699dE0693d71C28f5559a68635495AdA0826c,
            "SymbioticVaultsMeta moved"
        );
    }

    /// @notice The whole point of these salts: the derivation must not depend on the chain.
    /// @notice Re-derives the fleet-wide addresses using each chain's OWN recorded NAV proxy.
    /// @dev **Why this reads the deployment records instead of looping over `vm.chainId`.** An earlier version of
    ///      this test set `vm.chainId(...)` and re-derived from the `NAV_PROXY` constant. That could never fail:
    ///      `vm.computeCreate2Address` is a pure function of (deployer, salt, init-code hash) and reads no chain
    ///      state, so the loop asserted a value against itself five times.
    ///
    ///      The property that actually matters is that every chain's RECORDED NAV proxy is the same address —
    ///      that is what makes the init code identical fleet-wide and the derived addresses collapse to one. So
    ///      the NAV is read per chain from `script/config/deployments/<chainId>.json`, and a single chain whose
    ///      record drifts (a re-proxied chain, a bad paste) now fails here instead of being discovered when a
    ///      redeploy silently lands somewhere new.
    function testAddressesAreChainIndependent() public view {
        uint256[5] memory chains = [uint256(1), 10, 8453, 42161, 534352];
        address registry;
        address morpho;
        for (uint256 i; i < chains.length; ++i) {
            address navOnChain = ConfigReader.readDeployedAddress(vm, chains[i], "NAVCalculatorProxy");
            assertEq(navOnChain, NAV_PROXY, "recorded NAV proxy differs from the canonical fleet-wide address");

            address r = _deriveWithArgs(
                type(AssetKindRegistry).creationCode,
                abi.encode(navOnChain),
                "AssetKindRegistry",
                DeploySalts.ASSET_KIND_REGISTRY
            );
            address m = _deriveWithArgs(
                type(MorphoVaultsMetaBalanceAdapter).creationCode,
                abi.encode(navOnChain),
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
        assertEq(DeploySalts.UNISWAP_V3_POOLS_META, 2, "UniswapV3PoolsMeta salt version changed");
        assertEq(DeploySalts.MORPHO_MARKETS_META, 2, "MorphoMarketsMeta salt version changed");
        assertEq(DeploySalts.FLUID_VAULTS_META, 2, "FluidVaultsMeta salt version changed");
    }
}
