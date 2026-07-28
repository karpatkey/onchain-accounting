// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console2} from "forge-std/console2.sol";
import {IntegrationFromConfigBase} from "test/integration/IntegrationFromConfigBase.fork.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title Paginated NAV read — mainnet fork invariant
/// @notice THE load-bearing test for `getAccountNavForAdapters`. On the full mainnet registry (every asset and
///         every balance adapter the deploy config enables — meta-adapters with their real governed instance sets
///         included), the sum of the paginated read over a disjoint partition covering all of `getAllAdapters()`
///         must reproduce `getAccountNav()` exactly: the `value`, and the UNION of every health flag.
///
///         If that invariant holds, the API is sound and an off-chain caller following the documented contract can
///         reassemble a NAV that is byte-identical to the complete read's. If it fails, the API is not shippable —
///         a slice-based reader would produce a wrong NAV that looks entirely plausible.
/// @dev Uses `IntegrationFromConfigBase` rather than the leaner NAV fork harness because only the former builds a
///      real registry from the deploy config, with real meta-instance sets. A partition invariant proven against
///      three mock adapters proves very little; the interesting cases — a meta-adapter fanning out over 14 Morpho
///      markets, an adapter reporting a debt leg, two adapters reporting the same asset — only exist here.
///
///      **Coverage, stated honestly: this harness registers 41 assets and 21 adapters, where the mainnet deploy
///      config carries 43 and 27.** The six it skips are the ones whose deploy type the harness does not know
///      (`EthenaCooldown`, `LidoWithdrawalQueue`, `EulerVaultsMeta`, and the three assisted adapters). So the
///      invariant is NOT exercised over those six, and an adapter whose behaviour differs under a one-adapter slice
///      would ship unverified. Do not read this file as proving the whole production registry. (The exact counts are
///      asserted below rather than trusted from this comment, so the two cannot drift.)
///
///      The fork block comes from test/integration/accounts.json via the base (see
///      docs/howto/refresh-integration-test-blocks.md). The two ACCOUNT addresses below ARE pinned here — the base
///      class exposes no per-account accessor to read them by label, and the refresh script only rewrites
///      `forkBlock` and the expected NAVs, not the address list. That pinning is why
///      `_assertPartitionReproducesNav` asserts the account actually holds positions: if one of these accounts ever
///      exits everything, `computeNav` takes its empty-positions early return and every partition assertion below
///      would compare 0 against 0 and pass while proving nothing.
contract MainnetPaginatedNavIntegration is IntegrationFromConfigBase {
    /// @notice The most diversified mainnet test account — positions across lending, LP, staking and queues, which
    ///         is what makes its partition worth summing.
    address internal constant ACCOUNT_9_DIVERSIFIED = 0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669;

    /// @notice A second, differently-shaped account (Compound + Uniswap V3 LP) so the invariant is not a property
    ///         of one portfolio's adapter mix.
    address internal constant ACCOUNT_11 = 0x0EFcCBb9E2C09Ea29551879bd9Da32362b32fc89;

    function setUp() public {
        _chainId = 1;
        _forkNetwork = "eth-mainnet";
        _setupAndDeploy();
    }

    // -----------------------------------------------------------------------
    // The invariant
    // -----------------------------------------------------------------------

    /// @notice Singleton partition — one slice per registered adapter. The finest partition available, and the
    ///         harshest test of the sum: any per-slice constant leaking into `value` is multiplied by the adapter
    ///         count, and any flag that fails to survive slicing is dropped by 20-odd slices instead of one.
    function test_singletonPartitionReproducesCompleteNav() public view {
        _assertPartitionReproducesNav(ACCOUNT_9_DIVERSIFIED, 1);
    }

    /// @notice The same account under a coarser partition (slices of 4). A real pager batches adapters, and a
    ///         multi-adapter slice exercises the in-slice aggregation that singletons never touch.
    function test_batchedPartitionReproducesCompleteNav() public view {
        _assertPartitionReproducesNav(ACCOUNT_9_DIVERSIFIED, 4);
    }

    /// @notice A second portfolio shape, so the invariant is not an artefact of one account's adapter mix.
    function test_partitionReproducesCompleteNavForSecondAccount() public view {
        _assertPartitionReproducesNav(ACCOUNT_11, 3);
    }

    /// @notice Pins what this harness actually covers, so the docblock's honesty claim is enforced rather than
    ///         asserted in prose. If the harness gains or loses an adapter/asset — because a deploy type became
    ///         recognised, or the config changed — this fails and the coverage caveat above must be re-stated
    ///         rather than silently becoming wrong.
    /// @dev Deliberately a hard equality, not a lower bound. A lower bound would let coverage silently shrink,
    ///      which is the direction that matters: the caveat exists to stop a reader believing the invariant spans
    ///      the production registry.
    function test_harnessCoverageIsWhatTheDocblockClaims() public view {
        assertEq(nav.getAssetCount(), 41, "harness asset count changed - update the coverage caveat in the docblock");
        assertEq(
            nav.getAllAdapters().length,
            21,
            "harness adapter count changed - update the coverage caveat in the docblock"
        );
    }

    /// @notice Partitions `getAllAdapters()` into consecutive slices of at most `sliceSize`, reads each, and
    ///         asserts the reassembled result equals `getAccountNav` in every field a caller would use.
    /// @param account The account to value.
    /// @param sliceSize Maximum adapters per slice.
    function _assertPartitionReproducesNav(address account, uint256 sliceSize) internal view {
        INAVCalculator.NAV memory complete = nav.getAccountNav(account, QUOTE_USD);
        address[] memory all = nav.getAllAdapters();
        assertGt(all.length, 5, "the mainnet registry should have many adapters; partitioning is trivial otherwise");

        // NON-VACUITY GUARD. Without this, an account that has exited all its positions makes computeNav take its
        // `allPositions.length == 0` early return: complete.value is 0, every slice is 0, both flag arrays are empty
        // on both sides, and every assertion below compares zero against zero. All three partition tests would stay
        // green while proving nothing — and this file is the gate that decides the API is shippable, so a genuine
        // partition defect could ship behind it. The accounts are pinned in this file (see the note above), so
        // nothing else notices when one of them goes quiet.
        assertTrue(
            complete.value != 0, "account holds no value at this fork block; partition assertions would be vacuous"
        );
        assertGt(
            nav.getAccountPositions(account, QUOTE_USD).length,
            1,
            "account must hold several positions for a partition to test anything"
        );

        int256 summedValue;
        uint256 coveredCount;
        bool unionSequencerDown;
        bool unionQuoteAssetStale;
        bool unionQuoteAssetIrregular;

        // Unions accumulate as (possibly duplicated) concatenations; set-equality is asserted below in both
        // directions, which is the check a reassembler actually needs and which does not require de-duplicating.
        address[] memory unionStale = new address[](0);
        address[] memory unionIrregular = new address[](0);
        address[] memory concatCovered = new address[](0);

        for (uint256 start = 0; start < all.length; start += sliceSize) {
            uint256 end = start + sliceSize > all.length ? all.length : start + sliceSize;
            address[] memory slice = new address[](end - start);
            for (uint256 i = start; i < end; i++) {
                slice[i - start] = all[i];
            }

            INAVCalculator.PartialNAV memory p = nav.getAccountNavForAdapters(account, QUOTE_USD, slice);

            summedValue += p.value;
            coveredCount += p.adaptersCovered.length;
            unionSequencerDown = unionSequencerDown || p.sequencerDown;
            unionQuoteAssetStale = unionQuoteAssetStale || p.quoteAssetStale;
            unionQuoteAssetIrregular = unionQuoteAssetIrregular || p.quoteAssetIrregular;

            // Same block for every slice — obligation 3 of the caller contract, and here it is guaranteed by
            // being one test frame. A real pager has to check it.
            assertEq(p.timestamp, complete.timestamp, "every slice is stamped with the same block");
            assertEq(p.quoteAsset.asset, complete.quoteAsset.asset, "same quote asset in every slice");

            // The slice covered exactly what it was asked for, in order.
            assertEq(p.adaptersCovered.length, slice.length, "slice covered exactly the adapters supplied");
            for (uint256 i = 0; i < slice.length; i++) {
                assertEq(p.adaptersCovered[i], slice[i], "adaptersCovered preserves the supplied order");
            }

            concatCovered = _concat(concatCovered, p.adaptersCovered);
            unionStale = _concat(unionStale, _addressesOf(p.stalePriceAssets));
            unionIrregular = _concat(unionIrregular, _addressesOf(p.irregularPriceAssets));
        }

        // --- Coverage: the partition covered the registry exactly once. ---
        assertEq(coveredCount, all.length, "partition covers every registered adapter exactly once");
        assertEq(concatCovered.length, all.length, "no adapter covered twice, none missed");
        for (uint256 i = 0; i < all.length; i++) {
            assertTrue(_contains(concatCovered, all[i]), "every registered adapter appears in the coverage union");
        }

        // --- The one field that sums. Exactly, with no tolerance. ---
        assertEq(summedValue, complete.value, "sum of slice values == complete NAV value, exactly");

        // --- The fields that must be UNIONED. ---
        assertEq(unionSequencerDown, complete.sequencerDown, "OR of sequencerDown matches the complete read");
        assertEq(unionQuoteAssetStale, complete.quoteAssetStale, "OR of quoteAssetStale matches the complete read");
        assertEq(
            unionQuoteAssetIrregular,
            complete.quoteAssetIrregular,
            "OR of quoteAssetIrregular matches the complete read"
        );
        _assertSameSet(unionStale, _addressesOf(complete.stalePriceAssets), "stalePriceAssets union");
        _assertSameSet(unionIrregular, _addressesOf(complete.irregularPriceAssets), "irregularPriceAssets union");
    }

    // -----------------------------------------------------------------------
    // The failure modes, on the real registry
    // -----------------------------------------------------------------------

    /// @notice A partition that omits one adapter must be detectable from `adaptersCovered` alone. The value it
    ///         produces is a perfectly plausible NAV, which is exactly why coverage has to be checkable
    ///         independently of it.
    function test_omittedAdapterIsDetectableFromCoverage() public view {
        address[] memory all = nav.getAllAdapters();
        address omitted = all[all.length - 1];

        address[] memory concatCovered = new address[](0);
        int256 summedValue;
        for (uint256 i = 0; i < all.length - 1; i++) {
            address[] memory slice = new address[](1);
            slice[0] = all[i];
            INAVCalculator.PartialNAV memory p = nav.getAccountNavForAdapters(ACCOUNT_9_DIVERSIFIED, QUOTE_USD, slice);
            summedValue += p.value;
            concatCovered = _concat(concatCovered, p.adaptersCovered);
        }

        assertEq(concatCovered.length, all.length - 1, "coverage is detectably one adapter short");
        assertFalse(_contains(concatCovered, omitted), "and the missing adapter is identifiable by name");

        // The short sum is NOT flagged by anything in the result — only the coverage check catches it. If the
        // omitted adapter happens to hold nothing for this account the values coincide, which is the point: value
        // equality is not evidence of complete coverage, in either direction.
        INAVCalculator.NAV memory complete = nav.getAccountNav(ACCOUNT_9_DIVERSIFIED, QUOTE_USD);
        console2.log("omitted adapter", omitted);
        console2.log("complete value", complete.value);
        console2.log("short sum     ", summedValue);
    }

    function test_revertsOnUnregisteredAdapter() public {
        address stranger = makeAddr("not-an-adapter");
        vm.expectRevert(abi.encodeWithSelector(INAVCalculator.AdapterNotRegistered.selector, stranger));
        address[] memory slice = new address[](1);
        slice[0] = stranger;
        nav.getAccountNavForAdapters(ACCOUNT_9_DIVERSIFIED, QUOTE_USD, slice);
    }

    function test_revertsOnDuplicateAdapter() public {
        address[] memory all = nav.getAllAdapters();
        address[] memory slice = new address[](2);
        slice[0] = all[0];
        slice[1] = all[0];
        vm.expectRevert(abi.encodeWithSelector(INAVCalculator.DuplicateAdapterInSlice.selector, all[0]));
        nav.getAccountNavForAdapters(ACCOUNT_9_DIVERSIFIED, QUOTE_USD, slice);
    }

    function test_revertsOnEmptySlice() public {
        vm.expectRevert(INAVCalculator.EmptyAdapterSlice.selector);
        nav.getAccountNavForAdapters(ACCOUNT_9_DIVERSIFIED, QUOTE_USD, new address[](0));
    }

    /// @notice A single-adapter slice against the real registry, pinned separately from the partition so the
    ///         narrowest possible read is covered on its own.
    function test_singleAdapterSlice() public view {
        address[] memory all = nav.getAllAdapters();
        address[] memory slice = new address[](1);
        slice[0] = all[0];

        INAVCalculator.PartialNAV memory p = nav.getAccountNavForAdapters(ACCOUNT_9_DIVERSIFIED, QUOTE_USD, slice);
        assertEq(p.adaptersCovered.length, 1);
        assertEq(p.adaptersCovered[0], all[0]);
        assertEq(p.timestamp, uint64(block.timestamp));
    }

    // -----------------------------------------------------------------------
    // Gas — the measurement that motivates the API
    // -----------------------------------------------------------------------

    /// @notice Reports what the complete read costs against the real registry, and what each adapter costs on its
    ///         own, so the pagination argument rests on measured numbers rather than an assumption about growth.
    /// @dev Logs only; asserts nothing about gas. A gas assertion here would be a pin on live mainnet state and
    ///      would fail on the next fork-block refresh for no useful reason.
    function test_reportSliceGas() public view {
        address[] memory all = nav.getAllAdapters();

        uint256 before = gasleft();
        nav.getAccountNav(ACCOUNT_9_DIVERSIFIED, QUOTE_USD);
        uint256 completeGas = before - gasleft();

        console2.log("registered assets  ", nav.getAssetCount());
        console2.log("registered adapters", all.length);
        console2.log("complete getAccountNav gas", completeGas);

        uint256 summed;
        for (uint256 i = 0; i < all.length; i++) {
            address[] memory slice = new address[](1);
            slice[0] = all[i];
            uint256 g = gasleft();
            nav.getAccountNavForAdapters(ACCOUNT_9_DIVERSIFIED, QUOTE_USD, slice);
            uint256 used = g - gasleft();
            summed += used;
            console2.log("  slice gas", used, slice[0]);
        }
        console2.log("sum of singleton slices", summed);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _addressesOf(INAVCalculator.Asset[] memory assets) internal pure returns (address[] memory out) {
        out = new address[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            out[i] = assets[i].asset;
        }
    }

    function _concat(address[] memory a, address[] memory b) internal pure returns (address[] memory out) {
        out = new address[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            out[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            out[a.length + i] = b[i];
        }
    }

    function _contains(address[] memory haystack, address needle) internal pure returns (bool) {
        for (uint256 i = 0; i < haystack.length; i++) {
            if (haystack[i] == needle) return true;
        }
        return false;
    }

    /// @notice Asserts two address lists denote the same SET, ignoring order and repeats. Repeats are expected in
    ///         the union: two slices holding the same stale asset each report it, which is precisely why a
    ///         reassembler must de-duplicate and why this comparison must not be length-based.
    function _assertSameSet(address[] memory got, address[] memory want, string memory what) internal pure {
        for (uint256 i = 0; i < want.length; i++) {
            assertTrue(_contains(got, want[i]), string.concat(what, ": union is missing an asset"));
        }
        for (uint256 i = 0; i < got.length; i++) {
            assertTrue(_contains(want, got[i]), string.concat(what, ": union has an asset the complete read lacks"));
        }
    }
}
