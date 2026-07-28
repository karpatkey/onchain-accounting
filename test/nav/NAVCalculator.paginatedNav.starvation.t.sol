// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {Mock_CustomBalanceAdapter} from "test/mocks/balance_adapters.sol";
import {Mock_CustomPriceFeed} from "test/mocks/price_oracles.sol";
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
///      - `test_irregularIsSliceLocalAndDedupedUnionRecoversIt` asserts `rawHits > dedupedCount`, i.e. that the
///        documented de-duplication obligation is load-bearing rather than decorative.
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
    /// @dev Total budget handed to every NAV read in these probes, so gas is a CONSTANT across the comparison and
    ///      the only variable is the slice composition.
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

    /// @notice THE PROBE. Same block, same account, same total gas, coverage exactly equal to `getAllAdapters()`
    ///         once, no duplicates, identical timestamps — and the reassembled NAV is HIGHER than
    ///         `getAccountNav()` because one slice's ORDERING starved the fail-open debt read.
    function test_sliceOrderingCanManufactureAnOverReport() public {
        address[] memory all = nav.getAllAdapters();
        INAVCalculator.NAV memory complete = _completeAt(BUDGET);

        // Partition: {[hog, failOpen], [erc20Default]}. Disjoint, covers the registry exactly once.
        INAVCalculator.PartialNAV memory p1 = _sliceAt(BUDGET, _arr(address(hog), address(failOpen)));
        INAVCalculator.PartialNAV memory p2 = _sliceAt(BUDGET, _arr(all[0]));

        // Every check the API tells a reassembler to run PASSES.
        assertEq(p1.timestamp, complete.timestamp, "same block");
        assertEq(p2.timestamp, complete.timestamp, "same block");
        assertEq(p1.adaptersCovered.length + p2.adaptersCovered.length, all.length, "coverage count matches");
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
        emit log_named_bytes("returndata", ret);
        assertFalse(ok, "a dirty-bits duplicate must not be answered");
        if (ret.length >= 4) {
            bytes4 sel = bytes4(ret);
            assertTrue(
                sel == INAVCalculator.DuplicateAdapterInSlice.selector || sel == bytes4(0),
                "expected DuplicateAdapterInSlice (or a bare ABI-validation revert)"
            );
        }
    }

    // ======================================================================
    // P3. irregularPriceAssets slice-locality + union recovery (test gap).
    // ======================================================================

    function test_irregularIsSliceLocalAndDedupedUnionRecoversIt() public {
        // Make WETH irregular (primary $3240.57 vs monitor $3400 -> ~492bps > 250bps tolerance).
        Mock_CustomPriceFeed monitor = new Mock_CustomPriceFeed("WETH-monitor", address(weth), 340_000_000_000, 8);
        vm.startPrank(navCalculatorManager);
        nav.setDivergenceTolerance(address(weth), 250);
        nav.addMonitorFeed(address(weth), address(monitor), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        // A plain adapter holding WETH, so WETH is reachable through exactly one non-fail-open adapter.
        Mock_CustomBalanceAdapter wethAd = new Mock_CustomBalanceAdapter();
        address[] memory sup = new address[](1);
        sup[0] = address(weth);
        wethAd.setUnderlyingAssetsSupported(sup);
        wethAd.setBalance(address(weth), address(safe), 1e18, false);
        address[] memory add = new address[](1);
        add[0] = address(wethAd);
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(add);

        INAVCalculator.NAV memory complete = _completeAt(BUDGET);
        assertEq(complete.irregularPriceAssets.length, 1, "complete read sees WETH irregular");
        assertEq(complete.irregularPriceAssets[0].asset, address(weth));

        INAVCalculator.PartialNAV memory withIrr = _sliceAt(BUDGET, _arr(address(wethAd)));
        assertEq(withIrr.irregularPriceAssets.length, 1, "the slice holding WETH reports it");
        assertEq(withIrr.irregularPriceAssets[0].asset, address(weth));

        // A slice NOT holding WETH loses the signal entirely - the documented hazard, pinned.
        address[] memory all = nav.getAllAdapters();
        INAVCalculator.PartialNAV memory withoutIrr = _sliceAt(BUDGET, _arr(all[0]));
        assertEq(withoutIrr.irregularPriceAssets.length, 0, "a slice not holding WETH reports nothing irregular");

        // Union over the whole partition, DE-DUPLICATED (the interface docstring requires the dedupe: WETH is
        // reachable through two adapters here, so two slices each report it), recovers exactly the complete set.
        address[] memory seen = new address[](16);
        uint256 seenN;
        uint256 rawHits;
        for (uint256 i = 0; i < all.length; i++) {
            INAVCalculator.PartialNAV memory p = _sliceAt(BUDGET, _arr(all[i]));
            for (uint256 j = 0; j < p.irregularPriceAssets.length; j++) {
                rawHits++;
                address a = p.irregularPriceAssets[j].asset;
                bool dup;
                for (uint256 k = 0; k < seenN; k++) {
                    if (seen[k] == a) dup = true;
                }
                if (!dup) seen[seenN++] = a;
            }
        }
        assertEq(seenN, 1, "de-duplicated union has exactly the complete read's cardinality");
        assertEq(seen[0], address(weth), "and it is the same asset");
        assertGt(rawHits, seenN, "the RAW union over-counts - the documented dedupe obligation is load-bearing");
    }

    // ======================================================================
    // P3b. getAllAdapters()[0] is permanently the ERC20Default singleton, so the COMPLETE read already gives it
    //      the largest stipend any read can. A slice can only give it LESS.
    // ======================================================================

    function test_erc20DefaultIsPermanentlyAdapterIndexZero() public {
        address[] memory all = nav.getAllAdapters();
        address def = all[0];

        // It cannot be removed at all.
        vm.prank(navCalculatorManager);
        vm.expectRevert();
        nav.removeBalanceAdapters(_arr(def));

        // Removing anything else swap-and-pops the LAST element into the hole, never index 0.
        vm.prank(navCalculatorManager);
        nav.removeBalanceAdapters(_arr(address(hog)));
        assertEq(nav.getAllAdapters()[0], def, "index 0 survives a swap-and-pop removal");
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
