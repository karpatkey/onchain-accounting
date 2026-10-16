// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {IPositionEnumerable} from "src/balances/IPositionEnumerable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";

// The whole meta family, for the cross-adapter advertised-shape census below. Constructor argument lists are
// copied 1:1 from `test_everyMetaAdapterReportsItsProtocolName`; the stubs are reused from that same file.
import {CodeStub, FluidVaultResolverStub, SparkDataProviderStub} from "test/ProtocolNameConsistency.t.sol";

// The wallet-held yield-token family (ADR: yield tokens as protocol positions). All take (navCalculator) and
// all inherit the base `_instancePositionId`, so every one of them belongs in the address-keyed default group.
import {
    AaveSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/AaveSavingsWalletMetaBalanceAdapter.sol";
import {
    AnkrStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/AnkrStakedEthWalletMetaBalanceAdapter.sol";
import {
    CoinbaseStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/CoinbaseStakedEthWalletMetaBalanceAdapter.sol";
import {
    EthenaSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/EthenaSavingsWalletMetaBalanceAdapter.sol";
import {
    EtherFiStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/EtherFiStakedEthWalletMetaBalanceAdapter.sol";
import {
    KelpRestakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/KelpRestakedEthWalletMetaBalanceAdapter.sol";
import {
    LidoStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/LidoStakedEthWalletMetaBalanceAdapter.sol";
import {
    LiquidCollectiveStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/LiquidCollectiveStakedEthWalletMetaBalanceAdapter.sol";
import {
    MapleSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/MapleSavingsWalletMetaBalanceAdapter.sol";
import {
    NexusMutualVaultsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/NexusMutualVaultsWalletMetaBalanceAdapter.sol";
import {
    RenzoRestakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/RenzoRestakedEthWalletMetaBalanceAdapter.sol";
import {
    ReserveBasketsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/ReserveBasketsWalletMetaBalanceAdapter.sol";
import {
    RocketPoolStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/RocketPoolStakedEthWalletMetaBalanceAdapter.sol";
import {
    SkySavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/SkySavingsWalletMetaBalanceAdapter.sol";
import {
    SparkSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/SparkSavingsWalletMetaBalanceAdapter.sol";
import {
    StaderStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/StaderStakedEthWalletMetaBalanceAdapter.sol";
import {
    StakeWiseV3OsTokenWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/StakeWiseV3OsTokenWalletMetaBalanceAdapter.sol";
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
import {
    UniswapV3SicklePoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/vfat/UniswapV3SicklePoolsMetaBalanceAdapter.sol";
import {
    UniswapV4SicklePoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/vfat/UniswapV4SicklePoolsMetaBalanceAdapter.sol";
import {
    FablesSickleRangesMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/vfat/FablesSickleRangesMetaBalanceAdapter.sol";
import {MockSickleFactory, MockSickle} from "test/balances/MetaBalanceAdapters/vfat/SickleMocks.sol";

// Protocol mocks for the emitted-side join, reused from each adapter's own suite rather than re-written.
import {TickMath} from "src/balances/MetaBalanceAdapters/uniswap/lib/TickMath.sol";
import {
    MockUniswapV3Pool,
    MockPositionManager,
    MockToken
} from "test/balances/MetaBalanceAdapters/uniswap/UniswapV3Mocks.sol";
import {
    MockAavePool,
    MockAaveAddressesProvider,
    MockAaveDataProvider
} from "test/balances/MetaBalanceAdapters/AaveV3InstancesMetaBalanceAdapter.t.sol";
import {
    MockGearboxToken,
    MockCreditAccount,
    MockCreditManager
} from "test/balances/MetaBalanceAdapters/GearboxV3CreditAccountsMetaBalanceAdapter.t.sol";
import {
    MockPancakeV3Pool
} from "test/balances/MetaBalanceAdapters/pancakeswap/PancakeSwapV3PoolsMetaBalanceAdapter.t.sol";

/// @dev Minimal address-keyed meta adapter: leaves `_instancePositionId` on the base default and routes its
///      emitted positionId through the same hook, which is the contract every meta adapter owes
///      {IPositionEnumerable}. Stands in for the ~19 adapters that key positions on the coordinate itself.
contract HookAbidingMeta is MetaBalanceAdapter {
    constructor(address nav) MetaBalanceAdapter(nav) {}

    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.AAVE;
    }

    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.AAVE_V3;
    }

    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.AAVE_V3_LENDING;
    }

    function positionLabels(bytes calldata) external pure override returns (string[] memory) {
        return _labels("Market", "mock");
    }

    function _instanceAssets(bytes32) internal pure override returns (address[] memory) {
        return new address[](0);
    }

    function _instancePositions(address, bytes32 instance, address)
        internal
        view
        virtual
        override
        returns (INAVCalculator.PositionBalance[] memory out)
    {
        (INAVCalculator.Asset memory asset, bool found) = _getAssetInfo(_asset);
        if (!found) return new INAVCalculator.PositionBalance[](0);
        out = new INAVCalculator.PositionBalance[](1);
        out[0] = _leg(asset, 1e18, false, _instancePositionId(instance), PositionKind.Supplied);
    }

    address internal _asset;

    function setAsset(address a) external {
        _asset = a;
    }
}

/// @dev The failure mode {IPositionEnumerable} exists to catch, reproduced deliberately: this adapter derives its
///      emitted positionId from the coordinate (here: +1) while leaving `_instancePositionId` on the default, so
///      the enumeration advertises ids that no position ever carries. This is the shape Aave V3 sat in before its
///      override. Used only to prove the join assertion below actually detects it.
contract HookViolatingMeta is HookAbidingMeta {
    constructor(address nav) HookAbidingMeta(nav) {}

    function _instancePositions(address, bytes32 instance, address)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory out)
    {
        (INAVCalculator.Asset memory asset, bool found) = _getAssetInfo(_asset);
        if (!found) return new INAVCalculator.PositionBalance[](0);
        out = new INAVCalculator.PositionBalance[](1);
        // Derived, NOT the hook — the silent break.
        address derived = address(uint160(uint256(instance)) + 1);
        out[0] = _leg(asset, 1e18, false, abi.encode(derived), PositionKind.Supplied);
    }
}

/// @dev Shared assertions for the three suites below. Extracted so the cross-adapter suites can reuse the exact
///      membership rule the base suite proves out, rather than each hand-rolling a comparison — hand-copied
///      assertions drifting apart is the failure this file exists to prevent.
abstract contract PositionIdJoinAsserts is Test {
    /// @dev Set membership over `bytes`, compared by hash — the join {IPositionEnumerable} specifies. Ordering is
    ///      disclaimed by the interface, so never compare index-wise.
    function _contains(bytes[] memory haystack, bytes memory needle) internal pure returns (bool) {
        for (uint256 i; i < haystack.length; ++i) {
            if (keccak256(haystack[i]) == keccak256(needle)) return true;
        }
        return false;
    }

    /// @dev A one-element governed set.
    function _one(bytes32 coord) internal pure returns (bytes32[] memory out) {
        out = new bytes32[](1);
        out[0] = coord;
    }

    /// @dev Configures `coord` as `a`'s sole governed instance and asserts the ADVERTISED shape is exactly
    ///      `expected`. Returns 1 so the caller can count what it exercised (the `_expectName` pattern from
    ///      {ProtocolNameConsistencyTest}).
    ///
    ///      The length assertion is the anti-vacuity guard and is not decoration: `positionIds()` DROPS a
    ///      coordinate whose hook reverts, so an adapter that cannot resolve its coordinate answers `[]` and every
    ///      value assertion below would pass over an empty array.
    function _assertAdvertisedId(
        Mock_NAVCalculator nav_,
        MetaBalanceAdapter a,
        bytes32 coord,
        bytes memory expected,
        string memory who
    ) internal returns (uint256) {
        nav_.setMetaInstances(address(a), _one(coord));
        bytes[] memory ids = a.positionIds();
        assertEq(ids.length, 1, string.concat(who, ": the one configured coordinate must advertise a shape"));
        assertEq(
            keccak256(ids[0]),
            keccak256(expected),
            string.concat(who, ": advertised positionId bytes must match the declared shape")
        );
        return 1;
    }

    /// @dev The byte-identity join, driven ONE coordinate at a time so set membership degenerates to exact
    ///      equality against that coordinate's own advertised id — strictly stronger than `emitted in ids`, and it
    ///      never depends on ordering. Returns the number of legs seen so the caller can pin the exact count.
    function _assertJoin(MetaBalanceAdapter a, address account, bytes32[] memory coords, string memory who)
        internal
        view
        returns (uint256 legsSeen)
    {
        bytes[] memory ids = a.positionIds();
        assertEq(ids.length, coords.length, string.concat(who, ": every configured coordinate must advertise"));

        for (uint256 i; i < coords.length; ++i) {
            // The hook's answer for this coordinate IS the advertised shape: `positionIds()` is literally
            // `instancePositionId` mapped over the governed set, and the length assertion above already proved
            // nothing was dropped. So no `_contains(ids, expected)` check here — it could never fail, and asserting
            // it would imply the advertised side is independently verified in this suite when that is Half A's job.
            bytes memory expected = a.instancePositionId(coords[i]);

            INAVCalculator.PositionBalance[] memory pos =
                a.getAdapterPositionsForInstances(account, _one(coords[i]), address(0));
            for (uint256 j; j < pos.length; ++j) {
                assertEq(
                    keccak256(pos[j].positionId),
                    keccak256(expected),
                    string.concat(who, ": emitted positionId must be byte-identical to the advertised shape")
                );
            }
            legsSeen += pos.length;
        }

        // Asserted INSIDE the helper so no call site can forget it. Most adapters early-return an empty array when
        // the underlying is unregistered or the balance is zero, which would make the loop above assert nothing.
        assertGt(legsSeen, 0, string.concat(who, ": no legs emitted -- this join asserts nothing, fix the wiring"));
    }
}

/// @title MetaBalanceAdapterEnumerationTest
/// @author KPK
/// @notice Covers {IPositionEnumerable} as implemented once on {MetaBalanceAdapter} for the whole meta family.
contract MetaBalanceAdapterEnumerationTest is PositionIdJoinAsserts {
    Mock_NAVCalculator internal nav;
    HookAbidingMeta internal adapter;
    Mock_ERC20 internal token;

    address internal constant INSTANCE_A = address(0xA11CE);
    address internal constant INSTANCE_B = address(0xB0B);

    function setUp() public {
        nav = new Mock_NAVCalculator();
        adapter = new HookAbidingMeta(address(nav));
        token = new Mock_ERC20("MCK", 18);
        nav.registerAssetFromERC20(address(token));
        adapter.setAsset(address(token));
    }

    function _instances(address a, address b) internal pure returns (bytes32[] memory out) {
        out = new bytes32[](2);
        out[0] = bytes32(uint256(uint160(a)));
        out[1] = bytes32(uint256(uint160(b)));
    }

    // ============================================
    // ERC-165
    // ============================================

    /// @dev The bit a configuration view gates on. Contributed by the base, so every meta adapter gets it.
    function test_supportsInterface_advertisesPositionEnumerable() public view {
        assertTrue(adapter.supportsInterface(type(IPositionEnumerable).interfaceId));
    }

    /// @dev Widening the base to `public` and adding a fifth id must not disturb the ids the registry routes on:
    ///      `NAVRegistryLib` keys the meta path off `IMetaBalanceAdapter`, and `Balances` requires
    ///      `IBalanceAdapter`. A regression here mis-routes or rejects every meta adapter at registration.
    function test_supportsInterface_registrationIdsUnchanged() public view {
        assertTrue(adapter.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertFalse(adapter.supportsInterface(bytes4(0xdeadbeef)));
        assertFalse(adapter.supportsInterface(0xffffffff));
    }

    // ============================================
    // positionIds
    // ============================================

    /// @dev The shape set of a meta adapter IS its governed instance set, which lives on the NAVCalculator. With
    ///      none configured the adapter advertises nothing — the honest answer, not a failure.
    function test_positionIds_emptyWhenNoInstancesConfigured() public view {
        assertEq(adapter.positionIds().length, 0);
    }

    /// @dev One id per configured instance, mapped through `_instancePositionId`.
    function test_positionIds_enumeratesConfiguredInstances() public {
        nav.setMetaInstances(address(adapter), _instances(INSTANCE_A, INSTANCE_B));

        bytes[] memory ids = adapter.positionIds();
        assertEq(ids.length, 2);
        assertTrue(_contains(ids, abi.encode(INSTANCE_A)));
        assertTrue(_contains(ids, abi.encode(INSTANCE_B)));
    }

    /// @dev Enumeration tracks governance with no adapter state: removing an instance from the NAVCalculator
    ///      removes the row, and the adapter has no admin surface of its own.
    function test_positionIds_tracksTheGovernedSet() public {
        nav.setMetaInstances(address(adapter), _instances(INSTANCE_A, INSTANCE_B));
        assertEq(adapter.positionIds().length, 2);

        bytes32[] memory one = new bytes32[](1);
        one[0] = bytes32(uint256(uint160(INSTANCE_A)));
        nav.setMetaInstances(address(adapter), one);

        bytes[] memory ids = adapter.positionIds();
        assertEq(ids.length, 1);
        assertEq(ids[0], abi.encode(INSTANCE_A));
    }

    /// @dev **The byte-identity guarantee, at the base.** Every advertised id must be exactly what the adapter
    ///      emits as `PositionBalance.positionId` for that instance, or a configuration view cannot join its rows
    ///      against real positions.
    function test_positionIds_matchTheEmittedPositionIds() public {
        nav.setMetaInstances(address(adapter), _instances(INSTANCE_A, INSTANCE_B));

        bytes[] memory ids = adapter.positionIds();
        INAVCalculator.PositionBalance[] memory positions =
            adapter.getAdapterPositionsForInstances(address(this), _instances(INSTANCE_A, INSTANCE_B), address(0));

        assertEq(positions.length, 2, "both instances emit a leg");
        for (uint256 i; i < positions.length; ++i) {
            assertTrue(_contains(ids, positions[i].positionId), "emitted positionId must be an advertised shape");
        }
    }

    /// @dev **Proves the assertion above is load-bearing rather than tautological.** An adapter that derives its
    ///      positionId while leaving `_instancePositionId` on the default advertises ids no position carries —
    ///      the exact trap `AaveV3InstancesMetaBalanceAdapter` sat in, where the label came out right by
    ///      coincidence and only a byte comparison caught the broken join. The same check must FAIL for it.
    function test_positionIds_joinAssertionDetectsAHookViolation() public {
        HookViolatingMeta bad = new HookViolatingMeta(address(nav));
        bad.setAsset(address(token));
        nav.setMetaInstances(address(bad), _instances(INSTANCE_A, INSTANCE_B));

        bytes[] memory ids = bad.positionIds();
        INAVCalculator.PositionBalance[] memory positions =
            bad.getAdapterPositionsForInstances(address(this), _instances(INSTANCE_A, INSTANCE_B), address(0));

        assertEq(positions.length, 2, "the violating adapter still emits legs");
        // Without this, the assertFalse below would also hold for a completely different reason — an empty
        // advertised set — so the negative control would pass vacuously if `positionIds()` ever broke.
        assertEq(ids.length, 2, "and still advertises two shapes: the mismatch must be in CONTENT, not absence");
        // Every emitted id is ABSENT from the advertised set: the join silently returns nothing in production.
        for (uint256 i; i < positions.length; ++i) {
            assertFalse(_contains(ids, positions[i].positionId), "hook violation must be detectable by bytes");
        }
    }

    // ============================================
    // Per-instance revert isolation
    // ============================================

    /// @dev **{IPositionEnumerable} requires `positionIds()` not to revert, and deriving a positionId is not
    ///      inherently safe.** The base default reverts via `_toAddress` on a coordinate whose high bits are
    ///      dirty, and `addMetaInstances` never checks a coordinate is even a contract — so one mistyped
    ///      governance argument is enough. Without isolation that single bad coordinate would take down the
    ///      enumeration for every OTHER configured instance, and silently: through the consumer's fail-open
    ///      staticcall a reverting adapter is indistinguishable from one with nothing configured, which is the
    ///      exact ambiguity this interface exists to remove.
    ///
    ///      The good instance must still enumerate, and the bad one is dropped — under-report, never over-report.
    function test_positionIds_isolatesAMalformedCoordinate() public {
        bytes32[] memory mixed = new bytes32[](2);
        mixed[0] = bytes32(uint256(uint160(INSTANCE_A)));
        mixed[1] = bytes32(type(uint256).max); // dirty high bits -> `_toAddress` reverts

        nav.setMetaInstances(address(adapter), mixed);

        bytes[] memory ids = adapter.positionIds();
        assertEq(ids.length, 1, "the good instance survives the bad one");
        assertEq(ids[0], abi.encode(INSTANCE_A));
    }

    /// @dev The isolation is per instance, not "give up at the first failure": a bad coordinate BEFORE a good one
    ///      must not truncate the rest. Ordering out is compacted, which is why the interface disclaims order.
    function test_positionIds_isolationDoesNotTruncateLaterInstances() public {
        bytes32[] memory mixed = new bytes32[](3);
        mixed[0] = bytes32(type(uint256).max); // bad, first
        mixed[1] = bytes32(uint256(uint160(INSTANCE_A)));
        mixed[2] = bytes32(uint256(uint160(INSTANCE_B)));

        nav.setMetaInstances(address(adapter), mixed);

        bytes[] memory ids = adapter.positionIds();
        assertEq(ids.length, 2, "both good instances survive a leading bad one");
        assertTrue(_contains(ids, abi.encode(INSTANCE_A)));
        assertTrue(_contains(ids, abi.encode(INSTANCE_B)));
    }

    /// @dev Every coordinate malformed => empty, not a revert. Empty is a valid answer per the interface.
    function test_positionIds_allCoordinatesBad_returnsEmptyWithoutReverting() public {
        bytes32[] memory bad = new bytes32[](2);
        bad[0] = bytes32(type(uint256).max);
        bad[1] = bytes32(uint256(1) << 200);

        nav.setMetaInstances(address(adapter), bad);
        assertEq(adapter.positionIds().length, 0);
    }
}

/// @title MetaBalanceAdapterAdvertisedShapeTest
/// @author KPK
/// @notice **The cross-adapter tripwire.** Asserts, for every concrete meta adapter, what shape its
///         `positionIds()` advertises for a governed coordinate — the coordinate itself, unless the adapter
///         declares a derived id here.
/// @dev Why this is a SHAPE check and not the join, which is the non-obvious part:
///
///      The join (`emitted positionId in positionIds()`) cannot detect the regression this file most needs to
///      catch. `AaveV3InstancesMetaBalanceAdapter._instancePositions` derives its emitted id FROM the hook
///      (`bytes memory pid = _instancePositionId(instance)`), so deleting its `_instancePositionId` override moves
///      BOTH sides to `abi.encode(dataProvider)` in lockstep and the join still holds. Only pinning the VALUE —
///      "Aave must advertise the resolved Pool, and must NOT advertise its ProtocolDataProvider coordinate" —
///      fires on that mutation. The emitted-side join lives in {MetaBalanceAdapterEmittedJoinTest} and guards a
///      different shape: adapters that compute the id independently of the hook.
///
///      This test doubles as a CLASSIFICATION tripwire. A new adapter that overrides `_instancePositionId` fails
///      here until its author declares the derived id, and at that moment the failure message tells them a derived
///      id also obliges an emitted-side join case. That is the lever, not a hand-maintained "who is covered" list.
contract MetaBalanceAdapterAdvertisedShapeTest is PositionIdJoinAsserts {
    Mock_NAVCalculator internal nav;
    /// @dev Constructor dependencies for the adapters under test. NEVER used as a coordinate — see
    ///      `_assertAdvertisesCoordinate`.
    address internal stub;
    /// @dev The governed coordinate, deliberately distinct from every constructor dependency.
    address internal coordStub;

    /// @dev Pinned so adding an adapter fails `test_metaAdapterEnumerationCensus` until the author also adds it to
    ///      `test_everyMetaAdapter_advertisesItsCoordinateUnlessItDeclaresOtherwise`.
    uint256 internal constant META_ADAPTER_COUNT = 44;

    /// @dev A coordinate with dirty high bits, for the four adapters whose instance is a raw `bytes32` rather than
    ///      an address. Deliberately un-address-like: it proves those adapters really do override
    ///      `_instancePositionId`, because the base default would push it through `_toAddress`, revert, and get
    ///      dropped — which the length assertion in `_assertAdvertisedId` then catches. `abi.encode(bytes32)` and
    ///      `abi.encode(address)` are both 32 bytes, so nothing shorter than this distinguishes them.
    bytes32 internal constant RAW_COORD = keccak256("raw-bytes32-coordinate");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        stub = address(new CodeStub());
        coordStub = address(new CodeStub());
    }

    /// @dev The address-keyed default: coordinate in, `abi.encode(coordinate)` out.
    ///
    ///      The coordinate is `coordStub`, a SEPARATE address from the `stub` passed to constructors, and that
    ///      separation is load-bearing rather than tidy. Roughly eight adapters take `stub` as a constructor
    ///      dependency (`CompoundV3Comets(stub, stub)`, `UniswapV3Pools(stub)`, …), pinning it as an immutable. If
    ///      the coordinate were also `stub`, an adapter that advertised a constructor-pinned immutable instead of
    ///      the per-instance coordinate — `abi.encode(POSITION_MANAGER)`, `abi.encode(BOOSTER)` — would still
    ///      satisfy `abi.encode(stub)` and pass. That is the exact defect this suite exists to catch, so the
    ///      expected value must not be reachable from anything but the coordinate itself.
    function _assertAdvertisesCoordinate(MetaBalanceAdapter a, string memory who) internal returns (uint256) {
        return _assertAdvertisedId(nav, a, bytes32(uint256(uint160(coordStub))), abi.encode(coordStub), who);
    }

    function test_everyMetaAdapter_advertisesItsCoordinateUnlessItDeclaresOtherwise() public {
        address n = address(nav);
        uint256 i;

        // --- The one adapter whose positionId is DERIVED from its coordinate ---------------------------------
        // Coordinate is a ProtocolDataProvider; the advertised id is the Pool reached through
        // `ADDRESSES_PROVIDER().getPool()`. `SparkDataProviderStub` provides exactly that chain, and its resolved
        // pool is its own PROVIDER, so the two differ and the negative assertion below is meaningful.
        SparkDataProviderStub dp = new SparkDataProviderStub();
        AaveV3InstancesMetaBalanceAdapter aave = new AaveV3InstancesMetaBalanceAdapter(n);
        i += _assertAdvertisedId(
            nav, aave, bytes32(uint256(uint160(address(dp)))), abi.encode(dp.PROVIDER()), "AaveV3Instances"
        );
        // A NAMED diagnostic, not the guard. The value assertion above is what actually fires when the override is
        // reverted -- it pins the advertised bytes to the resolved Pool, which differs from the `dp` coordinate, so
        // it fails outright. This assertion adds a message that says WHY in the reviewer's language; it is strictly
        // weaker on its own (it would accept any value other than the coordinate, including a wrong resolution such
        // as skipping `.getPool()`), so do NOT delete the comparison above believing this covers it.
        bytes[] memory aaveIds = aave.positionIds();
        assertTrue(
            keccak256(aaveIds[0]) != keccak256(abi.encode(address(dp))),
            "AaveV3Instances: advertised id must NOT be the ProtocolDataProvider coordinate"
            " -- was the _instancePositionId override removed?"
        );

        // --- Raw-bytes32 coordinates: the id is the coordinate verbatim, never widened through an address -----
        i += _assertAdvertisedId(
            nav, new MorphoMarketsMetaBalanceAdapter(stub, n), RAW_COORD, abi.encode(RAW_COORD), "MorphoMarkets"
        );
        i += _assertAdvertisedId(
            nav, new BalancerV2PoolsMetaBalanceAdapter(stub, n), RAW_COORD, abi.encode(RAW_COORD), "BalancerV2Pools"
        );
        // The two vfat Sickle-held venues keyed by a Uniswap V4 pool id: same raw-coordinate rule, reached through
        // their own `_instancePositionId` override because the base default would reject a word with dirty upper
        // bits — which every pool id has by construction.
        i += _assertAdvertisedId(
            nav,
            new UniswapV4SicklePoolsMetaBalanceAdapter(stub, stub, stub, n, stub),
            RAW_COORD,
            abi.encode(RAW_COORD),
            "UniswapV4SicklePools"
        );
        i += _assertAdvertisedId(
            nav,
            new FablesSickleRangesMetaBalanceAdapter(stub, stub, stub, n),
            RAW_COORD,
            abi.encode(RAW_COORD),
            "FablesSickleRanges"
        );

        // --- Address-keyed, base default ---------------------------------------------------------------------
        // Aave V4's coordinate is the Spoke, which is already the contract users transact against, so unlike v3
        // it needs NO `_instancePositionId` override — the base default is correct and is what must be advertised.
        i += _assertAdvertisesCoordinate(new AaveV4SpokesMetaBalanceAdapter(n), "AaveV4Spokes");
        i += _assertAdvertisesCoordinate(new CompoundV3CometsMetaBalanceAdapter(stub, stub, n), "CompoundV3Comets");
        i += _assertAdvertisesCoordinate(
            new ConvexCurveLPStakingMetaBalanceAdapter(stub, stub, n), "ConvexCurveLPStaking"
        );
        i += _assertAdvertisesCoordinate(new EulerVaultsMetaBalanceAdapter(n), "EulerVaults");
        i += _assertAdvertisesCoordinate(new SymbioticVaultsMetaBalanceAdapter(n), "SymbioticVaults");
        i += _assertAdvertisesCoordinate(new FluidFTokensMetaBalanceAdapter(n), "FluidFTokens");
        i += _assertAdvertisesCoordinate(
            new FluidVaultsMetaBalanceAdapter(address(new FluidVaultResolverStub()), n), "FluidVaults"
        );
        i += _assertAdvertisesCoordinate(new GearboxV3CreditAccountsMetaBalanceAdapter(n), "GearboxV3CreditAccounts");
        i += _assertAdvertisesCoordinate(new GearboxV3MarketsMetaBalanceAdapter(n), "GearboxV3Markets");
        i += _assertAdvertisesCoordinate(new MorphoVaultsMetaBalanceAdapter(n), "MorphoVaults");
        i += _assertAdvertisesCoordinate(new StakeWiseV3VaultsMetaBalanceAdapter(stub, stub, n), "StakeWiseV3Vaults");
        i += _assertAdvertisesCoordinate(new PolygonStakingMetaBalanceAdapter(stub, n), "PolygonStaking");
        i += _assertAdvertisesCoordinate(new BalancerV2GaugesMetaBalanceAdapter(stub, stub, n), "BalancerV2Gauges");
        i += _assertAdvertisesCoordinate(new BalancerV3GaugesMetaBalanceAdapter(stub, n), "BalancerV3Gauges");
        i += _assertAdvertisesCoordinate(new BalancerV3PoolsMetaBalanceAdapter(n), "BalancerV3Pools");
        i += _assertAdvertisesCoordinate(new CurveGaugesMetaBalanceAdapter(stub, stub, n), "CurveGauges");
        i += _assertAdvertisesCoordinate(new CurvePoolsMetaBalanceAdapter(n), "CurvePools");
        i += _assertAdvertisesCoordinate(new PancakeSwapV2PoolsMetaBalanceAdapter(n), "PancakeSwapV2Pools");
        i += _assertAdvertisesCoordinate(new PancakeSwapV3PoolsMetaBalanceAdapter(stub, n), "PancakeSwapV3Pools");
        i += _assertAdvertisesCoordinate(new UniswapV2PoolsMetaBalanceAdapter(n), "UniswapV2Pools");
        i += _assertAdvertisesCoordinate(new UniswapV3PoolsMetaBalanceAdapter(stub, n), "UniswapV3Pools");
        // Holder indirection must leave the coordinate alone: the Sickle subclass advertises the same pool-address
        // id as its base, because WHO holds the NFT is not part of a position's identity (ADR 0026).
        i += _assertAdvertisesCoordinate(
            new UniswapV3SicklePoolsMetaBalanceAdapter(stub, n, stub), "UniswapV3SicklePools"
        );

        // --- Wallet-held yield tokens ------------------------------------------------------------------------
        // The instance coordinate is the token address and the base `_instancePositionId` is not overridden,
        // so each must advertise plain `abi.encode(token)` exactly like the group above.
        i += _assertAdvertisesCoordinate(new AaveSavingsWalletMetaBalanceAdapter(n), "AaveSavingsWallet");
        i += _assertAdvertisesCoordinate(new AnkrStakedEthWalletMetaBalanceAdapter(n), "AnkrStakedEthWallet");
        i += _assertAdvertisesCoordinate(new CoinbaseStakedEthWalletMetaBalanceAdapter(n), "CoinbaseStakedEthWallet");
        i += _assertAdvertisesCoordinate(new EthenaSavingsWalletMetaBalanceAdapter(n), "EthenaSavingsWallet");
        i += _assertAdvertisesCoordinate(new EtherFiStakedEthWalletMetaBalanceAdapter(n), "EtherFiStakedEthWallet");
        i += _assertAdvertisesCoordinate(new KelpRestakedEthWalletMetaBalanceAdapter(n), "KelpRestakedEthWallet");
        i += _assertAdvertisesCoordinate(new LidoStakedEthWalletMetaBalanceAdapter(n), "LidoStakedEthWallet");
        i += _assertAdvertisesCoordinate(
            new LiquidCollectiveStakedEthWalletMetaBalanceAdapter(n), "LiquidCollectiveStakedEthWallet"
        );
        i += _assertAdvertisesCoordinate(new MapleSavingsWalletMetaBalanceAdapter(n), "MapleSavingsWallet");
        i += _assertAdvertisesCoordinate(new NexusMutualVaultsWalletMetaBalanceAdapter(n), "NexusMutualVaultsWallet");
        i += _assertAdvertisesCoordinate(new RenzoRestakedEthWalletMetaBalanceAdapter(n), "RenzoRestakedEthWallet");
        i += _assertAdvertisesCoordinate(new ReserveBasketsWalletMetaBalanceAdapter(n), "ReserveBasketsWallet");
        i += _assertAdvertisesCoordinate(
            new RocketPoolStakedEthWalletMetaBalanceAdapter(n), "RocketPoolStakedEthWallet"
        );
        i += _assertAdvertisesCoordinate(new SkySavingsWalletMetaBalanceAdapter(n), "SkySavingsWallet");
        i += _assertAdvertisesCoordinate(new SparkSavingsWalletMetaBalanceAdapter(n), "SparkSavingsWallet");
        i += _assertAdvertisesCoordinate(new StaderStakedEthWalletMetaBalanceAdapter(n), "StaderStakedEthWallet");
        i += _assertAdvertisesCoordinate(new StakeWiseV3OsTokenWalletMetaBalanceAdapter(n), "StakeWiseV3OsTokenWallet");

        assertEq(i, META_ADAPTER_COUNT, "exercised count must equal META_ADAPTER_COUNT");
    }

    /// @dev Stops a 22nd adapter from escaping the tripwire silently. Deliberately duplicated from
    ///      {ProtocolNameConsistencyTest} (`_countMetaAdapterContracts`) rather than shared: the two censuses
    ///      guard different properties and must be able to fail independently, and both firing together on a new
    ///      adapter is the intended behaviour, not drift.
    function test_metaAdapterEnumerationCensus() public view {
        assertEq(
            _countMetaAdapterContracts("out"),
            META_ADAPTER_COUNT,
            "meta-adapter count changed: add the new adapter to"
            " test_everyMetaAdapter_advertisesItsCoordinateUnlessItDeclaresOtherwise and bump META_ADAPTER_COUNT."
            " Then classify it. If its _instancePositions builds the positionId INLINE instead of passing"
            " _instancePositionId(instance) to _leg, it can drift: add an emitted-side case in"
            " MetaBalanceAdapterEmittedJoinTest and bump DRIFT_CAPABLE_COUNT. (A DERIVED id like Aave V3's must"
            " also override _instancePositionId, but the join cannot guard that -- the value assertion here can.)"
            " Artifacts whose source is absent from this tree are already filtered, so a count that changed"
            " without you adding an adapter means a NEW artifact shape this census cannot classify -- read"
            " _isLiveConcreteArtifact before reaching for forge clean."
        );
    }

    /// @dev Counts concrete meta-adapter CONTRACT artifacts, excluding the abstract base, the interface, and any
    ///      artifact whose source is no longer in the tree. See the original in `test/ProtocolNameConsistency.t.sol`
    ///      for the reasoning behind the directory filter.
    function _countMetaAdapterContracts(string memory relDir) internal view returns (uint256 count) {
        Vm.DirEntry[] memory dirs = vm.readDir(string.concat(vm.projectRoot(), "/", relDir));
        for (uint256 i = 0; i < dirs.length; i++) {
            if (!_endsWith(dirs[i].path, "MetaBalanceAdapter.sol")) continue;
            Vm.DirEntry[] memory artifacts = vm.readDir(dirs[i].path);
            for (uint256 j = 0; j < artifacts.length; j++) {
                if (!_endsWith(artifacts[j].path, "MetaBalanceAdapter.json")) continue;
                if (!_isLiveConcreteArtifact(artifacts[j].path)) continue; // interface, abstract base, or stale
                count++;
            }
        }
    }

    /// @dev True when `artifactPath` is a CONCRETE contract that is still part of the tree. Ported verbatim from
    ///      the census in `test/ProtocolNameConsistency.t.sol`, which grew these two checks after this copy was
    ///      forked; keep the two in sync.
    /// @dev **1. Kind, not spelling.** Interfaces and abstract contracts have no creation bytecode, so an empty
    ///      `bytecode.object` identifies them by what they ARE. This replaces the hand-maintained
    ///      `/MetaBalanceAdapter.json` / `/IMetaBalanceAdapter.json` exclusions this helper used to carry, which
    ///      were a filename rule: every future marker interface or abstract base is now handled without editing a
    ///      list, as is a stale artifact of a DELETED one, which no such list could name in advance.
    /// @dev **2. The source must still exist.** The artifact records the file it was compiled from, and a foreign
    ///      or stale artifact's file is absent from THIS tree. That is the case this census actually failed on:
    ///      the `unit` job does not compile — it downloads `build`'s artifacts, and `build` compiles incrementally
    ///      against a **branch-shared sticky disk**, so `out/` carries adapters belonging to other branches
    ///      entirely. Measured: a sibling branch's `PolygonStakingMetaBalanceAdapter` artifact dropped into an
    ///      otherwise-clean `out/` took this count to 23 while the filtered census next door read 22.
    /// @dev Fails LOUD, not silent: if the artifact does not record a source path, it is COUNTED rather than
    ///      skipped, so an unrecognised artifact shape trips the census instead of quietly shrinking it. The whole
    ///      point of this test is that an unexplained count is a signal.
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
}

/// @title MetaBalanceAdapterEmittedJoinTest
/// @author KPK
/// @notice The emitted-side half: for adapters that build `PositionBalance.positionId` INDEPENDENTLY of
///         `_instancePositionId`, asserts the bytes they emit are byte-identical to the bytes they advertise.
/// @dev **The partition, counted rather than asserted.** Of the 22 meta adapters, **19** pass
///      `_instancePositionId(instance)` straight into `_leg`, so their join holds by construction and asserting it
///      would only re-test the base (already covered by {MetaBalanceAdapterEnumerationTest}). That 19 includes
///      `PancakeSwapV2PoolsMetaBalanceAdapter`, which inherits `UniswapV2Pools`'s `_instancePositions` unchanged,
///      **and `AaveV3InstancesMetaBalanceAdapter`** — Aave derives a *different* id from the coordinate, but it
///      derives it through the hook, so it cannot drift either.
///
///      Only **3** compute the id independently of the hook, and those are the drift-capable set:
///        - `UniswapV3PoolsMetaBalanceAdapter` builds `abi.encode(pool)` inline and assigns it through `_row`,
///          a SECOND positionId assignment site that exists because Uniswap needs a per-NFT `positionInstanceId`.
///        - `PancakeSwapV3PoolsMetaBalanceAdapter` inherits that path unchanged.
///        - `UniswapV3SicklePoolsMetaBalanceAdapter` inherits it too, and reaches it with a SECOND caller — the
///          vfat holder loop runs it once per holder, so the join has to hold for the Sickle's legs as well as
///          the account's.
///        - `GearboxV3CreditAccountsMetaBalanceAdapter` builds `abi.encode(ca)` inline at both leg sites.
///      For those four the two sides agree TODAY by coincidence, not by construction — that coincidence is
///      exactly what is worth pinning, because nothing in the code forces it to stay true.
///
///      `AaveV3Instances` is exercised here as a **fifth** case for a different reason: it is the only adapter
///      whose id is legitimately not its coordinate, so running the join over it documents that the derived id
///      still reconciles. It is NOT here because it can drift.
///
///      **This suite does NOT guard the Aave `_instancePositionId` override, and must not be assumed to.** Aave's
///      `_instancePositions` derives its id from the hook (`bytes memory pid = _instancePositionId(instance)`), so
///      deleting the override moves the advertised and emitted sides together and every assertion here stays
///      green. The guard for that regression is the VALUE assertion in
///      {MetaBalanceAdapterAdvertisedShapeTest}. Do not delete it as redundant with this file.
contract MetaBalanceAdapterEmittedJoinTest is PositionIdJoinAsserts {
    /// @dev Pinned alongside the adapters listed in this suite's NatSpec. If an adapter starts computing its
    ///      positionId independently of the hook, it belongs here and this count moves with it.
    uint256 internal constant DRIFT_CAPABLE_COUNT = 5;

    address internal alice = makeAddr("alice");

    // ---- Aave V3 -------------------------------------------------------------------------------------------

    function _caseAaveV3() internal returns (uint256) {
        Mock_NAVCalculator nav = new Mock_NAVCalculator();
        Mock_ERC20 usdc = new Mock_ERC20("USDC", 6);
        nav.registerAssetFromERC20(address(usdc));

        MockAavePool pool = new MockAavePool();
        MockAaveAddressesProvider provider = new MockAaveAddressesProvider(address(pool), "Aave V3 Test Instance");
        MockAaveDataProvider dp = new MockAaveDataProvider(address(provider));
        dp.addReserve("USDC", address(usdc));
        address[] memory list = new address[](1);
        list[0] = address(usdc);
        pool.setReservesList(list);
        // aToken balance, no debt, used as collateral. `cfgData` stays 0, so the unreportable-debt pre-pass
        // short-circuits false and the instance is not dropped.
        dp.setUserData(alice, address(usdc), 1_000e6, 0, true);

        AaveV3InstancesMetaBalanceAdapter a = new AaveV3InstancesMetaBalanceAdapter(address(nav));
        bytes32 coord = bytes32(uint256(uint160(address(dp))));
        nav.setMetaInstances(address(a), _one(coord));

        uint256 legs = _assertJoin(a, alice, _one(coord), "AaveV3Instances");
        assertEq(legs, 1, "one Collateral leg -- the join must run over a real position");
        return 1;
    }

    // ---- Uniswap V3 / PancakeSwap V3 -----------------------------------------------------------------------

    function _caseUniswapV3() internal returns (uint256) {
        Mock_NAVCalculator nav = new Mock_NAVCalculator();
        MockPositionManager npm = new MockPositionManager();
        MockToken wbtc = new MockToken("WBTC", 8);
        MockToken weth = new MockToken("WETH", 18);
        nav.registerAsset(address(wbtc), 8, "WBTC");
        nav.registerAsset(address(weth), 18, "WETH");

        MockUniswapV3Pool pool = new MockUniswapV3Pool(address(wbtc), address(weth), 3000, 60);
        pool.setSlot0(TickMath.getSqrtRatioAtTick(0), 0);
        npm.mint(
            alice,
            1,
            MockPositionManager.PositionData({
                token0: address(wbtc),
                token1: address(weth),
                fee: 3000,
                tickLower: -100,
                tickUpper: 100,
                liquidity: 1_000_000,
                feeGrowthInside0LastX128: 0,
                feeGrowthInside1LastX128: 0,
                tokensOwed0: 42,
                tokensOwed1: 1337
            })
        );

        UniswapV3PoolsMetaBalanceAdapter a = new UniswapV3PoolsMetaBalanceAdapter(address(npm), address(nav));
        bytes32 coord = bytes32(uint256(uint160(address(pool))));
        nav.setMetaInstances(address(a), _one(coord));

        // Emitted through `_row`, not `_leg` -- the second assignment site, and the reason this case exists.
        uint256 legs = _assertJoin(a, alice, _one(coord), "UniswapV3Pools");
        assertEq(legs, 4, "liq0 + liq1 + fee0 + fee1");
        return 1;
    }

    /// @dev The Sickle subclass inherits that same `_row` assignment site, and reaches it through a DIFFERENT
    ///      caller: the mixin's per-holder loop, with the Sickle as the holder rather than the account. The join
    ///      must survive that, or the account's own legs and its Sickle's legs would advertise different ids for
    ///      one position. The NFT is minted to the Sickle, never to `alice`, so a broken holder resolution shows
    ///      up here as zero legs rather than as a silently weaker assertion.
    function _caseUniswapV3Sickle() internal returns (uint256) {
        Mock_NAVCalculator nav = new Mock_NAVCalculator();
        MockPositionManager npm = new MockPositionManager();
        MockToken wbtc = new MockToken("WBTC", 8);
        MockToken weth = new MockToken("WETH", 18);
        nav.registerAsset(address(wbtc), 8, "WBTC");
        nav.registerAsset(address(weth), 18, "WETH");

        MockUniswapV3Pool pool = new MockUniswapV3Pool(address(wbtc), address(weth), 3000, 60);
        pool.setSlot0(TickMath.getSqrtRatioAtTick(0), 0);

        MockSickleFactory factory = new MockSickleFactory();
        MockSickle sickle = new MockSickle(alice);
        factory.setSickle(alice, address(sickle));

        npm.mint(
            address(sickle),
            1,
            MockPositionManager.PositionData({
                token0: address(wbtc),
                token1: address(weth),
                fee: 3000,
                tickLower: -100,
                tickUpper: 100,
                liquidity: 1_000_000,
                feeGrowthInside0LastX128: 0,
                feeGrowthInside1LastX128: 0,
                tokensOwed0: 42,
                tokensOwed1: 1337
            })
        );

        UniswapV3SicklePoolsMetaBalanceAdapter a =
            new UniswapV3SicklePoolsMetaBalanceAdapter(address(npm), address(nav), address(factory));
        bytes32 coord = bytes32(uint256(uint160(address(pool))));
        nav.setMetaInstances(address(a), _one(coord));

        uint256 legs = _assertJoin(a, alice, _one(coord), "UniswapV3SicklePools");
        assertEq(legs, 4, "the Sickle's liq0 + liq1 + fee0 + fee1, reported for the account");
        return 1;
    }

    function _casePancakeSwapV3() internal returns (uint256) {
        Mock_NAVCalculator nav = new Mock_NAVCalculator();
        MockPositionManager npm = new MockPositionManager();
        MockToken usdc = new MockToken("USDC", 6);
        MockToken weth = new MockToken("WETH", 18);
        nav.registerAsset(address(usdc), 6, "USDC");
        nav.registerAsset(address(weth), 18, "WETH");

        MockPancakeV3Pool pool = new MockPancakeV3Pool(address(usdc), address(weth), 500, 10);
        pool.setSlot0(TickMath.getSqrtRatioAtTick(0), 0, 0);
        npm.mint(
            alice,
            1,
            MockPositionManager.PositionData({
                token0: address(usdc),
                token1: address(weth),
                fee: 500,
                tickLower: -100,
                tickUpper: 100,
                liquidity: 2_000_000,
                feeGrowthInside0LastX128: 0,
                feeGrowthInside1LastX128: 0,
                tokensOwed0: 7,
                tokensOwed1: 99
            })
        );

        PancakeSwapV3PoolsMetaBalanceAdapter a = new PancakeSwapV3PoolsMetaBalanceAdapter(address(npm), address(nav));
        bytes32 coord = bytes32(uint256(uint160(address(pool))));
        nav.setMetaInstances(address(a), _one(coord));

        uint256 legs = _assertJoin(a, alice, _one(coord), "PancakeSwapV3Pools");
        assertEq(legs, 4, "liq0 + liq1 + fee0 + fee1");
        return 1;
    }

    // ---- Gearbox V3 credit accounts ------------------------------------------------------------------------

    function _caseGearboxV3CreditAccounts() internal returns (uint256) {
        Mock_NAVCalculator nav = new Mock_NAVCalculator();
        MockGearboxToken usdc = new MockGearboxToken("USDC", 6);
        MockGearboxToken weth = new MockGearboxToken("WETH", 18);
        nav.registerAsset(address(usdc), 6, "USDC");
        nav.registerAsset(address(weth), 18, "WETH");

        MockCreditManager cm = new MockCreditManager("Gearbox USDC v3", address(usdc));
        uint256 bitWeth = 1 << 3;
        cm.setToken(bitWeth, address(weth));
        MockCreditAccount ca = new MockCreditAccount(address(cm));
        cm.setAccount(address(ca), alice, bitWeth, 1500e6);
        weth.setBalance(address(ca), 2e18);

        GearboxV3CreditAccountsMetaBalanceAdapter a = new GearboxV3CreditAccountsMetaBalanceAdapter(address(nav));
        bytes32 coord = bytes32(uint256(uint160(address(ca))));
        nav.setMetaInstances(address(a), _one(coord));

        uint256 legs = _assertJoin(a, alice, _one(coord), "GearboxV3CreditAccounts");
        assertEq(legs, 2, "one Collateral leg + one Borrowed leg");
        return 1;
    }

    // ---- Per-adapter entry points, so a failure names one adapter rather than the whole set --------------

    function test_aaveV3_emitsTheAdvertisedPositionId() public {
        _caseAaveV3();
    }

    function test_uniswapV3_emitsTheAdvertisedPositionId() public {
        _caseUniswapV3();
    }

    function test_uniswapV3Sickle_emitsTheAdvertisedPositionId() public {
        _caseUniswapV3Sickle();
    }

    function test_pancakeSwapV3_emitsTheAdvertisedPositionId() public {
        _casePancakeSwapV3();
    }

    function test_gearboxV3CreditAccounts_emitsTheAdvertisedPositionId() public {
        _caseGearboxV3CreditAccounts();
    }

    /// @dev Keeps `DRIFT_CAPABLE_COUNT` honest against the cases actually written, by COUNTING them — each helper
    ///      returns 1, exactly as Half A accumulates `i` from `_assertAdvertisedId`.
    ///
    ///      This deliberately does not compare the constant to a literal. It previously did
    ///      (`assertEq(DRIFT_CAPABLE_COUNT, 4)`), which was a tautology: it stayed green whether a case was
    ///      deleted or a fifth drift-capable adapter went un-cased, i.e. it asserted nothing in a suite whose whole
    ///      purpose is to reject assertions that assert nothing.
    function test_driftCapableSetIsFullyExercised() public {
        uint256 i;
        i += _caseAaveV3();
        i += _caseUniswapV3();
        i += _caseUniswapV3Sickle();
        i += _casePancakeSwapV3();
        i += _caseGearboxV3CreditAccounts();
        assertEq(i, DRIFT_CAPABLE_COUNT, "exercised emitted-side cases must equal DRIFT_CAPABLE_COUNT");
    }
}
