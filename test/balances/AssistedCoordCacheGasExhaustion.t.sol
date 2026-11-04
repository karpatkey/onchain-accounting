// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {AssistedCoordCache, CoordinateGasExhausted} from "src/balances/AssistedBalanceAdapters/AssistedCoordCache.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {GasStipendLib} from "src/utils/GasStipendLib.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";

/// @notice A coordinate's own revert, so a test can tell "this coordinate answered: nothing" from "this
///         coordinate never answered". The two are indistinguishable to `catch`, which is the whole point.
error MockCoordUnavailable();

/// @notice The sub-contract a coordinate's live valuation reaches into, which never returns.
/// @dev Nesting is the realistic shape: a coordinate loses its gas inside the protocol it reads, not in its own
///      frame, so EIP-150 leaves a reserve behind and the loop never observes the full stipend consumed.
contract Mock_CoordSink {
    function burn() external pure {
        assembly {
            for {} 1 {} { mstore(0x00, keccak256(0x00, 0x20)) }
        }
    }
}

/// @notice A minimal concrete member of the assisted family whose coordinates behave differently by id.
contract Mock_AssistedAdapter is AssistedCoordCache {
    uint256 internal constant HEALTHY = 1;
    uint256 internal constant STARVING = 2;
    uint256 internal constant REVERTING = 3;

    uint256 public constant LEG_AMOUNT = 100e18;

    Mock_CoordSink private immutable SINK;

    constructor(address underlying_, address nav_) AssistedCoordCache(underlying_, nav_, msg.sender) {
        SINK = new Mock_CoordSink();
    }

    function submit(uint256 id) external {
        _submitCoord(abi.encode(id));
    }

    function _maxCoords() internal pure override returns (uint256) {
        return 16;
    }

    function _maxLegsPerCoord() internal pure override returns (uint256) {
        return 1;
    }

    function _coordId(bytes memory coord) internal pure override returns (uint256) {
        return abi.decode(coord, (uint256));
    }

    function _validateCoord(address, bytes memory) internal view override {}

    function _removable(address, bytes memory) internal view override returns (bool) {
        return true;
    }

    function _coordLength() internal pure override returns (uint256) {
        return 32;
    }

    function _isDead(address, bytes memory) internal view override returns (bool) {
        return true;
    }

    function _valueCoord(address, bytes memory coord, INAVCalculator.Asset memory underlying)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory legs)
    {
        uint256 id = abi.decode(coord, (uint256));
        if (id == STARVING) SINK.burn();
        if (id == REVERTING) revert MockCoordUnavailable();

        legs = new INAVCalculator.PositionBalance[](1);
        legs[0].balanceAsset = underlying;
        legs[0].balanceAdapter = address(this);
        legs[0].amount = LEG_AMOUNT;
        legs[0].protocolBrand = ProtocolIds.NEXUS_MUTUAL;
        legs[0].protocolId = ProtocolIds.NEXUS_MUTUAL;
        legs[0].protocolSubId = ProtocolIds.NEXUS_MUTUAL_STAKING_POOLS;
        legs[0].positionId = coord;
        legs[0].positionKind = PositionKind.Supplied;
    }
}

/// @notice Reproduces `PriceFeedLib._getAdapterPositions`'s measurement exactly, one frame outside the adapter.
/// @dev This is how the port's divergence is MEASURED rather than argued. `PriceFeedLib` will not honour
///      {CoordinateGasExhausted} as a selector (see the test doc), so what actually protects the read is its gas
///      heuristic — and that heuristic is this arithmetic. Recomputing it here proves the heuristic fires.
contract AdapterBoundaryHarness {
    function measure(address adapter, address account)
        external
        view
        returns (uint8 status, uint256 stipend, uint256 consumed, bool classifiedExhausted, uint256 legs)
    {
        uint256 available = gasleft();
        stipend = GasStipendLib.stipendFrom(available);
        try IBalanceAdapter(adapter).getAdapterPositions{gas: stipend}(account, address(0)) returns (
            INAVCalculator.PositionBalance[] memory p
        ) {
            return (0, stipend, available - gasleft(), false, p.length);
        } catch {
            consumed = available - gasleft();
            return (1, stipend, consumed, GasStipendLib.exhausted(stipend, consumed), 0);
        }
    }
}

/// @title AssistedCoordCache per-coordinate gas exhaustion
/// @author KPK
/// @notice Pins the one failure the per-coordinate `try`/`catch` must NOT absorb, and measures the one way this
///         port diverges from the meta-adapter fix it is modelled on.
/// @dev The valuation fan-out isolates each cached coordinate so a single revert-prone one cannot zero out the
///      account's set, and that isolation is deliberate. Gas exhaustion is not that: the coordinate did not
///      answer, and recording it as zero legs deletes a real position while `_collect` still returns
///      successfully — so nothing downstream can tell the answer was partial.
///
///      **The divergence, measured here.** `PriceFeedLib._reraiseIfInstanceExhausted` re-raises a meta-adapter's
///      `InstanceGasExhausted` only after three gates, the last of which is
///      `supportsInterface(IMetaBalanceAdapter)`. This family answers `IBalanceAdapter` /
///      `IAssistedBalanceAdapter` / `IERC165` and NOT `IMetaBalanceAdapter`, so a selector raised here can never
///      pass that gate. That is why this raises its own {CoordinateGasExhausted} rather than borrowing the
///      meta-adapter's error: borrowing it would be cargo-culting a signal that provably cannot be read.
///
///      What protects the NAV read instead is `PriceFeedLib`'s gas heuristic, and
///      `test_starvedCoordinate_isClassifiedExhaustedAtTheAdapterBoundary` measures that it fires — a starved
///      coordinate burns 63/64 of the loop's remaining budget before this contract raises, so `consumed` clears
///      `stipend - stipend/8` comfortably at the boundary above. The outcome is a loud `AdapterGasExhausted`
///      rather than a silent partial answer, which is the property that matters; naming the coordinate is a
///      bonus this contract's own error provides to direct callers.
contract AssistedCoordCacheGasExhaustionTest is Test {
    Mock_ERC20 internal token;
    Mock_NAVCalculator internal nav;
    Mock_AssistedAdapter internal adapter;
    AdapterBoundaryHarness internal harness;

    address internal constant ACCOUNT = address(0xA11CE);

    function setUp() public {
        token = new Mock_ERC20("NXM", 18);
        nav = new Mock_NAVCalculator();
        nav.registerAsset(address(token), 18, "NXM");
        adapter = new Mock_AssistedAdapter(address(token), address(nav));
        harness = new AdapterBoundaryHarness();
    }

    function _submit(uint256[] memory ids) internal {
        vm.startPrank(ACCOUNT);
        for (uint256 i; i < ids.length; ++i) {
            adapter.submit(ids[i]);
        }
        vm.stopPrank();
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }

    // ─── The isolation that must STAY ─────────────────────────────────────────

    /// @notice A coordinate that reverts cheaply is still isolated — the other coordinate's leg survives.
    /// @dev This is the behaviour the fix must not regress. A reverting coordinate has ANSWERED.
    function test_revertingCoordinate_isStillIsolated() public {
        _submit(_ids(1, 3)); // healthy + reverting
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(ACCOUNT, address(0));
        assertEq(p.length, 1, "the healthy coordinate must still report");
        assertEq(p[0].amount, adapter.LEG_AMOUNT());
    }

    /// @notice TWO healthy coordinates both report — the stipend does not starve an ordinary read.
    /// @dev The first draft submitted `(1, 1)`. Coordinates dedupe on `keccak256(coord)`, so that cached ONE
    ///      entry and asserted a single-iteration loop — while the thing this commit introduces is a
    ///      per-iteration `{gas: stipend}` derivation, which only has a second iteration to get wrong. A
    ///      regression that mis-derived the stipend from iteration 2 onwards would have left it green. Any id
    ///      outside {2, 3} is healthy in the mock, so `(1, 4)` gives a genuine two-element loop.
    ///      Caught in review; it is the same vacuous-test class this PR exists to sweep for.
    function test_healthyCoordinates_unaffectedByTheStipend() public {
        _submit(_ids(1, 4));
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(ACCOUNT, address(0));
        assertEq(p.length, 2, "both healthy coordinates must report");
        assertEq(p[0].amount + p[1].amount, adapter.LEG_AMOUNT() * 2, "and both must carry their full leg");
    }

    // ─── The failure that must NOT be absorbed ────────────────────────────────

    /// @notice A starved coordinate raises instead of silently vanishing from the total.
    /// @dev Before the fix this returned SUCCESSFULLY with one leg (the healthy coordinate) and no indication
    ///      that a second position had been dropped. `expectRevert` on the specific selector is what kills that
    ///      mutation: swapping the raise back for `catch {}` turns this into a passing 1-leg return.
    function test_starvedCoordinate_raisesInsteadOfBeingSwallowed() public {
        _submit(_ids(1, 2)); // healthy + starving
        vm.expectPartialRevert(CoordinateGasExhausted.selector);
        adapter.getAdapterPositions{gas: 3_000_000}(ACCOUNT, address(0));
    }

    /// @notice The starved coordinate also poisons the ones AFTER it, which is why swallowing was so bad.
    /// @dev A starved child takes 63/64 of what the loop held, so the residue cannot fund later coordinates
    ///      either. Ordering the starving coordinate FIRST is the worst case: under the old behaviour the whole
    ///      account read as empty while still returning success.
    function test_starvedCoordinateFirst_stillRaises() public {
        _submit(_ids(2, 1)); // starving + healthy
        vm.expectPartialRevert(CoordinateGasExhausted.selector);
        adapter.getAdapterPositions{gas: 3_000_000}(ACCOUNT, address(0));
    }

    // ─── The divergence from PR #182, measured ────────────────────────────────

    /// @notice `PriceFeedLib`'s gas heuristic classifies this as exhausted, even though it cannot read the
    ///         selector — so the NAV read fails loudly rather than accepting a partial answer.
    /// @dev The load-bearing measurement of this port. `classifiedExhausted` is `GasStipendLib.exhausted`
    ///      computed on the same `(stipend, consumed)` pair `PriceFeedLib._getAdapterPositions` computes, so a
    ///      true here means that function reverts `AdapterGasExhausted` rather than failing open.
    function test_starvedCoordinate_isClassifiedExhaustedAtTheAdapterBoundary() public {
        _submit(_ids(1, 2));
        (uint8 status, uint256 stipend, uint256 consumed, bool classifiedExhausted,) =
            harness.measure{gas: 3_000_000}(address(adapter), ACCOUNT);

        assertEq(status, 1, "the adapter must revert, not return a partial answer");
        assertTrue(classifiedExhausted, "PriceFeedLib's heuristic must score this exhausted, not benign");
        assertGe(consumed, stipend - stipend / 8, "the predicate itself, spelled out");
    }

    /// @notice A merely-reverting coordinate is NOT misclassified as exhaustion at the boundary.
    /// @dev The other side of the bracket. Without this, a fix that reverted on every caught coordinate would
    ///      pass the test above and turn every bad NFT into a failed NAV read for the whole account.
    function test_revertingCoordinate_isNotClassifiedExhausted() public {
        _submit(_ids(1, 3));
        (uint8 status,,, bool classifiedExhausted, uint256 legs) =
            harness.measure{gas: 3_000_000}(address(adapter), ACCOUNT);

        assertEq(status, 0, "a reverting coordinate must not fail the adapter");
        assertFalse(classifiedExhausted);
        assertEq(legs, 1, "the healthy coordinate still reports");
    }

    /// @notice The balance getters share `_collect`, so they inherit the same guard.
    function test_getAdapterBalanceForAsset_alsoRaisesOnStarvation() public {
        _submit(_ids(1, 2));
        vm.expectPartialRevert(CoordinateGasExhausted.selector);
        adapter.getAdapterBalanceForAsset{gas: 3_000_000}(ACCOUNT, address(token));
    }
}
