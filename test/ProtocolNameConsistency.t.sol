// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";

import {ProtocolNameResolver} from "script/utils/ProtocolNameResolver.sol";
import {ProtocolNames} from "src/utils/ProtocolNames.sol";

import {AaveUmbrellaBalanceAdapter} from "src/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.sol";
import {AaveV3SafetyModuleBalanceAdapter} from "src/balances/BalanceAdapters/AaveV3SafetyModuleBalanceAdapter.sol";
import {
    AaveV3InstancesMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/AaveV3InstancesMetaBalanceAdapter.sol";
import {
    StakeWiseV3ExitQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.sol";
import {
    StakeWiseV3VaultsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/StakeWiseV3VaultsMetaBalanceAdapter.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";

/// @dev Minimal deployed-bytecode stub. Several adapter constructors assert `code.length > 0` on their pinned
///      dependencies (`AddressCheckLib.requireContract`); none of those dependencies are *called* by
///      `protocolName()`, which is `pure`/`view` over a constant, so an empty contract is sufficient here.
contract CodeStub {}

/// @title ProtocolNameConsistencyTest
/// @author KPK
/// @notice Guards the invariant that `IPositionDescribable.protocolName()` names the PROTOCOL, never the product:
///         every adapter sharing a `ProtocolIds` protocol id must report the SAME display name.
/// @dev This is the invariant that broke. `AaveUmbrellaBalanceAdapter` returned "Aave Umbrella" while its two
///      siblings under `ProtocolIds.AAVE_V3` (`AaveV3SafetyModuleBalanceAdapter`, `AaveV3InstancesMetaBalanceAdapter`)
///      returned "Aave V3". Consumers group configured adapters by display name — the typed
///      `protocolBrand`/`protocolId`/`protocolSubId` are `private constant` and only ride on `PositionBalance`
///      structs from an *account* read, so a consumer listing adapters never sees them — and Umbrella therefore
///      rendered as a peer protocol of Aave V3 instead of one of its products.
///
///      The invariant has two halves and they need different instruments:
///
///        1. **Hardcoded names** (12 adapters) — a string literal in the adapter, so the name is in the bytecode.
///           Asserted by deploying the adapters in a shared-protocol-id group and comparing (`test_aaveV3Group_*`,
///           `test_stakeWiseV3Group_*`). Only groups with >1 member can disagree, so only those are deployed.
///
///        2. **Constructor-argument names** (21 meta adapters) — `MetaBalanceAdapter` takes `protocolName_` in its
///           constructor, so the name exists nowhere in `src/`; it is a deployment-time value. Neither a source
///           sweep nor a unit test that constructs an adapter with a string of its own choosing can audit it. It is
///           audited here at the layer that actually supplies it: `ProtocolNameResolver`, which `04_DeployBalanceAdapters`
///           now uses in place of a per-call-site JSON literal (`test_resolver_*`), plus a sweep asserting the
///           `protocol` keys still present in every chain's deploy config agree with the resolver
///           (`test_deployConfigs_agreeWithResolver`) so those documentary values cannot rot.
contract ProtocolNameConsistencyTest is Test {
    /// @dev Chains that have a `contracts-deployment-config/{balance,meta-balance}-adapters/<id>.json`.
    uint256[7] internal CONFIGURED_CHAINS = [uint256(1), 10, 56, 100, 137, 8453, 42161];

    BalancesHarness internal nav;
    address internal stub;

    function setUp() public {
        nav = new BalancesHarness();
        stub = address(new CodeStub());
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // Half 1 — hardcoded names: adapters sharing a protocol id must agree
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice The three `ProtocolIds.AAVE_V3` products — lending instances, Safety Module, Umbrella — must all
    ///         report "Aave V3". Their products are carried by `positionLabels()`, not by `protocolName()`.
    function test_aaveV3Group_reportsOneProtocolName() public {
        string memory umbrella = new AaveUmbrellaBalanceAdapter(stub, address(nav)).protocolName();
        string memory safetyModule = new AaveV3SafetyModuleBalanceAdapter(address(nav)).protocolName();
        string memory instances = new AaveV3InstancesMetaBalanceAdapter(
                ProtocolNameResolver.protocolNameFor("AaveV3InstancesMeta"), address(nav)
            ).protocolName();

        assertEq(umbrella, ProtocolNames.AAVE_V3, "AaveUmbrella must name the protocol, not the product");
        assertEq(safetyModule, ProtocolNames.AAVE_V3, "AaveV3SafetyModule must name the protocol");
        assertEq(instances, ProtocolNames.AAVE_V3, "AaveV3InstancesMeta must name the protocol");
    }

    /// @notice Umbrella keeps its product identity in the breadcrumb below the protocol level — nothing is lost by
    ///         the protocolName() fix. The rendered breadcrumb is `["Aave V3", "Umbrella Module"]`.
    function test_aaveUmbrella_productLivesInPositionLabels() public {
        AaveUmbrellaBalanceAdapter umbrella = new AaveUmbrellaBalanceAdapter(stub, address(nav));
        string[] memory labels = umbrella.positionLabels("");
        assertEq(labels.length, 1, "expected a single-segment breadcrumb");
        assertEq(labels[0], "Umbrella Module", "product name must survive in positionLabels");
    }

    /// @notice The two `ProtocolIds.STAKEWISE_V3` adapters — the vaults meta-adapter (constructor-arg name) and the
    ///         exit-queue adapter (hardcoded name) — must agree. This group spans BOTH halves of the audit.
    function test_stakeWiseV3Group_reportsOneProtocolName() public {
        string memory exitQueue =
            new StakeWiseV3ExitQueueAssistedBalanceAdapter(stub, stub, "osETH", address(nav), 1 days).protocolName();
        string memory vaults = new StakeWiseV3VaultsMetaBalanceAdapter(
                stub, stub, ProtocolNameResolver.protocolNameFor("StakeWiseV3VaultsMeta"), address(nav)
            ).protocolName();

        assertEq(exitQueue, ProtocolNames.STAKEWISE_V3, "StakeWiseV3ExitQueue must name the protocol");
        assertEq(vaults, ProtocolNames.STAKEWISE_V3, "StakeWiseV3VaultsMeta must name the protocol");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // Half 2 — constructor-argument names: the deploy layer must hand siblings the same string
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Every pair of meta adapters sharing a protocol id must resolve to one name. These are the adapters
    ///         whose name is a deployment-time value, so this is the only place the property can be stated.
    function test_resolver_siblingsShareOneName() public pure {
        _assertSameName("MorphoVaultsMeta", "MorphoMarketsMeta");
        _assertSameName("BalancerV2PoolsMeta", "BalancerV2GaugesMeta");
        _assertSameName("BalancerV3PoolsMeta", "BalancerV3GaugesMeta");
        _assertSameName("CurvePoolsMeta", "CurveGaugesMeta");
        _assertSameName("GearboxV3MarketsMeta", "GearboxV3CreditAccountsMeta");
        _assertSameName("FluidFTokensMeta", "FluidVaultsMeta");
        // Cross-family: meta adapter vs. hardcoded adapter of the same protocol.
        _assertSameName("StakeWiseV3VaultsMeta", "StakeWiseV3ExitQueueAssisted");
        _assertSameName("AaveV3InstancesMeta", "AaveV3SafetyModule");
        _assertSameName("AaveV3InstancesMeta", "AaveUmbrella");
        // Legacy per-instance keys must land on the same protocol as the meta adapter that superseded them.
        _assertSameName("CompoundV3CometsMeta", "CompoundV3_USDC");
        _assertSameName("FluidFTokensMeta", "Fluid_fToken_GHO");
        _assertSameName("MorphoVaultsMeta", "MorphoVault_kpkEURC_V1");
    }

    /// @notice The resolver must not silently return "" for a key the deploy script will hand to a constructor —
    ///         an unmapped key would deploy an adapter with an empty display name.
    function test_resolver_coversEveryConfiguredAdapterKey() public view {
        for (uint256 c = 0; c < CONFIGURED_CHAINS.length; c++) {
            uint256 chainId = CONFIGURED_CHAINS[c];
            _forEachAdapterKey(chainId, "balance-adapters", _checkResolved);
            _forEachAdapterKey(chainId, "meta-balance-adapters", _checkResolved);
        }
    }

    /// @notice The `protocol` strings left in the deploy configs are documentary now that `04` resolves the name
    ///         from `ProtocolNames`. This sweep keeps them truthful — and is what catches per-chain drift, the
    ///         failure mode a source review cannot see (the same adapter given a different name on a different
    ///         chain). It is what surfaced "Compound v3" vs "Compound V3" and "Fluid Lending" vs "Fluid".
    function test_deployConfigs_agreeWithResolver() public view {
        for (uint256 c = 0; c < CONFIGURED_CHAINS.length; c++) {
            uint256 chainId = CONFIGURED_CHAINS[c];
            _forEachAdapterKey(chainId, "balance-adapters", _checkConfigMatches);
            _forEachAdapterKey(chainId, "meta-balance-adapters", _checkConfigMatches);
        }
    }

    /// @notice Distinct protocols must not collide on one display name — otherwise a consumer grouping by name
    ///         would merge two genuinely different protocols, the mirror image of the Umbrella bug.
    function test_distinctProtocolsHaveDistinctNames() public pure {
        string[24] memory names = [
            ProtocolNames.WALLET,
            ProtocolNames.AAVE_V3,
            ProtocolNames.SPARK,
            ProtocolNames.MORPHO,
            ProtocolNames.EULER,
            ProtocolNames.COMPOUND_V3,
            ProtocolNames.FLUID,
            ProtocolNames.GEARBOX_V3,
            ProtocolNames.CAP,
            ProtocolNames.BALANCER_V2,
            ProtocolNames.BALANCER_V3,
            ProtocolNames.CURVE,
            ProtocolNames.CONVEX,
            ProtocolNames.UNISWAP_V2,
            ProtocolNames.UNISWAP_V3,
            ProtocolNames.PANCAKESWAP_V2,
            ProtocolNames.PANCAKESWAP_V3,
            ProtocolNames.STAKEWISE_V3,
            ProtocolNames.LIDO,
            ProtocolNames.KELP,
            ProtocolNames.STADER,
            ProtocolNames.ETHERFI,
            ProtocolNames.ETHENA,
            ProtocolNames.NEXUS_MUTUAL
        ];

        for (uint256 i = 0; i < names.length; i++) {
            assertGt(bytes(names[i]).length, 0, "protocol display name must not be empty");
            for (uint256 j = i + 1; j < names.length; j++) {
                assertTrue(
                    keccak256(bytes(names[i])) != keccak256(bytes(names[j])),
                    string.concat("duplicate protocol display name: ", names[i])
                );
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    function _assertSameName(string memory keyA, string memory keyB) internal pure {
        string memory a = ProtocolNameResolver.protocolNameFor(keyA);
        string memory b = ProtocolNameResolver.protocolNameFor(keyB);
        assertGt(bytes(a).length, 0, string.concat("unmapped adapter key: ", keyA));
        assertEq(a, b, string.concat(keyA, " and ", keyB, " share a protocol id but resolve to different names"));
    }

    /// @dev Applies `check(chainId, file, key)` to every top-level adapter key in a deploy-config file. Missing
    ///      files are skipped (not every chain has both).
    function _forEachAdapterKey(
        uint256 chainId,
        string memory dir,
        function(uint256, string memory, string memory) internal view check
    ) internal view {
        string memory path = string.concat(
            vm.projectRoot(), "/script/config/contracts-deployment-config/", dir, "/", vm.toString(chainId), ".json"
        );
        if (!vm.exists(path)) return;
        string memory json = vm.readFile(path);
        string[] memory keys = vm.parseJsonKeys(json, "$");
        for (uint256 i = 0; i < keys.length; i++) {
            check(chainId, json, keys[i]);
        }
    }

    function _checkResolved(uint256 chainId, string memory, string memory key) internal pure {
        assertGt(
            bytes(ProtocolNameResolver.protocolNameFor(key)).length,
            0,
            string.concat("chain ", vm.toString(chainId), ": adapter key has no protocol name mapping: ", key)
        );
    }

    function _checkConfigMatches(uint256 chainId, string memory json, string memory key) internal view {
        string memory configured = _readProtocol(json, key);
        if (bytes(configured).length == 0) return; // key carries no `protocol` field — nothing to contradict
        assertEq(
            configured,
            ProtocolNameResolver.protocolNameFor(key),
            string.concat(
                "chain ", vm.toString(chainId), ": config protocol name for ", key, " disagrees with ProtocolNames"
            )
        );
    }

    /// @dev Reads `.<key>.protocol`, falling back to `.<key>.constructor.protocol` — both spellings are in use.
    function _readProtocol(string memory json, string memory key) internal view returns (string memory) {
        string memory direct = string.concat(".", key, ".protocol");
        if (vm.keyExistsJson(json, direct)) return vm.parseJsonString(json, direct);
        string memory nested = string.concat(".", key, ".constructor.protocol");
        if (vm.keyExistsJson(json, nested)) return vm.parseJsonString(json, nested);
        return "";
    }
}
