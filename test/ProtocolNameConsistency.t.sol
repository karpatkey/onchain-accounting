// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ProtocolNameResolver} from "script/utils/ProtocolNameResolver.sol";
import {ProtocolNames} from "src/utils/ProtocolNames.sol";

import {AaveUmbrellaBalanceAdapter} from "src/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.sol";
import {AaveV3SafetyModuleBalanceAdapter} from "src/balances/BalanceAdapters/AaveV3SafetyModuleBalanceAdapter.sol";
import {CapBalanceAdapter} from "src/balances/BalanceAdapters/CapBalanceAdapter.sol";
import {ERC20DefaultBalanceAdapter} from "src/balances/BalanceAdapters/ERC20DefaultBalanceAdapter.sol";
import {EthenaCooldownBalanceAdapter} from "src/balances/BalanceAdapters/EthenaCooldownBalanceAdapter.sol";
import {KelpWithdrawalQueueBalanceAdapter} from "src/balances/BalanceAdapters/KelpWithdrawalQueueBalanceAdapter.sol";
import {LidoWithdrawalQueueBalanceAdapter} from "src/balances/BalanceAdapters/LidoWithdrawalQueueBalanceAdapter.sol";
import {SparkLendBalanceAdapter} from "src/balances/BalanceAdapters/SparkLendBalanceAdapter.sol";
import {
    StaderWithdrawalQueueBalanceAdapter
} from "src/balances/BalanceAdapters/StaderWithdrawalQueueBalanceAdapter.sol";
import {
    EtherFiWithdrawalQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol";
import {
    NexusMutualStakingPoolsAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol";
import {
    StakeWiseV3ExitQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.sol";
import {
    AaveV3InstancesMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/AaveV3InstancesMetaBalanceAdapter.sol";
import {
    StakeWiseV3VaultsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/StakeWiseV3VaultsMetaBalanceAdapter.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";

/// @dev Minimal deployed-bytecode stub. Several adapter constructors assert `code.length > 0` on their pinned
///      dependencies (`AddressCheckLib.requireContract`); none of those dependencies are *called* by
///      `protocolName()`, which is `pure`/`view` over a constant, so an empty contract is sufficient.
contract CodeStub {}

/// @dev SparkLend's constructor walks `dataProvider.ADDRESSES_PROVIDER().getPool()`, so its stub needs the chain.
contract PoolProviderStub {
    function getPool() external view returns (address) {
        return address(this);
    }
}

contract SparkDataProviderStub {
    address public immutable PROVIDER;

    constructor() {
        PROVIDER = address(new PoolProviderStub());
    }

    // solhint-disable-next-line func-name-mixedcase
    function ADDRESSES_PROVIDER() external view returns (address) {
        return PROVIDER;
    }
}

/// @dev Stader's constructor resolves `userWithdrawalManager.staderConfig().getStakePoolManager()` and
///      `requireContract`s the result, so its stub needs the same two-hop graph.
contract StaderConfigStub {
    address public immutable POOL_MANAGER;

    constructor(address poolManager_) {
        POOL_MANAGER = poolManager_;
    }

    function getStakePoolManager() external view returns (address) {
        return POOL_MANAGER;
    }
}

contract StaderWithdrawalManagerStub {
    address public immutable CONFIG;

    constructor() {
        CONFIG = address(new StaderConfigStub(address(new CodeStub())));
    }

    function staderConfig() external view returns (address) {
        return CONFIG;
    }
}

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
///           Every one is deployed here and pinned to its `ProtocolNames` constant
///           (`test_hardcodedAdapters_matchCanonicalNames`). That is what makes "use the constant, not a literal" a
///           checked rule rather than an aspiration: a literal that drifts from its constant fails here even for
///           single-member protocols, which no group comparison would catch.
///
///        2. **Constructor-argument names** (21 meta adapters) — `MetaBalanceAdapter` takes `protocolName_` in its
///           constructor, so the name exists nowhere in `src/`; it is a deployment-time value. Neither a source
///           sweep nor a unit test that constructs an adapter with a string of its own choosing can audit it. It is
///           audited at the layer that actually supplies it: `ProtocolNameResolver`, which both
///           `04_DeployBalanceAdapters` and the `IntegrationFromConfigBase` harness use.
///
///      Note on what is *not* asserted here: comparing `protocolNameFor(keyA)` to `protocolNameFor(keyB)` for two
///      keys that share a prefix is a tautology — both are the same `return` statement, so the assertion holds for
///      any value of the constants. Sibling agreement is therefore asserted against the deployed adapters and the
///      constants, and the resolver is checked for *mapping* (`isMapped`) and for *config agreement* instead.
contract ProtocolNameConsistencyTest is Test {
    string internal constant PLAIN_DIR = "script/config/contracts-deployment-config/balance-adapters";
    string internal constant META_DIR = "script/config/contracts-deployment-config/meta-balance-adapters";

    BalancesHarness internal nav;
    address internal stub;

    function setUp() public {
        nav = new BalancesHarness();
        stub = address(new CodeStub());
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // Half 1 — hardcoded names
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Every adapter that hardcodes its display name must report exactly its `ProtocolNames` constant.
    /// @dev Covers all 12, including the single-member protocols (Kelp, Lido, Cap, Spark, Ethena, Stader, ether.fi,
    ///      Nexus Mutual, Wallet) that no shared-protocol-id comparison can reach. Deploying each adapter — rather
    ///      than restating its literal — is what keeps this non-tautological: the assertion reads the string out of
    ///      compiled bytecode.
    function test_hardcodedAdapters_matchCanonicalNames() public {
        assertEq(
            new AaveUmbrellaBalanceAdapter(stub, address(nav)).protocolName(),
            ProtocolNames.AAVE_V3,
            "AaveUmbrella must name the protocol, not the product"
        );
        assertEq(
            new AaveV3SafetyModuleBalanceAdapter(address(nav)).protocolName(),
            ProtocolNames.AAVE_V3,
            "AaveV3SafetyModule"
        );
        assertEq(
            new SparkLendBalanceAdapter(address(new SparkDataProviderStub()), address(nav)).protocolName(),
            ProtocolNames.SPARK,
            "SparkLend"
        );
        assertEq(new CapBalanceAdapter(stub, stub, stub, address(nav)).protocolName(), ProtocolNames.CAP, "Cap");
        assertEq(
            new EthenaCooldownBalanceAdapter(stub, stub, address(nav)).protocolName(), ProtocolNames.ETHENA, "Ethena"
        );
        assertEq(
            new KelpWithdrawalQueueBalanceAdapter(stub, address(nav)).protocolName(), ProtocolNames.KELP, "Kelp DAO"
        );
        assertEq(
            new LidoWithdrawalQueueBalanceAdapter(stub, stub, address(nav)).protocolName(), ProtocolNames.LIDO, "Lido"
        );
        assertEq(
            new StaderWithdrawalQueueBalanceAdapter(address(new StaderWithdrawalManagerStub()), stub, address(nav))
                .protocolName(),
            ProtocolNames.STADER,
            "Stader"
        );
        assertEq(
            new EtherFiWithdrawalQueueAssistedBalanceAdapter(stub, stub, stub, address(nav)).protocolName(),
            ProtocolNames.ETHERFI,
            "ether.fi"
        );
        assertEq(
            new NexusMutualStakingPoolsAssistedBalanceAdapter(stub, stub, stub, address(nav)).protocolName(),
            ProtocolNames.NEXUS_MUTUAL,
            "Nexus Mutual"
        );
        assertEq(
            new StakeWiseV3ExitQueueAssistedBalanceAdapter(stub, stub, "osETH", address(nav), 1 days).protocolName(),
            ProtocolNames.STAKEWISE_V3,
            "StakeWiseV3ExitQueue"
        );
        assertEq(
            new ERC20DefaultBalanceAdapter(address(nav), new address[](0)).protocolName(),
            ProtocolNames.WALLET,
            "ERC20Default"
        );
    }

    /// @notice The three `ProtocolIds.AAVE_V3` products — lending instances, Safety Module, Umbrella — must all
    ///         report one name. Two are hardcoded, one takes it from the deploy resolver, so this spans both halves.
    function test_aaveV3Group_reportsOneProtocolName() public {
        string memory umbrella = new AaveUmbrellaBalanceAdapter(stub, address(nav)).protocolName();
        string memory safetyModule = new AaveV3SafetyModuleBalanceAdapter(address(nav)).protocolName();
        string memory instances = new AaveV3InstancesMetaBalanceAdapter(
                ProtocolNameResolver.protocolNameFor("AaveV3InstancesMeta"), address(nav)
            ).protocolName();

        assertEq(umbrella, safetyModule, "Umbrella and Safety Module share aave-v3 but disagree");
        assertEq(umbrella, instances, "Umbrella and lending instances share aave-v3 but disagree");
        assertEq(umbrella, ProtocolNames.AAVE_V3, "aave-v3 group must report the canonical name");
    }

    /// @notice Umbrella keeps its product identity in the breadcrumb below the protocol level — nothing is lost by
    ///         the protocolName() fix. The rendered breadcrumb is `["Aave V3", "Umbrella Module"]`.
    function test_aaveUmbrella_productLivesInPositionLabels() public {
        string[] memory labels = new AaveUmbrellaBalanceAdapter(stub, address(nav)).positionLabels("");
        assertEq(labels.length, 1, "expected a single-segment breadcrumb");
        assertEq(labels[0], "Umbrella Module", "product name must survive in positionLabels");
    }

    /// @notice The two `ProtocolIds.STAKEWISE_V3` adapters — the vaults meta-adapter (constructor-arg name) and the
    ///         exit-queue adapter (hardcoded name) — must agree.
    function test_stakeWiseV3Group_reportsOneProtocolName() public {
        string memory exitQueue =
            new StakeWiseV3ExitQueueAssistedBalanceAdapter(stub, stub, "osETH", address(nav), 1 days).protocolName();
        string memory vaults = new StakeWiseV3VaultsMetaBalanceAdapter(
                stub, stub, ProtocolNameResolver.protocolNameFor("StakeWiseV3VaultsMeta"), address(nav)
            ).protocolName();

        assertEq(exitQueue, vaults, "exit queue and vaults share stakewise-v3 but disagree");
        assertEq(exitQueue, ProtocolNames.STAKEWISE_V3, "stakewise-v3 group must report the canonical name");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // Half 2 — constructor-argument names, audited at the deploy layer
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Every meta-adapter key in every chain's deploy config must resolve. These are the keys
    ///         `04_DeployBalanceAdapters` (and the integration harness) feed straight into a `protocolName_`
    ///         constructor argument, so an unmapped one would deploy an immutable, permanently nameless adapter.
    /// @dev Enumerates the config files on disk rather than a hardcoded chain list — a new chain's config is
    ///      audited the moment it is added, without anyone remembering to extend an array. Only the meta folder is
    ///      required to resolve: plain adapters hardcode their name and never reach the resolver.
    function test_everyMetaAdapterKeyResolves() public view {
        string[] memory files = _configFiles(META_DIR);
        assertGt(files.length, 0, "no meta-adapter configs found - path wrong?");
        for (uint256 f = 0; f < files.length; f++) {
            string memory json = vm.readFile(files[f]);
            string[] memory keys = _adapterKeys(json);
            for (uint256 i = 0; i < keys.length; i++) {
                assertTrue(
                    ProtocolNameResolver.isMapped(keys[i]),
                    string.concat(files[f], ": meta adapter key has no ProtocolNames mapping: ", keys[i])
                );
            }
        }
    }

    /// @notice The `protocol` strings left in the deploy configs are documentary now that the display name is
    ///         resolved from `ProtocolNames`. This sweep keeps them truthful — and it is what catches per-chain
    ///         drift, the failure mode a source review cannot see (the same adapter given a different name on a
    ///         different chain). It surfaced "Compound v3" vs "Compound V3" and "Fluid Lending" vs "Fluid".
    /// @dev Keys the resolver does not map are skipped rather than failed: plain adapters may carry a `protocol`
    ///      key for documentation while hardcoding their name, and a future plain adapter must not be forced to
    ///      invent a resolver entry no code path reads.
    function test_deployConfigs_agreeWithResolver() public view {
        string[] memory dirs = new string[](2);
        dirs[0] = PLAIN_DIR;
        dirs[1] = META_DIR;

        uint256 checked;
        for (uint256 d = 0; d < dirs.length; d++) {
            string[] memory files = _configFiles(dirs[d]);
            for (uint256 f = 0; f < files.length; f++) {
                string memory json = vm.readFile(files[f]);
                string[] memory keys = _adapterKeys(json);
                for (uint256 i = 0; i < keys.length; i++) {
                    if (!ProtocolNameResolver.isMapped(keys[i])) continue;
                    string memory configured = _readProtocol(json, keys[i]);
                    if (bytes(configured).length == 0) continue;
                    assertEq(
                        configured,
                        ProtocolNameResolver.protocolNameFor(keys[i]),
                        string.concat(files[f], ": config protocol name for ", keys[i], " disagrees with ProtocolNames")
                    );
                    checked++;
                }
            }
        }
        assertGt(checked, 0, "swept no config protocol names - enumeration broken?");
    }

    /// @notice An unmapped key must revert, not fall through to "". `MetaBalanceAdapter` does not validate
    ///         `protocolName_`, and adapters are immutable, so a silent "" would ship a permanently nameless
    ///         adapter that only a redeploy plus re-registration could fix.
    function test_resolver_revertsOnUnmappedKey() public {
        vm.expectRevert(abi.encodeWithSelector(ProtocolNameResolver.UnmappedProtocolName.selector, "PendleMarketsMeta"));
        this.resolve("PendleMarketsMeta");
        assertFalse(ProtocolNameResolver.isMapped("PendleMarketsMeta"), "isMapped must agree with the revert");
    }

    /// @dev External wrapper so `vm.expectRevert` can catch a revert from an `internal pure` library function.
    function resolve(string calldata key) external pure returns (string memory) {
        return ProtocolNameResolver.protocolNameFor(key);
    }

    /// @notice A version-agnostic prefix must not hand a future major version its predecessor's name — that is the
    ///         only path in the table that yields a WRONG name rather than a revert.
    function test_resolver_unknownVersionRevertsRatherThanInheriting() public view {
        assertFalse(ProtocolNameResolver.isMapped("StakeWiseV4VaultsMeta"), "StakeWiseV4 must not inherit V3's name");
        assertFalse(ProtocolNameResolver.isMapped("AaveV4InstancesMeta"), "AaveV4 must not inherit V3's name");
        assertFalse(ProtocolNameResolver.isMapped("BalancerV4PoolsMeta"), "BalancerV4 must not inherit V3's name");
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

    /// @dev Every `<chainId>.json` under a deploy-config directory, discovered on disk.
    function _configFiles(string memory dir) internal view returns (string[] memory out) {
        string memory root = string.concat(vm.projectRoot(), "/", dir);
        Vm.DirEntry[] memory entries = vm.readDir(root);
        out = new string[](entries.length);
        uint256 n;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].isDir) continue;
            if (!_endsWith(entries[i].path, ".json")) continue;
            out[n++] = entries[i].path;
        }
        assembly {
            mstore(out, n)
        }
    }

    /// @dev Top-level adapter keys, excluding `$`-prefixed metadata (`$comment`, …). Mirrors
    ///      `ConfigReader._namesIn`, which filters them for the same reason: `$comment` is an established
    ///      convention in this config tree and must not be mistaken for an adapter.
    function _adapterKeys(string memory json) internal pure returns (string[] memory out) {
        string[] memory all = vm.parseJsonKeys(json, "$");
        out = new string[](all.length);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            bytes memory k = bytes(all[i]);
            if (k.length == 0 || k[0] == "$") continue;
            out[n++] = all[i];
        }
        assembly {
            mstore(out, n)
        }
    }

    /// @dev Reads `.<key>.protocol`, falling back to `.<key>.constructor.protocol` — both spellings are in use.
    function _readProtocol(string memory json, string memory key) internal view returns (string memory) {
        string memory direct = string.concat(".", key, ".protocol");
        if (vm.keyExistsJson(json, direct)) return vm.parseJsonString(json, direct);
        string memory nested = string.concat(".", key, ".constructor.protocol");
        if (vm.keyExistsJson(json, nested)) return vm.parseJsonString(json, nested);
        return "";
    }

    function _endsWith(string memory value, string memory suffix) internal pure returns (bool) {
        bytes memory v = bytes(value);
        bytes memory s = bytes(suffix);
        if (v.length < s.length) return false;
        for (uint256 i = 0; i < s.length; i++) {
            if (v[v.length - s.length + i] != s[i]) return false;
        }
        return true;
    }
}
