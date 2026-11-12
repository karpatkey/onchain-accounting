// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ProtocolNames} from "src/utils/ProtocolNames.sol";
import {
    LidoStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/LidoStakedEthWalletMetaBalanceAdapter.sol";
import {
    EtherFiStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/EtherFiStakedEthWalletMetaBalanceAdapter.sol";
import {
    RocketPoolStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/RocketPoolStakedEthWalletMetaBalanceAdapter.sol";
import {
    RenzoRestakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/RenzoRestakedEthWalletMetaBalanceAdapter.sol";
import {
    KelpRestakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/KelpRestakedEthWalletMetaBalanceAdapter.sol";
import {
    StaderStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/StaderStakedEthWalletMetaBalanceAdapter.sol";
import {
    StakeWiseV3OsTokenWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/StakeWiseV3OsTokenWalletMetaBalanceAdapter.sol";
import {
    LiquidCollectiveStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/LiquidCollectiveStakedEthWalletMetaBalanceAdapter.sol";
import {
    AnkrStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/AnkrStakedEthWalletMetaBalanceAdapter.sol";
import {
    CoinbaseStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/CoinbaseStakedEthWalletMetaBalanceAdapter.sol";
import {
    ReserveBasketsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/ReserveBasketsWalletMetaBalanceAdapter.sol";
import {
    EthenaSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/EthenaSavingsWalletMetaBalanceAdapter.sol";
import {
    SkySavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/SkySavingsWalletMetaBalanceAdapter.sol";
import {
    AaveSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/AaveSavingsWalletMetaBalanceAdapter.sol";
import {
    SparkSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/SparkSavingsWalletMetaBalanceAdapter.sol";
import {
    MapleSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/MapleSavingsWalletMetaBalanceAdapter.sol";
import {
    NexusMutualVaultsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/NexusMutualVaultsWalletMetaBalanceAdapter.sol";

import {AaveUmbrellaBalanceAdapter} from "src/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.sol";
import {AaveV3SafetyModuleBalanceAdapter} from "src/balances/BalanceAdapters/AaveV3SafetyModuleBalanceAdapter.sol";
import {CapStablecoinBalanceAdapter} from "src/balances/BalanceAdapters/cap/CapStablecoinBalanceAdapter.sol";
import {CapSavingsBalanceAdapter} from "src/balances/BalanceAdapters/cap/CapSavingsBalanceAdapter.sol";
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
    MerklRewardsAttestedBalanceAdapter
} from "src/balances/AttestedBalanceAdapters/MerklRewardsAttestedBalanceAdapter.sol";
import {
    AaveV3InstancesMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/AaveV3InstancesMetaBalanceAdapter.sol";
import {AaveV4SpokesMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/AaveV4SpokesMetaBalanceAdapter.sol";
import {
    StakeWiseV3VaultsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/StakeWiseV3VaultsMetaBalanceAdapter.sol";
import {PolygonStakingMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/PolygonStakingMetaBalanceAdapter.sol";
import {
    CompoundV3CometsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/CompoundV3CometsMetaBalanceAdapter.sol";
import {
    ConvexCurveLPStakingMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/ConvexCurveLPStakingMetaBalanceAdapter.sol";
import {EulerVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/EulerVaultsMetaBalanceAdapter.sol";
import {
    SymbioticVaultsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/SymbioticVaultsMetaBalanceAdapter.sol";
import {YoVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/YoVaultsMetaBalanceAdapter.sol";
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

/// @dev Fluid's constructor probes `getVaultType(address(0))` and requires a >=32-byte answer
///      (`FluidVaultLib.supportsVaultType`, added by #161), so a bare CodeStub is not enough here.
contract FluidVaultResolverStub {
    function getVaultType(address) external pure returns (uint256) {
        return 0;
    }
}

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
///        1. **Hardcoded names** (14 adapters) — a string literal in the adapter, so the name is in the bytecode.
///           Every one is deployed here and pinned to its `ProtocolNames` constant
///           (`test_hardcodedAdapters_matchCanonicalNames`). That is what makes "use the constant, not a literal" a
///           checked rule rather than an aspiration: a literal that drifts from its constant fails here even for
///           single-member protocols, which no group comparison would catch.
///
///        2. **Meta adapters** (22) — `MetaBalanceAdapter.protocolName()` returns
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
    ///      author also adds it to `test_everyMetaAdapterReportsItsProtocolName`.
    uint256 internal constant META_ADAPTER_COUNT = 42;

    /// @dev Number of concrete plain + assisted adapters, i.e. the family whose name is a bytecode LITERAL rather
    ///      than derived. Pinned so adding one fails `test_hardcodedAdapterCensus` until the author also adds it to
    ///      `test_hardcodedAdapters_matchCanonicalNames`. This family is where the Umbrella bug actually happened,
    ///      and deriving the name fixed only the meta family — so without this census the exact defect this file
    ///      exists to prevent stays re-introducible here.
    ///
    ///      12 -> **13** when the combined `CapBalanceAdapter` was split into `CapStablecoinBalanceAdapter` +
    ///      `CapSavingsBalanceAdapter`: two contracts, one protocol, one `ProtocolNames.CAP`. That is exactly the
    ///      shape this census exists to make visible — a protocol gaining a second adapter is the moment a phantom
    ///      sibling can appear — so both are asserted in {test_hardcodedAdapters_matchCanonicalNames} above.
    ///      `CapBalanceAdapterBase` is abstract and is not counted (the census walks `out/` for deployable artifacts).
    ///      13 -> **14** when `MerklRewardsAttestedBalanceAdapter` (attested family) was added.
    uint256 internal constant HARDCODED_ADAPTER_COUNT = 14;

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
    /// @dev Covers all 14, including the single-member protocols (Kelp, Lido, Spark, Ethena, Stader, ether.fi,
    ///      Nexus Mutual, Merkl, Wallet) that no shared-protocol-id comparison can reach. Cap is no longer single-member:
    ///      its two leg adapters share `ProtocolNames.CAP` and both are asserted below. Deploying each adapter — rather
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
        // BOTH Cap leg adapters, deliberately. They are two contracts serving one protocol, which is exactly the
        // shape this test exists to police: if the split had given them different display names, a consumer
        // enumerating configured adapters would see Cap as two peer protocols — the phantom-sibling split.
        assertEq(
            new CapStablecoinBalanceAdapter(stub, stub, address(nav)).protocolName(), ProtocolNames.CAP, "CapStablecoin"
        );
        assertEq(
            new CapSavingsBalanceAdapter(stub, stub, stub, address(nav)).protocolName(), ProtocolNames.CAP, "CapSavings"
        );
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
            new EtherFiWithdrawalQueueAssistedBalanceAdapter(stub, stub, stub, address(nav), address(this))
                .protocolName(),
            ProtocolNames.ETHERFI,
            "ether.fi"
        );
        assertEq(
            new NexusMutualStakingPoolsAssistedBalanceAdapter(stub, stub, stub, address(nav), address(this))
                .protocolName(),
            ProtocolNames.NEXUS_MUTUAL,
            "Nexus Mutual"
        );
        assertEq(
            new StakeWiseV3ExitQueueAssistedBalanceAdapter(stub, stub, "osETH", address(nav), 1 days, address(this))
                .protocolName(),
            ProtocolNames.STAKEWISE_V3,
            "StakeWiseV3ExitQueue"
        );
        assertEq(
            new ERC20DefaultBalanceAdapter(address(nav), new address[](0)).protocolName(),
            ProtocolNames.WALLET,
            "ERC20Default"
        );
        assertEq(
            new MerklRewardsAttestedBalanceAdapter(stub, address(nav), address(this)).protocolName(),
            ProtocolNames.MERKL,
            "MerklRewards"
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
        string memory exitQueue = new StakeWiseV3ExitQueueAssistedBalanceAdapter(
                stub, stub, "osETH", address(nav), 1 days, address(this)
            ).protocolName();
        string memory vaults = new StakeWiseV3VaultsMetaBalanceAdapter(stub, stub, address(nav)).protocolName();

        assertEq(exitQueue, vaults, "exit queue and vaults share stakewise-v3 but disagree");
        assertEq(exitQueue, ProtocolNames.STAKEWISE_V3, "stakewise-v3 group must report the canonical name");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // Half 2 — meta adapters: the name is DERIVED, so the invariant is structural
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice EVERY meta adapter must report exactly the display name its own protocol maps to — asserted by
    ///         deploying all of them and calling `protocolName()`, not against a hand-written list of protocol ids.
    /// @dev `MetaBalanceAdapter.protocolName()` is `ProtocolNames.forProtocolId(_protocolId())`, so sibling
    ///      agreement is structural and needs no assertion. Two things are NOT structural.
    ///
    ///      *Totality*: a new meta adapter whose `_protocolId()` has no `forProtocolId` branch compiles, passes
    ///      its own tests (they never call `protocolName()`), and ships — adapters are immutable, plain CREATE —
    ///      after which every verbose read returns `protocolName == ""` for it, because the revert is swallowed by
    ///      NAVCalculator's fail-open `_safeString`. Calling `protocolName()` on a real instance is the only
    ///      assertion that catches that, and `test_metaAdapterCensus` below stops a new adapter from silently
    ///      escaping this list.
    ///
    ///      *Correct pairing*: deriving the name makes siblings agree, but it does NOT make the derived name
    ///      right. An adapter that copy-pastes a sibling's `_protocolId()` resolves to a real, non-empty, WRONG
    ///      name, so asserting non-emptiness alone would report green while the adapter mis-groups every verbose
    ///      read under another protocol — the same class of defect as the Umbrella bug this file exists to
    ///      prevent, just in the opposite direction (merging rather than splitting). Hence each adapter is paired
    ///      with its EXPECTED constant via `_expectName`, not merely checked for a non-empty string.
    function test_everyMetaAdapterReportsItsProtocolName() public {
        address n = address(nav);
        uint256 i;
        i += _expectName(
            new AaveV3InstancesMetaBalanceAdapter(n).protocolName(), ProtocolNames.AAVE_V3, "AaveV3Instances"
        );
        i += _expectName(new AaveV4SpokesMetaBalanceAdapter(n).protocolName(), ProtocolNames.AAVE_V4, "AaveV4Spokes");
        i += _expectName(
            new CompoundV3CometsMetaBalanceAdapter(stub, stub, n).protocolName(),
            ProtocolNames.COMPOUND_V3,
            "CompoundV3Comets"
        );
        i += _expectName(
            new ConvexCurveLPStakingMetaBalanceAdapter(stub, stub, n).protocolName(),
            ProtocolNames.CONVEX,
            "ConvexCurveLPStaking"
        );
        i += _expectName(new EulerVaultsMetaBalanceAdapter(n).protocolName(), ProtocolNames.EULER, "EulerVaults");
        i += _expectName(
            new SymbioticVaultsMetaBalanceAdapter(n).protocolName(), ProtocolNames.SYMBIOTIC, "SymbioticVaults"
        );
        i += _expectName(new YoVaultsMetaBalanceAdapter(n).protocolName(), ProtocolNames.YO, "YoVaults");
        i += _expectName(new FluidFTokensMetaBalanceAdapter(n).protocolName(), ProtocolNames.FLUID, "FluidFTokens");
        i += _expectName(
            new FluidVaultsMetaBalanceAdapter(address(new FluidVaultResolverStub()), n).protocolName(),
            ProtocolNames.FLUID,
            "FluidVaults"
        );
        i += _expectName(
            new GearboxV3CreditAccountsMetaBalanceAdapter(n).protocolName(),
            ProtocolNames.GEARBOX_V3,
            "GearboxV3CreditAccounts"
        );
        i += _expectName(
            new GearboxV3MarketsMetaBalanceAdapter(n).protocolName(), ProtocolNames.GEARBOX_V3, "GearboxV3Markets"
        );
        i += _expectName(
            new MorphoMarketsMetaBalanceAdapter(stub, n).protocolName(), ProtocolNames.MORPHO, "MorphoMarkets"
        );
        i += _expectName(new MorphoVaultsMetaBalanceAdapter(n).protocolName(), ProtocolNames.MORPHO, "MorphoVaults");
        i += _expectName(
            new StakeWiseV3VaultsMetaBalanceAdapter(stub, stub, n).protocolName(),
            ProtocolNames.STAKEWISE_V3,
            "StakeWiseV3Vaults"
        );
        i += _expectName(
            new PolygonStakingMetaBalanceAdapter(stub, n).protocolName(), ProtocolNames.POLYGON, "PolygonStaking"
        );
        i += _expectName(
            new BalancerV2GaugesMetaBalanceAdapter(stub, stub, n).protocolName(),
            ProtocolNames.BALANCER_V2,
            "BalancerV2Gauges"
        );
        i += _expectName(
            new BalancerV2PoolsMetaBalanceAdapter(stub, n).protocolName(), ProtocolNames.BALANCER_V2, "BalancerV2Pools"
        );
        i += _expectName(
            new BalancerV3GaugesMetaBalanceAdapter(stub, n).protocolName(),
            ProtocolNames.BALANCER_V3,
            "BalancerV3Gauges"
        );
        i += _expectName(
            new BalancerV3PoolsMetaBalanceAdapter(n).protocolName(), ProtocolNames.BALANCER_V3, "BalancerV3Pools"
        );
        i += _expectName(
            new CurveGaugesMetaBalanceAdapter(stub, stub, n).protocolName(), ProtocolNames.CURVE, "CurveGauges"
        );
        i += _expectName(new CurvePoolsMetaBalanceAdapter(n).protocolName(), ProtocolNames.CURVE, "CurvePools");
        i += _expectName(
            new PancakeSwapV2PoolsMetaBalanceAdapter(n).protocolName(),
            ProtocolNames.PANCAKESWAP_V2,
            "PancakeSwapV2Pools"
        );
        i += _expectName(
            new PancakeSwapV3PoolsMetaBalanceAdapter(stub, n).protocolName(),
            ProtocolNames.PANCAKESWAP_V3,
            "PancakeSwapV3Pools"
        );
        i += _expectName(
            new UniswapV2PoolsMetaBalanceAdapter(n).protocolName(), ProtocolNames.UNISWAP_V2, "UniswapV2Pools"
        );
        i += _expectName(
            new UniswapV3PoolsMetaBalanceAdapter(stub, n).protocolName(), ProtocolNames.UNISWAP_V3, "UniswapV3Pools"
        );

        // Wallet-held yield-token family: `protocolName()` derives from `_protocolId()` via forProtocolId —
        // NOT from `_protocolBrand()`, which differs from the id for adapters like StakeWise V3 and Aave V3.
        // A missing ProtocolNames branch would revert UnknownProtocolId rather than return an empty string.
        i += _expectName(
            new LidoStakedEthWalletMetaBalanceAdapter(n).protocolName(), ProtocolNames.LIDO, "LidoStakedEthWall"
        );
        i += _expectName(
            new EtherFiStakedEthWalletMetaBalanceAdapter(n).protocolName(),
            ProtocolNames.ETHERFI,
            "EtherFiStakedEthWall"
        );
        i += _expectName(
            new RocketPoolStakedEthWalletMetaBalanceAdapter(n).protocolName(),
            ProtocolNames.ROCKET_POOL,
            "RocketPoolStakedEthWall"
        );
        i += _expectName(
            new RenzoRestakedEthWalletMetaBalanceAdapter(n).protocolName(), ProtocolNames.RENZO, "RenzoRestakedEthWall"
        );
        i += _expectName(
            new KelpRestakedEthWalletMetaBalanceAdapter(n).protocolName(), ProtocolNames.KELP, "KelpRestakedEthWall"
        );
        i += _expectName(
            new StaderStakedEthWalletMetaBalanceAdapter(n).protocolName(), ProtocolNames.STADER, "StaderStakedEthWall"
        );
        i += _expectName(
            new StakeWiseV3OsTokenWalletMetaBalanceAdapter(n).protocolName(),
            ProtocolNames.STAKEWISE_V3,
            "StakeWiseV3OsTokenWall"
        );
        i += _expectName(
            new LiquidCollectiveStakedEthWalletMetaBalanceAdapter(n).protocolName(),
            ProtocolNames.LIQUID_COLLECTIVE,
            "LiquidCollectiveStakedEthWall"
        );
        i += _expectName(
            new AnkrStakedEthWalletMetaBalanceAdapter(n).protocolName(), ProtocolNames.ANKR, "AnkrStakedEthWall"
        );
        i += _expectName(
            new CoinbaseStakedEthWalletMetaBalanceAdapter(n).protocolName(),
            ProtocolNames.COINBASE,
            "CoinbaseStakedEthWall"
        );
        i += _expectName(
            new ReserveBasketsWalletMetaBalanceAdapter(n).protocolName(), ProtocolNames.RESERVE, "ReserveBasketsWall"
        );
        i += _expectName(
            new EthenaSavingsWalletMetaBalanceAdapter(n).protocolName(), ProtocolNames.ETHENA, "EthenaSavingsWall"
        );
        i += _expectName(new SkySavingsWalletMetaBalanceAdapter(n).protocolName(), ProtocolNames.SKY, "SkySavingsWall");
        i += _expectName(
            new AaveSavingsWalletMetaBalanceAdapter(n).protocolName(), ProtocolNames.AAVE_V3, "AaveSavingsWall"
        );
        i += _expectName(
            new SparkSavingsWalletMetaBalanceAdapter(n).protocolName(), ProtocolNames.SPARK, "SparkSavingsWall"
        );
        i += _expectName(
            new MapleSavingsWalletMetaBalanceAdapter(n).protocolName(), ProtocolNames.MAPLE, "MapleSavingsWall"
        );
        i += _expectName(
            new NexusMutualVaultsWalletMetaBalanceAdapter(n).protocolName(),
            ProtocolNames.NEXUS_MUTUAL,
            "NexusMutualVaultsWall"
        );
        assertEq(i, META_ADAPTER_COUNT, "exercised count must equal META_ADAPTER_COUNT");
    }

    /// @dev Asserts one adapter reports exactly the name its `_protocolId()` should map to, and returns 1 so the
    ///      caller can count what it exercised. Pairing each adapter with its EXPECTED name — rather than merely
    ///      asserting the name is non-empty — is what makes a wrong `_protocolId()` fail: a new adapter that
    ///      copy-pastes a sibling's id still yields a plausible non-empty name (e.g. "Fluid" for a Pendle
    ///      adapter), which a non-emptiness check passes and which then ships immutably and mis-groups every
    ///      verbose read. It is also the only guard on the thin-subclass adapters whose identity comes from
    ///      overriding a parent (`PancakeSwapV2Pools` over `UniswapV2Pools`, which has no test of its own): drop
    ///      the override and the name reverts to the parent's, which this catches.
    function _expectName(string memory actual, string memory expected, string memory who)
        internal
        pure
        returns (uint256)
    {
        assertEq(actual, expected, string.concat(who, " must report its own protocol's name"));
        return 1;
    }

    /// @notice A new meta adapter must not be able to slip past the test above unnoticed.
    /// @dev Counts the concrete meta-adapter compilation artifacts and requires the number to equal the number this
    ///      file actually deploys. Adding an adapter therefore fails here until it is added to
    ///      `test_everyMetaAdapterReportsItsProtocolName` — at which point that test catches both a missing
    ///      `forProtocolId` branch and a wrong `_protocolId()`. Without this census the coverage list is a
    ///      hand-maintained snapshot that silently rots.
    ///
    ///      Counts CONTRACTS, not source files. Each `out/<file>.sol/` directory holds one JSON per contract
    ///      declared in that file, so counting directories would miss a meta adapter declared as a SECOND contract
    ///      inside an existing file — exactly the thin-subclass shape `PancakeSwapV2Pools` already uses over
    ///      `UniswapV2Pools`. Such an adapter would escape both this census and the name test while compiling and
    ///      deploying perfectly well.
    ///
    ///      Counts `out/` rather than `src/`: `fs_permissions` grants read on `out` but not `src`, and adding a
    ///      permission would mean editing `foundry.toml`, which is off-limits while the library pin is being
    ///      coordinated across parallel branches. The trade-off is that this is a function of BUILD state, not
    ///      source state, so it over-counts on a stale artifact from a deleted adapter or on any non-production
    ///      source (a test mock, a script) whose contract name ends in `MetaBalanceAdapter`. Both are loud
    ///      failures, never silent passes — hence the message below names them, since the obvious reading of a
    ///      red census ("register the new adapter") is the wrong fix in those cases. CI always builds fresh.
    function test_metaAdapterCensus() public view {
        uint256 found = _countMetaAdapterContracts("out");
        assertEq(
            found,
            META_ADAPTER_COUNT,
            "meta-adapter contract count changed: if you added one, add it to test_everyMetaAdapterReportsItsProtocolName and bump META_ADAPTER_COUNT; if you did not, suspect a stale out/ artifact (forge clean) or a non-production contract named *MetaBalanceAdapter"
        );
    }

    /// @notice A new plain or assisted adapter must not be able to slip past `test_hardcodedAdapters_matchCanonicalNames`.
    /// @dev The mirror of `test_metaAdapterCensus` for the family whose display name is a hardcoded literal. That
    ///      test asserts only the names it explicitly lists, so it cannot notice a NEW adapter — and a
    ///      hardcoded name is exactly what went wrong with Umbrella ("Aave Umbrella" for `ProtocolIds.AAVE_V3`).
    ///      Deriving the name closed that hole for meta adapters only; this census closes the reporting gap for the
    ///      family that still writes the string by hand, so a new adapter naming a PRODUCT, or naming a protocol
    ///      absent from `ProtocolNames` altogether, fails here until it is asserted above.
    ///
    ///      Same build-state caveat as the meta census — see `test_metaAdapterCensus` for why `out/` and not `src/`.
    function test_hardcodedAdapterCensus() public view {
        uint256 found = _countHardcodedAdapterContracts("out");
        assertEq(
            found,
            HARDCODED_ADAPTER_COUNT,
            "plain/assisted adapter contract count changed: if you added one, add it to test_hardcodedAdapters_matchCanonicalNames and bump HARDCODED_ADAPTER_COUNT; if you did not, suspect a stale out/ artifact (forge clean) or a non-production contract named *BalanceAdapter"
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

    /// @dev Counts concrete meta-adapter CONTRACT artifacts, excluding the abstract base and the interface. Walks
    ///      one level into each `out/<file>.sol/` directory so a contract declared alongside another in the same
    ///      file is counted too; `vm.readDir` is non-recursive, and every artifact sits exactly one level down.
    function _countMetaAdapterContracts(string memory relDir) internal view returns (uint256 count) {
        Vm.DirEntry[] memory dirs = vm.readDir(string.concat(vm.projectRoot(), "/", relDir));
        for (uint256 i = 0; i < dirs.length; i++) {
            // Filter on the DIRECTORY name, not just the artifact name: `out/` has one directory per *source file*,
            // including test files, and mocks named `*BalanceAdapter` live inside `out/<something>.t.sol/`. A
            // production adapter always occupies a file named after itself, so requiring the directory to match too
            // excludes test/mock artifacts while still descending into the adapter's own file.
            if (!_endsWith(dirs[i].path, "MetaBalanceAdapter.sol")) continue;
            Vm.DirEntry[] memory artifacts = vm.readDir(dirs[i].path);
            for (uint256 j = 0; j < artifacts.length; j++) {
                if (!_endsWith(artifacts[j].path, "MetaBalanceAdapter.json")) continue;
                if (!_isLiveConcreteArtifact(artifacts[j].path)) continue; // interface, abstract base, or stale
                count++;
            }
        }
    }

    /// @dev Counts concrete plain + assisted adapter CONTRACT artifacts — everything whose name ends in
    ///      `BalanceAdapter` but NOT in `MetaBalanceAdapter` — excluding the three interfaces (`IBalanceAdapter`,
    ///      `IAssistedBalanceAdapter`, `IAttestedBalanceAdapter`). `AssistedCoordCache` is naturally excluded by the
    ///      name rule, as is the `MetaBalanceAdapter` base.
    function _countHardcodedAdapterContracts(string memory relDir) internal view returns (uint256 count) {
        Vm.DirEntry[] memory dirs = vm.readDir(string.concat(vm.projectRoot(), "/", relDir));
        for (uint256 i = 0; i < dirs.length; i++) {
            // Same directory-name filter as the meta census, and load-bearing here rather than merely tidy: this
            // family's suffix (`BalanceAdapter`) is shared by numerous test mocks (`Mock_ManyLegsBalanceAdapter`
            // and friends), so counting artifacts across all of `out/` over-counts by however many mocks exist.
            if (!_endsWith(dirs[i].path, "BalanceAdapter.sol")) continue;
            if (_endsWith(dirs[i].path, "MetaBalanceAdapter.sol")) continue; // the meta family, counted above
            Vm.DirEntry[] memory artifacts = vm.readDir(dirs[i].path);
            for (uint256 j = 0; j < artifacts.length; j++) {
                if (!_endsWith(artifacts[j].path, "BalanceAdapter.json")) continue;
                if (_endsWith(artifacts[j].path, "MetaBalanceAdapter.json")) continue; // the meta family
                if (!_isLiveConcreteArtifact(artifacts[j].path)) continue; // interface, abstract base, or stale
                count++;
            }
        }
    }

    /// @dev True when `artifactPath` is a CONCRETE contract that is still part of the tree. Two independent
    ///      checks, because the census has two distinct ways of over-counting and neither subsumes the other.
    /// @dev **1. Kind, not spelling.** Interfaces and abstract contracts have no creation bytecode, so an empty
    ///      `bytecode.object` identifies them by what they ARE. This replaces the hand-maintained
    ///      `/IBalanceAdapter.json` / `/IAssistedBalanceAdapter.json` / `/IMetaBalanceAdapter.json` /
    ///      `/MetaBalanceAdapter.json` exclusions, which were a filename rule: every future interface, marker
    ///      interface or abstract base is handled without editing this list, and a stale artifact of a DELETED
    ///      interface or base — which no such list could name in advance — is handled too.
    /// @dev **2. The source must still exist.** The artifact records the file it was compiled from, and a stale
    ///      artifact's file is gone. This is the case that actually broke `main`: the artifact directory `out/` is
    ///      restored in CI from a cache keyed on the repository alone, with no tree or lockfile component, so it
    ///      accumulates artifacts of adapters deleted long ago and `forge build` never prunes them. Every deleted
    ///      `*BalanceAdapter.sol` in this repo's history is a latent +1 on a census that only reads `out/`.
    /// @dev Fails LOUD, not silent: if the artifact does not record a source path, it is COUNTED rather than
    ///      skipped, so an unrecognised artifact shape trips the census instead of quietly shrinking it. The
    ///      whole point of this test is that an unexplained count is a signal.
    function _isLiveConcreteArtifact(string memory artifactPath) internal view returns (bool) {
        string memory json = vm.readFile(artifactPath);
        if (bytes(vm.parseJsonString(json, ".bytecode.object")).length <= 2) return false; // "0x" or empty
        if (!vm.keyExists(json, ".ast.absolutePath")) return true; // undeterminable: count it, do not hide it
        string memory sourcePath = vm.parseJsonString(json, ".ast.absolutePath");
        // `vm.exists` REVERTS — it does not return false — on a path outside `fs_permissions`, and
        // only `src`, `script`, `lib`, `out`, `safe-transactions` and `test/integration` are
        // granted. The premise of this filter is an `out/` carrying artifacts from arbitrary other
        // branches, so a branch with a matching source under, say, `test/mocks/` would blow up the
        // census with an fs-permission revert instead of its own message. A production adapter
        // always lives under `src/`, so anything else is foreign by construction: filter it rather
        // than probing the filesystem for it.
        if (!_startsWith(sourcePath, "src/")) return false;
        return vm.exists(string.concat(vm.projectRoot(), "/", sourcePath));
    }

    function _startsWith(string memory value, string memory prefix) internal pure returns (bool) {
        bytes memory v = bytes(value);
        bytes memory pfx = bytes(prefix);
        if (v.length < pfx.length) return false;
        for (uint256 i = 0; i < pfx.length; i++) {
            if (v[i] != pfx[i]) return false;
        }
        return true;
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
    /// @dev **Known limitation — this list is hand-maintained.** It covers all 26 `ProtocolNames` constants today,
    ///      but nothing forces it to stay complete: adding a constant without adding it here passes silently, so a
    ///      duplicate introduced by copy-pasting a neighbour (say `AAVE_V4 = "Aave V3"`) would never be compared
    ///      against anything and this test would report green on exactly the collision it exists to find. There is
    ///      no fix available in-repo right now: Solidity cannot enumerate a library's constants, the artifact holds
    ///      no entry for an `internal constant`, and counting the source would need `fs_permissions` read on `src/`
    ///      — i.e. editing `foundry.toml`, which is off-limits while the library pins are being coordinated. A
    ///      `PROTOCOL_NAME_COUNT` pinned to the array's own length would be a tautology, not a guard. So: when you
    ///      add a `ProtocolNames` constant, add it to this array by hand. Revisit once `foundry.toml` is free.
    function test_distinctProtocolsHaveDistinctNames() public pure {
        string[26] memory names = [
            ProtocolNames.WALLET,
            ProtocolNames.AAVE_V3,
            ProtocolNames.SPARK,
            ProtocolNames.MORPHO,
            ProtocolNames.EULER,
            ProtocolNames.SYMBIOTIC,
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
            ProtocolNames.NEXUS_MUTUAL,
            ProtocolNames.MERKL
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
