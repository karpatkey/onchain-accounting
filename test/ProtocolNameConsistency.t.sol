// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ProtocolNames} from "src/utils/ProtocolNames.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

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
import {
    CompoundV3CometsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/CompoundV3CometsMetaBalanceAdapter.sol";
import {
    ConvexCurveLPStakingMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/ConvexCurveLPStakingMetaBalanceAdapter.sol";
import {EulerVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/EulerVaultsMetaBalanceAdapter.sol";
import {FluidFTokensMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/FluidFTokensMetaBalanceAdapter.sol";
import {FluidVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/FluidVaultsMetaBalanceAdapter.sol";
import {
    GearboxV3CreditAccountsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/GearboxV3CreditAccountsMetaBalanceAdapter.sol";
import {
    GearboxV3MarketsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/GearboxV3MarketsMetaBalanceAdapter.sol";
import {MorphoMarketsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/MorphoMarketsMetaBalanceAdapter.sol";
import {MorphoVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/MorphoVaultsMetaBalanceAdapter.sol";
import {
    BalancerV2GaugesMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/balancer/BalancerV2GaugesMetaBalanceAdapter.sol";
import {
    BalancerV2PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/balancer/BalancerV2PoolsMetaBalanceAdapter.sol";
import {
    BalancerV3GaugesMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/balancer/BalancerV3GaugesMetaBalanceAdapter.sol";
import {
    BalancerV3PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/balancer/BalancerV3PoolsMetaBalanceAdapter.sol";
import {CurveGaugesMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/curve/CurveGaugesMetaBalanceAdapter.sol";
import {CurvePoolsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/curve/CurvePoolsMetaBalanceAdapter.sol";
import {
    PancakeSwapV2PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/pancakeswap/PancakeSwapV2PoolsMetaBalanceAdapter.sol";
import {
    PancakeSwapV3PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/pancakeswap/PancakeSwapV3PoolsMetaBalanceAdapter.sol";
import {
    UniswapV2PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV2PoolsMetaBalanceAdapter.sol";
import {
    UniswapV3PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolsMetaBalanceAdapter.sol";
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
///        2. **Meta adapters** (21) — `MetaBalanceAdapter.protocolName()` returns
///           `ProtocolNames.forProtocolId(_protocolId())`, so the name is a pure function of the typed identity the
///           adapter already declares. Sibling agreement is true **by construction**: two adapters sharing a
///           protocol id evaluate the same expression over the same input, so there is nothing left to assert. What
///           remains assertable is that every protocol id the family declares HAS a name, and that an unknown id
///           reverts rather than returning "".
///
///      Note on what deliberately is NOT asserted: an earlier revision compared `protocolNameFor(keyA)` to
///      `protocolNameFor(keyB)` for two config keys sharing a resolver prefix. Both were the same `return`
///      statement, so those assertions held for any value of the constants — a tautology. Deriving the name from
///      `_protocolId()` removed the resolver, and with it the class of test that could look meaningful while
///      asserting nothing.
contract ProtocolNameConsistencyTest is Test {
    string internal constant PLAIN_DIR = "script/config/contracts-deployment-config/balance-adapters";
    string internal constant META_DIR = "script/config/contracts-deployment-config/meta-balance-adapters";

    /// @dev Number of concrete meta adapters. Pinned so adding one fails `test_metaAdapterCensus` until the
    ///      author also adds it to `test_everyMetaAdapterHasANonEmptyName`.
    uint256 internal constant META_ADAPTER_COUNT = 21;

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
    ///         report one name. Two hardcode it; the meta adapter derives it from `_protocolId()`. Spans both halves.
    function test_aaveV3Group_reportsOneProtocolName() public {
        string memory umbrella = new AaveUmbrellaBalanceAdapter(stub, address(nav)).protocolName();
        string memory safetyModule = new AaveV3SafetyModuleBalanceAdapter(address(nav)).protocolName();
        string memory instances = new AaveV3InstancesMetaBalanceAdapter(address(nav)).protocolName();

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

    /// @notice The two `ProtocolIds.STAKEWISE_V3` adapters — the vaults meta-adapter (derived name) and the
    ///         exit-queue adapter (hardcoded name) — must agree.
    function test_stakeWiseV3Group_reportsOneProtocolName() public {
        string memory exitQueue =
            new StakeWiseV3ExitQueueAssistedBalanceAdapter(stub, stub, "osETH", address(nav), 1 days).protocolName();
        string memory vaults = new StakeWiseV3VaultsMetaBalanceAdapter(stub, stub, address(nav)).protocolName();

        assertEq(exitQueue, vaults, "exit queue and vaults share stakewise-v3 but disagree");
        assertEq(exitQueue, ProtocolNames.STAKEWISE_V3, "stakewise-v3 group must report the canonical name");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // Half 2 — meta adapters: the name is DERIVED, so the invariant is structural
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice EVERY meta adapter must resolve to a non-empty display name — asserted by deploying all of them
    ///         and calling `protocolName()`, not against a hand-written list of protocol ids.
    /// @dev `MetaBalanceAdapter.protocolName()` is `ProtocolNames.forProtocolId(_protocolId())`, so sibling
    ///      agreement is structural and needs no assertion. What is NOT structural is *totality*: a new meta
    ///      adapter whose `_protocolId()` has no `forProtocolId` branch compiles, passes its own tests (they never
    ///      call `protocolName()`), and ships — adapters are immutable, plain CREATE — after which every verbose
    ///      read returns `protocolName == ""` for it, because the revert is swallowed by NAVCalculator's
    ///      fail-open `_safeString`. Calling `protocolName()` on a real instance is the only assertion that
    ///      catches that, and `test_metaAdapterCensus` below stops a new adapter from silently escaping this list.
    function test_everyMetaAdapterHasANonEmptyName() public {
        address n = address(nav);
        string[] memory names = new string[](META_ADAPTER_COUNT);
        uint256 i;
        names[i++] = new AaveV3InstancesMetaBalanceAdapter(n).protocolName();
        names[i++] = new CompoundV3CometsMetaBalanceAdapter(stub, stub, n).protocolName();
        names[i++] = new ConvexCurveLPStakingMetaBalanceAdapter(stub, stub, n).protocolName();
        names[i++] = new EulerVaultsMetaBalanceAdapter(n).protocolName();
        names[i++] = new FluidFTokensMetaBalanceAdapter(n).protocolName();
        names[i++] = new FluidVaultsMetaBalanceAdapter(stub, n).protocolName();
        names[i++] = new GearboxV3CreditAccountsMetaBalanceAdapter(n).protocolName();
        names[i++] = new GearboxV3MarketsMetaBalanceAdapter(n).protocolName();
        names[i++] = new MorphoMarketsMetaBalanceAdapter(stub, n).protocolName();
        names[i++] = new MorphoVaultsMetaBalanceAdapter(n).protocolName();
        names[i++] = new StakeWiseV3VaultsMetaBalanceAdapter(stub, stub, n).protocolName();
        names[i++] = new BalancerV2GaugesMetaBalanceAdapter(stub, stub, n).protocolName();
        names[i++] = new BalancerV2PoolsMetaBalanceAdapter(stub, n).protocolName();
        names[i++] = new BalancerV3GaugesMetaBalanceAdapter(stub, n).protocolName();
        names[i++] = new BalancerV3PoolsMetaBalanceAdapter(n).protocolName();
        names[i++] = new CurveGaugesMetaBalanceAdapter(stub, stub, n).protocolName();
        names[i++] = new CurvePoolsMetaBalanceAdapter(n).protocolName();
        names[i++] = new PancakeSwapV2PoolsMetaBalanceAdapter(n).protocolName();
        names[i++] = new PancakeSwapV3PoolsMetaBalanceAdapter(stub, n).protocolName();
        names[i++] = new UniswapV2PoolsMetaBalanceAdapter(n).protocolName();
        names[i++] = new UniswapV3PoolsMetaBalanceAdapter(stub, n).protocolName();

        assertEq(i, META_ADAPTER_COUNT, "exercised count must equal META_ADAPTER_COUNT");
        for (uint256 k = 0; k < names.length; k++) {
            assertGt(bytes(names[k]).length, 0, "meta adapter reports an empty protocolName");
        }
    }

    /// @notice A new meta adapter must not be able to slip past the test above unnoticed.
    /// @dev Counts the concrete `*MetaBalanceAdapter.sol` compilation artifacts and requires the number to equal
    ///      the number this file actually deploys. Adding an adapter therefore fails here until it is added to
    ///      `test_everyMetaAdapterHasANonEmptyName` — at which point that test catches a missing `forProtocolId`
    ///      branch. Without this census the coverage list is a hand-maintained snapshot that silently rots.
    ///
    ///      Counts `out/` rather than `src/`: `fs_permissions` grants read on `out` but not `src`, and adding a
    ///      permission would mean editing `foundry.toml`, which is off-limits while the library pin is being
    ///      coordinated across parallel branches. `out/` mirrors the source set one directory per source file.
    ///      A stale artifact from a deleted adapter would make this over-count — a loud failure fixed by
    ///      `forge clean`, never a silent pass. CI always builds fresh.
    function test_metaAdapterCensus() public view {
        uint256 found = _countMetaAdapterSources("out");
        assertEq(
            found,
            META_ADAPTER_COUNT,
            "meta-adapter count changed: add the new adapter to test_everyMetaAdapterHasANonEmptyName and bump META_ADAPTER_COUNT"
        );
    }

    /// @notice An unknown protocol id must revert rather than return "". A meta adapter is immutable, so a silent
    ///         "" would be permanent; and because `protocolName()` is only reached through NAVCalculator's
    ///         fail-open staticcall, reverting degrades to an empty display name rather than breaking a NAV read.
    function test_unknownProtocolIdReverts() public {
        bytes32 unknown = keccak256("pendle-v2");
        vm.expectRevert(abi.encodeWithSelector(ProtocolNames.UnknownProtocolId.selector, unknown));
        this.nameFor(unknown);
    }

    /// @dev External wrapper so `vm.expectRevert` can catch a revert from an `internal pure` library function.
    function nameFor(bytes32 protocolId) external pure returns (string memory) {
        return ProtocolNames.forProtocolId(protocolId);
    }

    /// @dev Counts concrete meta-adapter artifacts, excluding the abstract base and the interface.
    function _countMetaAdapterSources(string memory relDir) internal view returns (uint256 count) {
        Vm.DirEntry[] memory entries = vm.readDir(string.concat(vm.projectRoot(), "/", relDir));
        for (uint256 i = 0; i < entries.length; i++) {
            if (!_endsWith(entries[i].path, "MetaBalanceAdapter.sol")) continue;
            if (_endsWith(entries[i].path, "/MetaBalanceAdapter.sol")) continue; // abstract base
            if (_endsWith(entries[i].path, "/IMetaBalanceAdapter.sol")) continue; // interface
            count++;
        }
    }

    function _endsWith(string memory value, string memory suffix) internal pure returns (bool) {
        bytes memory v = bytes(value);
        bytes memory sfx = bytes(suffix);
        if (v.length < sfx.length) return false;
        for (uint256 i = 0; i < sfx.length; i++) {
            if (v[v.length - sfx.length + i] != sfx[i]) return false;
        }
        return true;
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
}
