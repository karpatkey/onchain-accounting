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
///      **Coverage, stated honestly — AS MEASURED, NOT MAINTAINED: this harness registered 41 assets and 21
///      adapters when these figures were taken. The mainnet deploy config carried 42 assets / 27 adapters
///      then and carries 43 / 28 after PR #308 — MEASURED both sides; an earlier revision paired 43 with
///      27, which is true of no tree.** Both
///      sides move as the registry grows — PR #308 adds a Symbiotic meta-adapter AND the wARS asset, so
///      it moves the adapter axis and the asset axis both. Treat these as descriptive of the run they
///      were measured in; the policy on why they are not asserted is stated once, below.
///
///      The six it skips are the ones whose deploy type the harness does not know
///      (`EthenaCooldown`, `LidoWithdrawalQueue`, `EulerVaultsMeta`, and the three assisted adapters). So the
///      invariant is NOT exercised over those six, and an adapter whose behaviour differs under a one-adapter slice
///      would ship unverified. Do not read this file as proving the whole production registry.
///
///      The six-adapter GAP is asserted by name in `test_harnessCoverageGapIsWhatTheDocblockClaims`, so that claim
///      cannot silently rot. The counts (41/21) are descriptive only and deliberately NOT pinned: asserting them
///      coupled this suite to the mainnet asset config, where adding one asset reddened it with a message about a
///      docblock.
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

    /// @notice Pins the harness's coverage GAP — the six adapters it cannot build — rather than an absolute count.
    /// @dev An earlier version asserted `getAssetCount() == 41` and `getAllAdapters().length == 21`. That coupled a
    ///      paginated-NAV test to the mainnet deploy config: adding one asset to
    ///      `script/config/nav-config/assets-and-price-feeds/1.json` — routine ops, no Solidity touched — turned this
    ///      suite red on whatever branch happened to be open, with a message about a docblock. Wrong tripwire.
    ///
    ///      What the docblock actually claims is the SHAPE of the gap: the harness builds every enabled adapter
    ///      except the six whose deploy type it does not know. That is what is asserted here, so the test fails when
    ///      the gap changes (a skipped type becomes recognised, or a new one appears) and stays green when unrelated
    ///      config grows. A lower bound is kept on the counts purely so a wholesale collapse of the harness cannot
    ///      pass unnoticed.
    function test_harnessCoverageGapIsWhatTheDocblockClaims() public view {
        address[] memory all = nav.getAllAdapters();

        // The gap, by name. These are absent because IntegrationFromConfigBase has no deploy branch for them.
        string[6] memory skipped = [
            "EthenaCooldown",
            "LidoWithdrawalQueue",
            "EulerVaultsMeta",
            "EtherFiWithdrawalQueueAssisted",
            "NexusMutualStakingPoolsAssisted",
            "StakeWiseV3ExitQueueAssisted"
        ];
        for (uint256 i = 0; i < skipped.length; i++) {
            assertFalse(
                _harnessBuilt(skipped[i]),
                string.concat(
                    "harness now builds ", skipped[i], " - the coverage caveat in the docblock is stale, update it"
                )
            );
        }

        // Sanity floor only, deliberately NOT an equality: enough registry to make a partition meaningful.
        assertGt(all.length, 15, "harness registry collapsed - partition tests would be near-trivial");
        assertGt(nav.getAssetCount(), 30, "harness asset registry collapsed");
    }

    /// @notice Whether the harness deployed an adapter under this config name.
    function _harnessBuilt(string memory name) internal view returns (bool) {
        for (uint256 i = 0; i < _deployedBalanceAdapterNames.length; i++) {
            if (keccak256(bytes(_deployedBalanceAdapterNames[i])) == keccak256(bytes(name))) return true;
        }
        return false;
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
        // Counts slices that actually contributed value. `complete.value != 0` alone does NOT close vacuity: if all
        // the value sits behind ONE adapter, every other slice returns 0, the sum is `x + 0 + 0 + ... = x`, and the
        // invariant is satisfied trivially without ever testing that contributions COMBINE across slices. Asserted
        // below. This also replaces a `getAccountPositions()` call the previous guard made purely to count
        // positions - a second full 21-adapter scan per test, for less information than this.
        uint256 nonZeroSlices;
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
            if (p.value != 0) nonZeroSlices++;
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

        assertGt(nonZeroSlices, 1, "value must be spread over >1 slice or the partition proves nothing about summing");

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
