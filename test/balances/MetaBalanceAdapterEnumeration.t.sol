// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
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

/// @dev Minimal address-keyed meta adapter: leaves `_instancePositionId` on the base default and routes its
///      emitted positionId through the same hook, which is the contract every meta adapter owes
///      {IPositionEnumerable}. Stands in for the ~18 adapters that key positions on the coordinate itself.
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

/// @title MetaBalanceAdapterEnumerationTest
/// @author KPK
/// @notice Covers {IPositionEnumerable} as implemented once on {MetaBalanceAdapter} for the whole meta family.
contract MetaBalanceAdapterEnumerationTest is Test {
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

    /// @dev Set membership over `bytes`, compared by hash — the join {IPositionEnumerable} specifies. Ordering is
    ///      disclaimed by the interface, so never compare index-wise.
    function _contains(bytes[] memory haystack, bytes memory needle) private pure returns (bool) {
        for (uint256 i; i < haystack.length; ++i) {
            if (keccak256(haystack[i]) == keccak256(needle)) return true;
        }
        return false;
    }
}
