// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Mock_CustomBalanceAdapter} from "test/mocks/balance_adapters.sol";

/// @title Paginated NAV read — unit tests
/// @notice Covers `getAccountNavForAdapters`: the three rejections that keep a silently-wrong slice from being
///         returned, the partition invariant on a controlled registry, and the fact that the health flags are
///         SLICE-LOCAL (the property a reassembler must union, and the one that silently loses signals if it
///         doesn't). The same partition invariant is pinned against the real mainnet registry in
///         test/integration/NAV.PaginatedNav.Mainnet.integration.fork.t.sol, and the gas-starvation exception to
///         it — the one case where the sums legitimately differ — in
///         test/nav/NAVCalculator.paginatedNav.starvation.t.sol.
/// @dev One property is deliberately NOT tested here because it cannot be: that a `PartialNAV` is not assignable
///      where a `NAV` is expected. That is a compile-time guarantee of the two structs being distinct types — a
///      test asserting it would have to fail to compile, so the guarantee is enforced by the type system and
///      documented on `INAVCalculator.PartialNAV` instead.
contract NAVCalculatorPaginatedNavTest is SuperTest {
    Mock_CustomBalanceAdapter internal adapterA;
    Mock_CustomBalanceAdapter internal adapterB;
    Mock_CustomBalanceAdapter internal adapterC;

    /// @notice An adapter that is never registered — the {AdapterNotRegistered} subject.
    Mock_CustomBalanceAdapter internal strangerAdapter;

    function setUp() public {
        setupAll();

        adapterA = new Mock_CustomBalanceAdapter();
        adapterB = new Mock_CustomBalanceAdapter();
        adapterC = new Mock_CustomBalanceAdapter();
        strangerAdapter = new Mock_CustomBalanceAdapter();

        // A: WETH credit. B: USDC credit + a WETH debt leg (so the partition test exercises sign netting across
        // slice boundaries, not just addition of positives). C: DAI only — DAI is the asset made stale below, so
        // staleness is reachable through exactly one adapter and is therefore provably slice-local.
        _wire(adapterA, address(weth), 3e18, false);
        _wire(adapterB, address(usdc), 50_000e6, false);
        _wire(adapterB, address(weth), 1e18, true);
        _wire(adapterC, address(dai), 25_000e18, false);

        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(_arr3(address(adapterA), address(adapterB), address(adapterC)));
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _wire(Mock_CustomBalanceAdapter adapter, address asset, uint256 amount, bool debt) internal {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        adapter.setUnderlyingAssetsSupported(assets);
        adapter.setBalance(asset, safe, amount, debt);
    }

    function _arr1(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _arr2(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
    }

    function _arr3(address a, address b, address c) internal pure returns (address[] memory out) {
        out = new address[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function _slice(address[] memory adapters) internal view returns (INAVCalculator.PartialNAV memory) {
        return nav.getAccountNavForAdapters(safe, address(0), adapters);
    }

    /// @notice Makes DAI — and ONLY DAI — stale, so staleness is reachable through exactly one adapter.
    /// @dev DAI is the sole asset registered with a finite heartbeat (86400s, via `Mock_PriceOracleChainlink`);
    ///      USDC, WETH and native ETH all use `type(uint256).max`, so warping past a day ages DAI out and leaves
    ///      the rest fresh. Warping rather than `daiAdapter.setUpdatedAt(1)`: the mock's `updatedAt` is stamped at
    ///      construction and `setupAll` only advances the clock 2 hours, so a rewritten `updatedAt` is still well
    ///      inside a 24-hour window and the feed stays fresh.
    function _staleDaiOnly() internal {
        vm.warp(block.timestamp + 2 days);
    }

    /// @notice Makes DAI — and ONLY DAI — `irregular`, by giving it a monitor feed that diverges from its primary
    ///         far beyond the configured tolerance.
    /// @dev Uses only the public MANAGER API. DAI's primary reads $1.00 and its price is fixed at construction, so
    ///      the divergence is created from the monitor side: a $0.90 monitor against a 1% tolerance is ~1000bps of
    ///      divergence. No other registered asset has a monitor feed or a divergence tolerance, so none of them can
    ///      be flagged irregular — which is what makes the slice-locality assertion meaningful.
    function _irregularDaiOnly() internal {
        Mock_PriceOracleChainlink monitor = new Mock_PriceOracleChainlink("DAI-monitor", 90_000_000, 8);
        vm.startPrank(navCalculatorManager);
        nav.setDivergenceTolerance(address(dai), 100); // 1%
        nav.addMonitorFeed(address(dai), address(monitor), IPrices.PriceType.Chainlink, type(uint256).max);
        vm.stopPrank();
    }

    function _append(address[] memory arr, address item) internal pure returns (address[] memory out) {
        out = new address[](arr.length + 1);
        for (uint256 i = 0; i < arr.length; i++) {
            out[i] = arr[i];
        }
        out[arr.length] = item;
    }

    function _contains(address[] memory haystack, address needle) internal pure returns (bool) {
        for (uint256 i = 0; i < haystack.length; i++) {
            if (haystack[i] == needle) return true;
        }
        return false;
    }

    // -----------------------------------------------------------------------
    // Rejections — each of these, if answered instead of reverted, returns a
    // well-formed slice whose `value` is silently wrong.
    // -----------------------------------------------------------------------

    function test_revertsOnEmptySlice() public {
        vm.expectRevert(INAVCalculator.EmptyAdapterSlice.selector);
        nav.getAccountNavForAdapters(safe, address(0), new address[](0));
    }

    function test_revertsOnUnregisteredAdapter() public {
        vm.expectRevert(abi.encodeWithSelector(INAVCalculator.AdapterNotRegistered.selector, address(strangerAdapter)));
        nav.getAccountNavForAdapters(safe, address(0), _arr1(address(strangerAdapter)));
    }

    /// @notice An unregistered adapter is rejected even when the rest of the slice is valid — the check is
    ///         per-element, not "at least one registered adapter present".
    function test_revertsOnUnregisteredAdapterMixedWithValidOnes() public {
        vm.expectRevert(abi.encodeWithSelector(INAVCalculator.AdapterNotRegistered.selector, address(strangerAdapter)));
        nav.getAccountNavForAdapters(safe, address(0), _arr2(address(adapterA), address(strangerAdapter)));
    }

    /// @notice An adapter REMOVED from the registry stops being a valid slice member immediately. This is the case
    ///         that motivates rejecting rather than skipping: a paging caller holding a cached adapter list across
    ///         a governance removal must be told, not handed a zero-valued slice for it.
    function test_revertsOnAdapterRemovedFromRegistry() public {
        vm.prank(navCalculatorManager);
        nav.removeBalanceAdapters(_arr1(address(adapterC)));

        vm.expectRevert(abi.encodeWithSelector(INAVCalculator.AdapterNotRegistered.selector, address(adapterC)));
        nav.getAccountNavForAdapters(safe, address(0), _arr1(address(adapterC)));
    }

    function test_revertsOnDuplicateAdapter() public {
        vm.expectRevert(abi.encodeWithSelector(INAVCalculator.DuplicateAdapterInSlice.selector, address(adapterA)));
        nav.getAccountNavForAdapters(safe, address(0), _arr2(address(adapterA), address(adapterA)));
    }

    /// @notice A duplicate is caught even when it is not adjacent, and the error names the repeated address.
    function test_revertsOnNonAdjacentDuplicate() public {
        vm.expectRevert(abi.encodeWithSelector(INAVCalculator.DuplicateAdapterInSlice.selector, address(adapterA)));
        nav.getAccountNavForAdapters(safe, address(0), _arr3(address(adapterA), address(adapterB), address(adapterA)));
    }

    /// @notice The quote asset is validated exactly as on {getAccountNav} — an unpriced quote cannot yield a slice
    ///         denominated in it.
    function test_revertsOnUnpricedQuoteAsset() public {
        address unpriced = makeAddr("unpriced");
        vm.expectRevert(abi.encodeWithSelector(PriceFeedNotSet.selector, unpriced));
        nav.getAccountNavForAdapters(safe, unpriced, _arr1(address(adapterA)));
    }

    // -----------------------------------------------------------------------
    // The slice itself
    // -----------------------------------------------------------------------

    /// @notice A single-adapter slice values that adapter and nothing else, and reports exactly it as covered.
    function test_singleAdapterSlice() public view {
        INAVCalculator.PartialNAV memory p = _slice(_arr1(address(adapterA)));

        assertEq(p.adaptersCovered.length, 1, "one adapter covered");
        assertEq(p.adaptersCovered[0], address(adapterA), "covered is the one asked for");
        assertEq(p.quoteAsset.asset, address(0), "USD quote");
        assertEq(p.timestamp, uint64(block.timestamp), "slice is stamped with this block");

        // A holds 3 WETH at 3240.57 USD => 9721.71 USD at 8dp.
        assertEq(p.value, 3 * 324_057_000_000, "adapter A's WETH leg only");
    }

    /// @notice `adaptersCovered` preserves the supplied order, so a reassembler can correlate it positionally with
    ///         the list it sent.
    function test_adaptersCoveredPreservesOrder() public view {
        INAVCalculator.PartialNAV memory p = _slice(_arr3(address(adapterC), address(adapterA), address(adapterB)));

        assertEq(p.adaptersCovered.length, 3);
        assertEq(p.adaptersCovered[0], address(adapterC));
        assertEq(p.adaptersCovered[1], address(adapterA));
        assertEq(p.adaptersCovered[2], address(adapterB));
    }

    /// @notice A slice covering an adapter with no positions for this account is a legitimate zero — the adapter is
    ///         registered, so this is "nothing here", not "unknown".
    function test_sliceWithNoPositionsIsZero() public {
        INAVCalculator.PartialNAV memory p =
            nav.getAccountNavForAdapters(makeAddr("empty-account"), address(0), _arr1(address(adapterA)));
        assertEq(p.value, 0);
        assertEq(p.adaptersCovered.length, 1);
    }

    // -----------------------------------------------------------------------
    // The partition invariant
    // -----------------------------------------------------------------------

    /// @notice THE load-bearing property, on a controlled registry: summing `value` over a disjoint partition that
    ///         covers every registered adapter reproduces `getAccountNav().value` exactly. Includes a debt leg, so
    ///         this also pins that debt nets across a slice boundary rather than only within one.
    function test_partitionSumsToCompleteNav() public view {
        INAVCalculator.NAV memory complete = nav.getAccountNav(safe, address(0));
        address[] memory all = nav.getAllAdapters();
        assertGt(all.length, 1, "need several adapters for a partition to mean anything");

        // Partition into singletons — the finest partition available, and the worst case for any per-slice
        // constant leaking into the sum.
        int256 summed;
        uint256 coveredCount;
        for (uint256 i = 0; i < all.length; i++) {
            INAVCalculator.PartialNAV memory p = _slice(_arr1(all[i]));
            summed += p.value;
            coveredCount += p.adaptersCovered.length;
            assertEq(p.timestamp, complete.timestamp, "same block for every slice");
            assertEq(p.sequencerDown, complete.sequencerDown, "sequencer flag is not slice-dependent");
            assertEq(p.quoteAssetStale, complete.quoteAssetStale, "quote staleness is not slice-dependent");
        }

        assertEq(coveredCount, all.length, "partition covers the registry exactly once");
        assertEq(summed, complete.value, "sum of slices == complete NAV, exactly");
    }

    /// @notice The same invariant under an UNEVEN partition (a 2-slice split at an arbitrary point), which is what
    ///         a real pager produces. Singleton slices could hide an error that only appears when one slice holds
    ///         several adapters.
    function test_unevenPartitionSumsToCompleteNav() public view {
        INAVCalculator.NAV memory complete = nav.getAccountNav(safe, address(0));
        address[] memory all = nav.getAllAdapters();

        uint256 split = all.length / 2;
        address[] memory first = new address[](split);
        address[] memory second = new address[](all.length - split);
        for (uint256 i = 0; i < split; i++) {
            first[i] = all[i];
        }
        for (uint256 i = split; i < all.length; i++) {
            second[i - split] = all[i];
        }

        INAVCalculator.PartialNAV memory p1 = _slice(first);
        INAVCalculator.PartialNAV memory p2 = _slice(second);

        assertEq(p1.adaptersCovered.length + p2.adaptersCovered.length, all.length, "full coverage");
        assertEq(p1.value + p2.value, complete.value, "two uneven slices sum to the complete NAV");
    }

    /// @notice A partition that OMITS one adapter must be detectable from `adaptersCovered` — not merely from the
    ///         value, which is a plausible number either way. This is the gap-detection contract.
    function test_omittedAdapterIsDetectableFromCoverage() public view {
        INAVCalculator.NAV memory complete = nav.getAccountNav(safe, address(0));
        address[] memory all = nav.getAllAdapters();

        // Drop adapterA from the paging plan — the mistake a reassembler must catch.
        address[] memory covered = new address[](0);
        int256 summed;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i] == address(adapterA)) continue;
            INAVCalculator.PartialNAV memory p = _slice(_arr1(all[i]));
            summed += p.value;
            address[] memory grown = new address[](covered.length + 1);
            for (uint256 j = 0; j < covered.length; j++) {
                grown[j] = covered[j];
            }
            grown[covered.length] = p.adaptersCovered[0];
            covered = grown;
        }

        assertEq(covered.length, all.length - 1, "coverage is detectably one adapter short");
        assertFalse(_contains(covered, address(adapterA)), "and names which one is missing");
        assertTrue(summed != complete.value, "the short sum differs from the complete NAV");
        assertEq(complete.value - summed, 3 * 324_057_000_000, "short by exactly adapter A's value");
    }

    // -----------------------------------------------------------------------
    // Health flags are SLICE-LOCAL — the reassembly hazard
    // -----------------------------------------------------------------------

    /// @notice `stalePriceAssets` is restricted to the assets the SCANNED adapters touched. The slice that does not
    ///         hold the stale asset reports a clean array, and a reassembler reading only that slice would lose the
    ///         staleness signal entirely. The union recovers it.
    function test_stalePriceAssetsAreSliceLocalAndUnionRecoversThem() public {
        _staleDaiOnly();

        INAVCalculator.NAV memory complete = nav.getAccountNav(safe, address(0));
        assertEq(complete.stalePriceAssets.length, 1, "complete read sees DAI stale");
        assertEq(complete.stalePriceAssets[0].asset, address(dai));

        INAVCalculator.PartialNAV memory withStale = _slice(_arr1(address(adapterC)));
        INAVCalculator.PartialNAV memory withoutStale = _slice(_arr1(address(adapterA)));

        assertEq(withStale.stalePriceAssets.length, 1, "the slice holding DAI reports it");
        assertEq(withStale.stalePriceAssets[0].asset, address(dai));

        // The signal is ABSENT here, not merely different. This assertion is the documented hazard, pinned: a
        // caller that checked flags on this slice alone would conclude the portfolio has no stale prices.
        assertEq(withoutStale.stalePriceAssets.length, 0, "a slice not holding DAI reports nothing stale");

        // Union across the full partition recovers exactly the complete read's SET.
        //
        // Compared as a set, deliberately, and NOT by counting entries. Two adapters that both touch one stale
        // asset each report it, so the concatenation legitimately contains duplicates — that is precisely why the
        // documented rule is "union, de-duplicated". An entry-count assertion would encode the opposite rule; it
        // would pass here only because this fixture happens to reach DAI through exactly one adapter, and would
        // start failing the moment a second DAI-touching adapter existed — accusing the slice of inventing a stale
        // asset while it behaved exactly as specified.
        address[] memory all = nav.getAllAdapters();
        address[] memory union = new address[](0);
        for (uint256 i = 0; i < all.length; i++) {
            INAVCalculator.PartialNAV memory p = _slice(_arr1(all[i]));
            for (uint256 j = 0; j < p.stalePriceAssets.length; j++) {
                union = _append(union, p.stalePriceAssets[j].asset);
            }
        }
        assertTrue(_contains(union, address(dai)), "union over the partition recovers the stale asset");
        for (uint256 i = 0; i < union.length; i++) {
            bool inComplete;
            for (uint256 j = 0; j < complete.stalePriceAssets.length; j++) {
                if (complete.stalePriceAssets[j].asset == union[i]) inComplete = true;
            }
            assertTrue(inComplete, "the union introduces no asset the complete read did not report");
        }
        for (uint256 j = 0; j < complete.stalePriceAssets.length; j++) {
            assertTrue(
                _contains(union, complete.stalePriceAssets[j].asset), "the union loses no asset the complete read had"
            );
        }
    }

    /// @notice The `irregularPriceAssets` half of the flag-union contract, which `stalePriceAssets` coverage above
    ///         does not imply: `_buildStaleAssets` and `_buildIrregularAssets` are independent functions in
    ///         PriceFeedLib, and a change that scoped the irregular list from the asset registry rather than from
    ///         the slice-local price-feed cache would silently alter what a slice reports as depegged while every
    ///         staleness assertion here still passed. Depeg is the signal this repo's `irregular` work exists to
    ///         surface, so it gets its own pin.
    function test_irregularPriceAssetsAreSliceLocalAndUnionRecoversThem() public {
        _irregularDaiOnly();

        INAVCalculator.NAV memory complete = nav.getAccountNav(safe, address(0));
        assertEq(complete.irregularPriceAssets.length, 1, "complete read sees DAI irregular");
        assertEq(complete.irregularPriceAssets[0].asset, address(dai));

        // Slice-local: the adapter holding DAI reports it, the one that does not reports nothing.
        INAVCalculator.PartialNAV memory withIrregular = _slice(_arr1(address(adapterC)));
        INAVCalculator.PartialNAV memory withoutIrregular = _slice(_arr1(address(adapterA)));

        assertEq(withIrregular.irregularPriceAssets.length, 1, "the slice holding DAI reports it irregular");
        assertEq(withIrregular.irregularPriceAssets[0].asset, address(dai));
        assertEq(withoutIrregular.irregularPriceAssets.length, 0, "a slice not holding DAI reports nothing irregular");

        // And the DE-DUPLICATED union over the partition recovers exactly the complete read's set.
        //
        // `rawHits > dedupedCount` is the load-bearing assertion here, not decoration: it proves the documented
        // de-duplication obligation is real rather than theoretical, by showing the raw concatenation genuinely
        // over-counts. To make that reachable, DAI is deliberately held through TWO adapters below, so two slices
        // each report it. Without a second holder the raw and de-duplicated unions coincide and the assertion
        // would be vacuous.
        Mock_CustomBalanceAdapter secondDaiHolder = new Mock_CustomBalanceAdapter();
        _wire(secondDaiHolder, address(dai), 1_000e18, false);
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(_arr1(address(secondDaiHolder)));

        address[] memory all = nav.getAllAdapters();
        address[] memory seen = new address[](0);
        uint256 rawHits;
        for (uint256 i = 0; i < all.length; i++) {
            INAVCalculator.PartialNAV memory p = _slice(_arr1(all[i]));
            for (uint256 j = 0; j < p.irregularPriceAssets.length; j++) {
                rawHits++;
                if (!_contains(seen, p.irregularPriceAssets[j].asset)) {
                    seen = _append(seen, p.irregularPriceAssets[j].asset);
                }
            }
        }
        assertEq(seen.length, 1, "de-duplicated union has exactly the complete read's cardinality");
        assertEq(seen[0], address(dai), "and it is the same asset");
        assertGt(rawHits, seen.length, "the RAW union over-counts - the de-duplication obligation is load-bearing");
    }

    /// @notice Makes DAI's — and only DAI's — monitor set entirely UNREADABLE, while leaving DAI's own primary fresh.
    /// @dev A Chainlink monitor registered with a 1-second heartbeat goes stale as soon as any time passes, so
    ///      `_readFeedPrice` rejects it and `healthyMonitors` is 0. The 10-second warp is far inside DAI's primary
    ///      86400s window, so the primary stays usable — which is required, since `monitorsUnhealthy` is only set for
    ///      a USABLE primary (otherwise the suppression is the primary's fault, not the monitors').
    function _deadMonitorsDaiOnly() internal {
        Mock_PriceOracleChainlink deadMonitor = new Mock_PriceOracleChainlink("DAI-dead-monitor", 100_000_000, 8);
        vm.startPrank(navCalculatorManager);
        nav.setDivergenceTolerance(address(dai), 100);
        nav.addMonitorFeed(address(dai), address(deadMonitor), IPrices.PriceType.Chainlink, 1);
        vm.stopPrank();
        vm.warp(block.timestamp + 10);
    }

    /// @notice The `monitorsUnhealthyPriceAssets` third of the flag-union contract. `stalePriceAssets` and
    ///         `irregularPriceAssets` coverage above does not imply it: `_buildMonitorsUnhealthyAssets` is a third
    ///         independent function in PriceFeedLib, and a change that scoped it from the asset registry rather than
    ///         from the slice-local price-feed cache would silently alter what a slice reports as unchecked while
    ///         every staleness and depeg assertion here still passed. This array is the one that distinguishes
    ///         "checked and clean" from "checked by nothing that answered", so it gets its own pin.
    function test_monitorsUnhealthyAssetsAreSliceLocalAndUnionRecoversThem() public {
        _deadMonitorsDaiOnly();

        INAVCalculator.NAV memory complete = nav.getAccountNav(safe, address(0));
        assertEq(complete.monitorsUnhealthyPriceAssets.length, 1, "complete read sees DAI's monitors all unreadable");
        assertEq(complete.monitorsUnhealthyPriceAssets[0].asset, address(dai));
        assertEq(complete.irregularPriceAssets.length, 0, "and it is NOT irregular: the divergence check never ran");

        // Slice-local: the adapter holding DAI reports it, the one that does not reports nothing. This is the
        // assertion that fails if the array is ever scoped from the registry instead of the slice's own cache.
        INAVCalculator.PartialNAV memory withDai = _slice(_arr1(address(adapterC)));
        INAVCalculator.PartialNAV memory withoutDai = _slice(_arr1(address(adapterA)));
        assertEq(withDai.monitorsUnhealthyPriceAssets.length, 1, "the slice holding DAI reports it");
        assertEq(withDai.monitorsUnhealthyPriceAssets[0].asset, address(dai));
        assertEq(withoutDai.monitorsUnhealthyPriceAssets.length, 0, "a slice not holding DAI reports nothing");

        // De-duplicated union over the partition recovers exactly the complete read's set, and the RAW union
        // over-counts — so the documented de-duplication obligation is load-bearing here too, not decoration.
        Mock_CustomBalanceAdapter secondDaiHolder = new Mock_CustomBalanceAdapter();
        _wire(secondDaiHolder, address(dai), 1_000e18, false);
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(_arr1(address(secondDaiHolder)));

        address[] memory all = nav.getAllAdapters();
        address[] memory seen = new address[](0);
        uint256 rawHits;
        for (uint256 i = 0; i < all.length; i++) {
            INAVCalculator.PartialNAV memory p = _slice(_arr1(all[i]));
            for (uint256 j = 0; j < p.monitorsUnhealthyPriceAssets.length; j++) {
                rawHits++;
                if (!_contains(seen, p.monitorsUnhealthyPriceAssets[j].asset)) {
                    seen = _append(seen, p.monitorsUnhealthyPriceAssets[j].asset);
                }
            }
        }
        assertEq(seen.length, 1, "de-duplicated union has exactly the complete read's cardinality");
        assertEq(seen[0], address(dai), "and it is the same asset");
        assertGt(rawHits, seen.length, "the RAW union over-counts - the de-duplication obligation is load-bearing");
    }

    /// @notice A stale price does not stop a slice from being returned — it is reported alongside a value, exactly
    ///         as the complete read does. Pinned so the flag can never be mistaken for a rejection.
    function test_staleSliceStillReturnsAValue() public {
        _staleDaiOnly();
        INAVCalculator.PartialNAV memory p = _slice(_arr1(address(adapterC)));
        assertEq(p.stalePriceAssets.length, 1);
        assertEq(p.value, 0, "a stale asset prices at 0 in the slice, as in the complete read");
    }
}
