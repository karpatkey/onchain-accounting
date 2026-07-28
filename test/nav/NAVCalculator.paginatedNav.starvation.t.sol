// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// @notice Burns a configurable amount of gas, then answers. If it is forwarded less than `cost` it runs out of
///         gas instead — which is what the caller's fail-open read is meant to absorb.
contract SlowBalanceSink {
    uint256 public cost;
    uint256 public answer;

    function set(uint256 cost_, uint256 answer_) external {
        cost = cost_;
        answer = answer_;
    }

    function balanceOf(address) external view returns (uint256) {
        uint256 c = cost;
        uint256 target = gasleft() > c ? gasleft() - c : 0;
        bytes32 h = keccak256(abi.encodePacked(target));
        while (gasleft() > target) {
            h = keccak256(abi.encodePacked(h));
        }
        if (uint256(h) == 1) return 0; // keeps `h` live
        return answer;
    }
}

/// @notice Burns gas and returns an EMPTY position list, successfully. Mirrors an adapter that does real work.
contract GasHogAdapter is IBalanceAdapter {
    uint256 public burnTo;

    function setBurnTo(uint256 v) external {
        burnTo = v;
    }

    function getAdapterPositions(address, address)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        uint256 target = burnTo;
        bytes32 h = keccak256(abi.encodePacked(target));
        while (gasleft() > target) {
            h = keccak256(abi.encodePacked(h));
        }
        if (uint256(h) == 1) revert("x");
        return new INAVCalculator.PositionBalance[](0);
    }

    function getAdapterBalances(address)
        external
        pure
        override
        returns (address[] memory, uint256[] memory, bool[] memory)
    {
        return (new address[](0), new uint256[](0), new bool[](0));
    }

    function getAdapterBalanceForAsset(address, address) external pure override returns (uint256, bool) {
        return (0, false);
    }

    function underlyingAssetsSupported() external pure override returns (address[] memory) {
        return new address[](0);
    }

    function supportsInterface(bytes4 id) external pure override returns (bool) {
        return id == type(IBalanceAdapter).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @notice An adapter that reads its position amount through the SAME fail-open low-level staticcall shape the
///         shipped `ERC20DefaultBalanceAdapter._getBalanceForAsset` uses — `staticcall(gas(), ...)`, record 0 on
///         failure, keep going. Emits one leg, credit or debt as configured.
contract FailOpenAmountAdapter is IBalanceAdapter {
    address public sink;
    address public asset;
    uint8 public assetDecimals;
    bool public debt;

    function set(address sink_, address asset_, uint8 dec_, bool debt_) external {
        sink = sink_;
        asset = asset_;
        assetDecimals = dec_;
        debt = debt_;
    }

    /// @dev Byte-for-byte the shipped pattern: all-gas-forwarding staticcall, `success` gates the decode, a
    ///      failure yields 0 and the function returns NORMALLY with the leg's amount silently zeroed.
    function _read() internal view returns (uint256 out) {
        address s = sink;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x70a0823100000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x04), 0)
            let outPtr := add(ptr, 0x40)
            mstore(outPtr, 0)
            mstore(0x40, add(outPtr, 0x20))
            let ok := staticcall(gas(), s, ptr, 0x24, outPtr, 0x20)
            if and(ok, gt(returndatasize(), 0x1f)) { out := mload(outPtr) }
        }
    }

    function getAdapterPositions(address, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory out)
    {
        if (assetFilter != address(0) && assetFilter != asset) return new INAVCalculator.PositionBalance[](0);
        uint256 amt = _read();
        if (amt == 0) return new INAVCalculator.PositionBalance[](0);

        out = new INAVCalculator.PositionBalance[](1);
        out[0].balanceAsset = INAVCalculator.Asset({asset: asset, symbol: "P", decimals: assetDecimals});
        out[0].balanceAdapter = address(this);
        out[0].amount = amt;
        out[0].isDebt = debt;
        out[0].positionId = abi.encode(asset);
        out[0].positionKind = debt ? PositionKind.Borrowed : PositionKind.Wallet;
    }

    function getAdapterBalances(address)
        external
        pure
        override
        returns (address[] memory, uint256[] memory, bool[] memory)
    {
        return (new address[](0), new uint256[](0), new bool[](0));
    }

    function getAdapterBalanceForAsset(address, address) external pure override returns (uint256, bool) {
        return (0, false);
    }

    function underlyingAssetsSupported() external view override returns (address[] memory a) {
        a = new address[](1);
        a[0] = asset;
    }

    function supportsInterface(bytes4 id) external pure override returns (bool) {
        return id == type(IBalanceAdapter).interfaceId || id == type(IERC165).interfaceId;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// @title Paginated NAV read — the gas-starvation precondition
/// @notice Pins the ONE documented exception to "the sum of slices equals `getAccountNav`", and pins it in the
///         direction that actually matters: **a slice can report a HIGHER total than the complete read, and the
///         partition can therefore OVER-report.**
///
///         The mechanism is not in the paginated read itself. Some adapters fail open *inside their own frame* and
///         return SUCCESSFULLY having dropped legs — `ERC20DefaultBalanceAdapter._getBalanceForAsset` records 0 when
///         its all-gas-forwarding `staticcall` fails, and `AssistedCoordCache._collect` swallows a starved coordinate
///         behind an uncapped `try`/`catch {}`. Nothing upstream can see either; see the "Scope, stated plainly" note
///         on `PriceFeedLib._getAdapterPositions`. Because the per-adapter stipend is a share of what the READ still
///         holds *at the point that adapter is reached*, and `computeNav` scans the supplied array IN ORDER, the
///         caller's slice composition and ORDERING decide how much gas such an adapter gets — and therefore what it
///         reports.
///
///         `FailOpenAmountAdapter` reproduces the shipped `ERC20Default` shape byte for byte and emits a **debt**
///         leg, which is what turns a dropped leg into an over-report.
/// @dev **Provenance: these cases come from the security audit of PR #187** and are promoted here from throwaway
///      probes because each one is a live regression risk, not a one-off demonstration:
///      - the directional claim they refute ("when the two disagree, trust the slice") was written into this PR's
///        docs and had to be removed; without a test, it is the kind of simplification that gets written back;
///      - `test_erc20DefaultIsPermanentlyAdapterIndexZero` pins the structural fact the corrected docs now rely on;
///      - `test_erc20DefaultIsPermanentlyAdapterIndexZero` also witnesses a genuine interior swap-and-pop, because
///        removing the last element is a self-assign that proves nothing.
///      (The irregular-flag slice-locality case that started life in the same probe file lives in the sibling unit
///      test, where it belongs — it has nothing to do with starvation.)
///
///      Every read here is given the SAME total budget (`BUDGET`), so gas is a constant across every comparison and
///      the only variable is slice composition. The fork integration test structurally cannot cover any of this:
///      forge grants effectively unlimited gas there, so nothing is ever starved.
contract PaginatedNavStarvationTest is SuperTest {
    SlowBalanceSink internal sink;
    FailOpenAmountAdapter internal failOpen;
    GasHogAdapter internal hog;

    /// @dev The sink must cost more than the starved slice can forward, and less than the complete read forwards.
    uint256 internal constant SINK_COST = 4_000_000;
    /// @dev What the hog leaves behind. Chosen so the fail-open adapter after it CANNOT forward SINK_COST, but
    ///      still has ample budget (>= (leftover)/64) to finish its own frame and return successfully.
    uint256 internal constant HOG_LEAVES = 2_000_000;
    /// @dev Total budget handed to every NAV read here, so gas is a CONSTANT across every comparison and the only
    ///      variable is slice composition/ordering.
    ///
    ///      **BUDGET is not a free parameter, and this is the fixture's one maintenance trap.** What reaches
    ///      `failOpen` behind the hog is NOT `HOG_LEAVES`: it is `HOG_LEAVES + ~BUDGET/64`, because the hog's own
    ///      stipend was 63/64 of the frame and the unspent 1/64 reserve comes back when it returns. That second
    ///      term scales with BUDGET. At 30M it is ~0.47M (so ~2.4M reaches `failOpen`, under SINK_COST, and the leg
    ///      is dropped); at 300M it would be ~4.7M, putting ~6.6M over SINK_COST so the sink COMPLETES and every
    ///      test here silently inverts. The failures would read as "the over-report is gone", i.e. as the defect
    ///      having been fixed. `test_fixturePreconditionHolds` asserts the relation directly so that a retune fails
    ///      loudly, with a message naming the cause.
    uint256 internal constant BUDGET = 30_000_000;

    function setUp() public {
        setupAll();

        sink = new SlowBalanceSink();
        // 3 WETH-worth of debt, read through the fail-open staticcall.
        sink.set(SINK_COST, 3e18);

        failOpen = new FailOpenAmountAdapter();
        failOpen.set(address(sink), address(weth), 18, true); // DEBT leg

        hog = new GasHogAdapter();
        hog.setBurnTo(HOG_LEAVES);

        address[] memory add = new address[](2);
        add[0] = address(failOpen);
        add[1] = address(hog);
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(add);

        // Give the account a plain credit position too, so the portfolio is not pure debt.
        usdc.mint(address(safe), 100_000e6);
    }

    // -- helpers ------------------------------------------------------------

    function _arr(address a) internal pure returns (address[] memory o) {
        o = new address[](1);
        o[0] = a;
    }

    function _arr(address a, address b) internal pure returns (address[] memory o) {
        o = new address[](2);
        o[0] = a;
        o[1] = b;
    }

    function _completeAt(uint256 gasBudget) internal view returns (INAVCalculator.NAV memory n) {
        (bool ok, bytes memory ret) = address(nav).staticcall{gas: gasBudget}(
            abi.encodeWithSelector(INAVCalculator.getAccountNav.selector, address(safe), address(0))
        );
        require(ok, "complete read reverted");
        n = abi.decode(ret, (INAVCalculator.NAV));
    }

    function _sliceAt(uint256 gasBudget, address[] memory adapters)
        internal
        view
        returns (INAVCalculator.PartialNAV memory p)
    {
        (bool ok, bytes memory ret) = address(nav).staticcall{gas: gasBudget}(
            abi.encodeWithSelector(
                INAVCalculator.getAccountNavForAdapters.selector, address(safe), address(0), adapters
            )
        );
        require(ok, "slice reverted");
        p = abi.decode(ret, (INAVCalculator.PartialNAV));
    }

    /// @notice The fixture's own precondition, asserted rather than assumed: `failOpen` must be starved when it sits
    ///         behind the hog and NOT starved when it is reached first. Every other test in this file is meaningless
    ///         if this inverts, and it inverts silently if BUDGET, HOG_LEAVES or SINK_COST are retuned — see the
    ///         note on BUDGET.
    function test_fixturePreconditionHolds() public view {
        assertEq(
            _sliceAt(BUDGET, _arr(address(failOpen))).value,
            -int256(3 * 324_057_000_000),
            "PRECONDITION BROKEN: failOpen must report its leg when reached first (SINK_COST too high for BUDGET?)"
        );
        assertEq(
            _sliceAt(BUDGET, _arr(address(hog), address(failOpen))).value,
            0,
            "PRECONDITION BROKEN: failOpen must be starved behind the hog (BUDGET raised? HOG_LEAVES too high?)"
        );
    }

    // ======================================================================
    // P1. The partition invariant is gas-conditional: reordering the adapters
    //     INSIDE a slice raises the reported NAV by dropping a debt leg.
    // ======================================================================

    /// @notice Control: with the fail-open adapter reached early (as `getAllAdapters()` order puts it), the debt
    ///         leg is present in the complete read.
    function test_completeReadSeesTheDebtLeg() public view {
        INAVCalculator.NAV memory complete = _completeAt(BUDGET);
        // 100k USDC credit at $1 (8dp) minus 3 WETH debt at $3240.57.
        assertEq(complete.value, 100_000 * 1e8 - 3 * 324_057_000_000, "debt leg counted in the complete read");
    }

    /// @notice Same block, same account, same total gas, coverage exactly `getAllAdapters()` once, no duplicates,
    ///         identical timestamps — and the reassembled NAV is HIGHER than `getAccountNav()`, because one slice's
    ///         ORDERING starved a fail-open debt read.
    /// @dev **What this test is for, stated precisely.** `FailOpenAmountAdapter` is configured with `debt_ = true`,
    ///      and NO shipped adapter in this repo emits a debt leg from behind an unbounded fail-open read of the kind
    ///      it models. So this is not a reproduction of a live over-report on today's adapter set — with the shipped
    ///      credit-only absorbers this mechanism can only UNDER-report.
    ///
    ///      It is the **enforcement of the adapter-layer invariant** recorded on `INAVCalculator.PartialNAV.value`:
    ///      *no adapter may emit an `isDebt == true` leg from behind any fail-open read.* This is what happens the
    ///      day one does. That framing is stronger than "here is a bug", because the invariant is written down and
    ///      enforced nowhere else, and three shipped adapters already sit close to violating it
    ///      (`EulerVaultsMeta._safeDebt`, `FluidVaultLib.aggregate`,
    ///      `GearboxV3CreditAccountsMeta._appendBorrow`).
    function test_sliceOrderingCanManufactureAnOverReport() public {
        address[] memory all = nav.getAllAdapters();
        INAVCalculator.NAV memory complete = _completeAt(BUDGET);

        // Partition: {[hog, failOpen], [erc20Default]}. Disjoint, covers the registry exactly once.
        INAVCalculator.PartialNAV memory p1 = _sliceAt(BUDGET, _arr(address(hog), address(failOpen)));
        INAVCalculator.PartialNAV memory p2 = _sliceAt(BUDGET, _arr(all[0]));

        // Every check the API tells a reassembler to run PASSES.
        assertEq(p1.timestamp, complete.timestamp, "same block");
        assertEq(p2.timestamp, complete.timestamp, "same block");
        // Coverage as a SET, not an entry count. (An entry-count check is the pattern the sibling unit file was
        // deliberately moved away from — it cannot tell "covered each once" from "covered one twice, missed one".)
        address[] memory covered = new address[](p1.adaptersCovered.length + p2.adaptersCovered.length);
        for (uint256 i = 0; i < p1.adaptersCovered.length; i++) {
            covered[i] = p1.adaptersCovered[i];
        }
        for (uint256 i = 0; i < p2.adaptersCovered.length; i++) {
            covered[p1.adaptersCovered.length + i] = p2.adaptersCovered[i];
        }
        assertEq(covered.length, all.length, "no adapter covered twice, none missed");
        for (uint256 i = 0; i < all.length; i++) {
            bool seen;
            for (uint256 j = 0; j < covered.length; j++) {
                if (covered[j] == all[i]) seen = true;
            }
            assertTrue(seen, "every registered adapter appears in the coverage union exactly once");
        }
        assertEq(p1.quoteAssetStale, complete.quoteAssetStale);
        assertEq(p1.sequencerDown, complete.sequencerDown);
        assertEq(p1.stalePriceAssets.length, 0, "no stale signal in the tampered slice");
        assertEq(p1.irregularPriceAssets.length, 0, "no irregular signal in the tampered slice");

        int256 summed = p1.value + p2.value;
        emit log_named_int("getAccountNav().value ", complete.value);
        emit log_named_int("sum of slices        ", summed);
        emit log_named_int("over-report          ", summed - complete.value);

        assertGt(summed, complete.value, "the partition sum OVER-reports vs the complete read");
        assertEq(summed - complete.value, 3 * 324_057_000_000, "over-report == the whole dropped debt leg");
    }

    /// @notice The same divergence with the fail-open adapter ALONE in its slice and ample gas: the leg is back.
    ///         Proves the divergence is caused by the per-adapter gas stipend, not by the slice mechanism itself.
    function test_oneAdapterOneBlockTwoValuesDependingOnSliceOrder() public {
        INAVCalculator.PartialNAV memory ample = _sliceAt(BUDGET, _arr(address(failOpen)));
        INAVCalculator.PartialNAV memory starved = _sliceAt(BUDGET, _arr(address(hog), address(failOpen)));

        emit log_named_int("failOpen alone       ", ample.value);
        emit log_named_int("failOpen behind hog  ", starved.value);

        assertEq(ample.value, -int256(3 * 324_057_000_000), "alone: debt leg present");
        assertEq(starved.value, 0, "behind the hog: debt leg silently gone");
        assertTrue(ample.value != starved.value, "one adapter, one block, two values");
    }

    // ======================================================================
    // P2. Dedup evasion via dirty upper bits in the address[] calldata.
    // ======================================================================

    /// @notice Craft raw calldata where element 0 carries garbage in bits 160..255 and element 1 is the same
    ///         adapter, clean. If the dedup compares raw words the duplicate slips through and the adapter is
    ///         scanned (and summed) twice.
    function test_dirtyUpperBitsCannotEvadeTheDuplicateCheck() public {
        address a = address(failOpen);
        bytes memory cd = abi.encodePacked(
            INAVCalculator.getAccountNavForAdapters.selector,
            bytes32(uint256(uint160(address(safe)))),
            bytes32(0), // quoteAsset = USD
            bytes32(uint256(0x60)), // offset to the array
            bytes32(uint256(2)), // length
            bytes32(uint256(uint160(a)) | (uint256(0xdead) << 160)), // DIRTY
            bytes32(uint256(uint160(a))) // clean
        );

        (bool ok, bytes memory ret) = address(nav).staticcall(cd);

        // The call fails, but NOT where you would guess, and the distinction is the point: returndata is EMPTY,
        // because Solidity's ABI decoder rejects an `address[] calldata` word with dirty upper bits BEFORE
        // `validateAdapterSlice` ever runs. So the duplicate check is never reached, and the security property
        // ("dirty bits cannot manufacture a duplicate") holds for a different reason than a reader might assume.
        // Asserted as an empty revert rather than as `DuplicateAdapterInSlice`, so that if a future compiler or a
        // hand-rolled decoder ever let such a word through, this test fails and sends the reader to the validator.
        assertFalse(ok, "a dirty-bits duplicate must not be answered");
        assertEq(ret.length, 0, "rejected by ABI decoding, before validateAdapterSlice - not by the dedup check");
    }

    /// @notice The sharpest form of the ordering hazard, and the one the docs assert: the SAME SET of adapters in
    ///         two different ORDERS yields two different values. `test_oneAdapterOneBlockTwoValuesDependingOnSliceOrder`
    ///         above varies composition (`{failOpen}` vs `{hog, failOpen}`), which leaves open the reading that only
    ///         slice SIZE matters. It does not: `validateAdapterSlice` preserves caller order and `computeNav` scans
    ///         in that order, so position within the slice is what decides the stipend.
    function test_sameSetInTwoOrdersGivesTwoDifferentValues() public view {
        INAVCalculator.PartialNAV memory failOpenFirst = _sliceAt(BUDGET, _arr(address(failOpen), address(hog)));
        INAVCalculator.PartialNAV memory hogFirst = _sliceAt(BUDGET, _arr(address(hog), address(failOpen)));

        // Identical sets, identical coverage cardinality, identical block.
        assertEq(failOpenFirst.adaptersCovered.length, hogFirst.adaptersCovered.length, "same set size");
        assertEq(failOpenFirst.timestamp, hogFirst.timestamp, "same block");

        // ...and different values, purely from ordering.
        assertEq(failOpenFirst.value, -int256(3 * 324_057_000_000), "reached first: debt leg present");
        assertEq(hogFirst.value, 0, "reached second, behind the hog: debt leg silently gone");
        assertTrue(failOpenFirst.value != hogFirst.value, "one set, one block, two orders, two values");
    }

    // ======================================================================
    // P3b. getAllAdapters()[0] is permanently the ERC20Default singleton, so the COMPLETE read already gives it
    //      the largest stipend any read can. A slice can only give it LESS.
    // ======================================================================

    /// @notice `getAllAdapters()[0]` is permanently the ERC20Default singleton, so the COMPLETE read already gives
    ///         it the largest stipend any read can and a slice can only ever give it LESS. The corrected docs rely on
    ///         this, so it is pinned rather than asserted in prose.
    /// @dev Two things this must actually prove, both of which an earlier version of this test did not:
    ///      1. the singleton is unremovable **for that reason** — so the revert is pinned to `InvalidArguments`, not
    ///         to `vm.expectRevert()` with no selector, which would also pass if the call reverted because the
    ///         address were merely unregistered;
    ///      2. index 0 survives a **real** swap-and-pop. Removing the LAST element is the degenerate case
    ///         (`arr[j] = arr[len-1]` with `j == len-1` is a self-assign, so nothing moves and nothing is proven).
    ///         An INTERIOR adapter is removed here, and the test additionally asserts the last element really did
    ///         fill the hole — otherwise it is not witnessing a swap-and-pop at all.
    function test_erc20DefaultIsPermanentlyAdapterIndexZero() public {
        address[] memory before = nav.getAllAdapters();
        assertGt(before.length, 2, "need >=3 adapters so that index 1 is interior, not the last element");

        // Read the singleton from its OWN getter, then assert index 0 IS it. Defining `def = before[0]` and later
        // asserting `getAllAdapters()[0] == def` would be a tautology: it pins that index 0 does not change, not
        // that index 0 is the default adapter, which is the claim the docs rely on.
        address def = nav.erc20DefaultBalanceAdapter();
        assertEq(before[0], def, "index 0 IS the ERC20Default singleton, not merely stable");

        // (1) The singleton is unremovable, and specifically because it is the singleton.
        vm.prank(navCalculatorManager);
        vm.expectRevert(InvalidArguments.selector);
        nav.removeBalanceAdapters(_arr(def));

        // (2) Remove an INTERIOR adapter (index 1) and watch the LAST element fill its hole while index 0 holds.
        address interior = before[1];
        address last = before[before.length - 1];
        assertTrue(interior != last, "index 1 must not be the last element or this is the degenerate case again");

        vm.prank(navCalculatorManager);
        nav.removeBalanceAdapters(_arr(interior));

        address[] memory after_ = nav.getAllAdapters();
        assertEq(after_.length, before.length - 1, "one adapter removed");
        assertEq(after_[1], last, "the LAST element filled the hole - this is a genuine swap-and-pop");
        assertEq(after_[0], def, "and index 0 is untouched by it");
    }

    // ======================================================================
    // P4. Control: with ample gas everywhere, the invariant does hold exactly.
    // ======================================================================

    function test_partitionHoldsExactlyWhenNobodyIsStarved() public view {
        address[] memory all = nav.getAllAdapters();
        INAVCalculator.NAV memory complete = _completeAt(BUDGET);

        int256 summed;
        for (uint256 i = 0; i < all.length; i++) {
            summed += _sliceAt(BUDGET, _arr(all[i])).value;
        }
        assertEq(summed, complete.value, "singleton partition sums exactly when nothing is starved");
    }
}
