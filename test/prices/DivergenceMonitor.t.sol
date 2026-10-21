// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Mock_CustomPriceFeed, Mock_CustomPriceFeedStaled} from "test/mocks/price_oracles.sol";

/// @title Divergence-monitor unit tests
/// @notice Exercises the primary-vs-monitor divergence signal on NAVCalculator: `getPriceData(...).irregular`,
///         `divergenceBps`, `monitorFeedCount`, the NAV `irregularPriceAssets` array, `healthCheck`, the stablecoin
///         peg guard, and the MANAGER-gated monitor/metadata mutators. Primary pricing is unaffected (still the
///         single pricing feed); monitors only feed the divergence check.
contract DivergenceMonitorTest is SuperTest {
    function setUp() public {
        setupAll();
    }

    /// @dev weth primary = wethAdapter (Custom, $3240.57). Attach a Custom monitor at a chosen price (MANAGER-gated).
    function _attachWethMonitor(uint256 monitorPrice8, uint32 toleranceBps) internal returns (Mock_CustomPriceFeed) {
        Mock_CustomPriceFeed monitor = new Mock_CustomPriceFeed("WETH-monitor", address(weth), monitorPrice8, 8);
        vm.startPrank(navCalculatorManager);
        nav.setDivergenceTolerance(address(weth), toleranceBps);
        nav.addMonitorFeed(address(weth), address(monitor), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
        return monitor;
    }

    function test_noMonitor_notIrregular() public view {
        INAVCalculator.PriceFeedData memory pd = nav.getPriceData(address(weth));
        assertFalse(pd.irregular);
        assertEq(pd.divergenceBps, 0);
        assertEq(pd.monitorFeedCount, 0);
    }

    function test_monitorInBand_notIrregular() public {
        // primary $3240.57, monitor $3250 -> ~29 bps, within 250 bps tolerance.
        _attachWethMonitor(325_000_000_000, 250);
        INAVCalculator.PriceFeedData memory pd = nav.getPriceData(address(weth));
        assertEq(pd.monitorFeedCount, 1);
        assertGt(pd.divergenceBps, 0);
        assertLt(pd.divergenceBps, 250);
        assertFalse(pd.irregular, "in-band must not be irregular");
    }

    function test_monitorOutOfBand_irregular() public {
        // primary $3240.57, monitor $3400 -> ~492 bps, beyond 250 bps tolerance.
        _attachWethMonitor(340_000_000_000, 250);
        INAVCalculator.PriceFeedData memory pd = nav.getPriceData(address(weth));
        assertEq(pd.monitorFeedCount, 1);
        assertGt(pd.divergenceBps, 250);
        assertTrue(pd.irregular, "out-of-band must be irregular");
        // primary price itself is unchanged (divergence is a signal, not a re-price).
        assertEq(pd.price, 324_057_000_000);
        assertFalse(pd.stale);
    }

    function test_navAndHealthCheck_surfaceIrregularAsset() public {
        _attachWethMonitor(340_000_000_000, 250);
        // Give the safe a WETH position so weth is an asset-with-position in the NAV read.
        weth.mint(address(safe), 1 ether);

        INAVCalculator.NAV memory r = nav.getAccountNav(address(safe), address(0));
        bool found;
        for (uint256 i = 0; i < r.irregularPriceAssets.length; i++) {
            if (r.irregularPriceAssets[i].asset == address(weth)) found = true;
        }
        assertTrue(found, "NAV.irregularPriceAssets must contain weth");

        (,, address[] memory irregular) = nav.healthCheck();
        bool foundHc;
        for (uint256 i = 0; i < irregular.length; i++) {
            if (irregular[i] == address(weth)) foundHc = true;
        }
        assertTrue(foundHc, "healthCheck must report weth irregular");
    }

    function test_stablecoinPegGuard() public {
        // usdc primary = usdcAdapter (Custom, settable). A non-zero peg tolerance enables the $1 guard.
        vm.prank(navCalculatorManager);
        nav.setPegTolerance(address(usdc), 100);
        usdcAdapter.setPrice(103_000_000); // $1.03, 8 decimals

        INAVCalculator.PriceFeedData memory pd = nav.getPriceData(address(usdc));
        assertTrue(pd.irregular, "peg deviation beyond tolerance must be irregular");

        // Back within band -> not irregular.
        usdcAdapter.setPrice(100_500_000); // $1.005 -> 50 bps < 100
        pd = nav.getPriceData(address(usdc));
        assertFalse(pd.irregular, "within peg band must not be irregular");
    }

    function test_addMonitorFeed_requiresToleranceFirst() public {
        Mock_CustomPriceFeed monitor = new Mock_CustomPriceFeed("m", address(weth), 324_000_000_000, 8);
        vm.prank(navCalculatorManager);
        vm.expectRevert(abi.encodeWithSelector(IPrices.DivergenceToleranceRequired.selector, address(weth)));
        nav.addMonitorFeed(address(weth), address(monitor), IPrices.PriceType.Custom, type(uint256).max);
    }

    /// @notice A Custom MONITOR feed is asset-bound too: `addMonitorFeed` runs the same validator as the primary path,
    ///         so a monitor that prices a different asset is rejected. This is the likelier of the two crossings in
    ///         practice — every `*CrossRate` instance is a monitor, and their config keys sit next to the primaries'.
    function test_RevertIf_addMonitorFeed_customFeedPricesDifferentAsset() public {
        Mock_CustomPriceFeed wrongAsset = new Mock_CustomPriceFeed("usdc-monitor", address(usdc), 100_000_000, 8);
        vm.prank(navCalculatorManager);
        nav.setDivergenceTolerance(address(weth), 250);

        vm.prank(navCalculatorManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPrices.CustomFeedAssetMismatch.selector, address(weth), address(wrongAsset), address(usdc)
            )
        );
        nav.addMonitorFeed(address(weth), address(wrongAsset), IPrices.PriceType.Custom, type(uint256).max);
    }

    function test_setDivergenceTolerance_rejectsOutOfRange() public {
        vm.prank(navCalculatorManager);
        vm.expectRevert(abi.encodeWithSelector(IPrices.InvalidTolerance.selector, uint32(0)));
        nav.setDivergenceTolerance(address(weth), 0);

        vm.prank(navCalculatorManager);
        vm.expectRevert(abi.encodeWithSelector(IPrices.InvalidTolerance.selector, uint32(10_001)));
        nav.setDivergenceTolerance(address(weth), 10_001);
    }

    function test_removeMonitorFeed() public {
        Mock_CustomPriceFeed monitor = _attachWethMonitor(340_000_000_000, 250);
        assertEq(nav.getMonitorFeedCount(address(weth)), 1);
        vm.prank(navCalculatorManager);
        nav.removeMonitorFeed(address(weth), address(monitor));
        assertEq(nav.getMonitorFeedCount(address(weth)), 0);
        INAVCalculator.PriceFeedData memory pd = nav.getPriceData(address(weth));
        assertFalse(pd.irregular, "no monitors -> not irregular");
    }

    function test_latestPrice_surfacesIrregular() public {
        // No monitor yet -> latestPrice reports not-irregular.
        (,,, bool before) = nav.latestPrice(address(weth));
        assertFalse(before);

        _attachWethMonitor(340_000_000_000, 250); // ~492 bps out of band
        (int256 price, uint8 decimals, bool stale, bool irregular) = nav.latestPrice(address(weth));
        assertEq(price, 324_057_000_000, "price still the primary");
        assertEq(decimals, 8);
        assertFalse(stale);
        assertTrue(irregular, "latestPrice must surface irregular (parity with getPriceData)");
    }

    function test_getPriceDivergence_view() public {
        _attachWethMonitor(340_000_000_000, 250); // monitor $3400 > primary $3240.57
        (
            int256 primaryPrice,
            int256 monitorMedian,
            uint256 divergenceBps,
            bool irregular,
            uint256 monitorFeedCount,
            bool primaryStale,
            bool primaryAboveMonitors
        ) = nav.getPriceDivergence(address(weth));
        assertEq(primaryPrice, 324_057_000_000);
        assertEq(monitorMedian, 340_000_000_000); // single monitor -> median is that monitor
        assertGt(divergenceBps, 250);
        assertTrue(irregular);
        assertEq(monitorFeedCount, 1);
        assertFalse(primaryStale);
        assertFalse(primaryAboveMonitors, "primary ($3240) is below the monitor ($3400)");
    }

    /// @dev Two monitors straddling the primary: their mean (and median) equals the primary, so a mean-based check
    ///      sees ~0 divergence and misses it. The worst-case check flags because each monitor is 400 bps away.
    function test_worstCase_catchesStraddle() public {
        vm.startPrank(navCalculatorManager);
        nav.setDivergenceTolerance(address(weth), 250);
        // primary = 324_057_000_000; ±4% = ±12_962_280_000 → mean == primary exactly.
        Mock_CustomPriceFeed hi = new Mock_CustomPriceFeed("hi", address(weth), 337_019_280_000, 8);
        Mock_CustomPriceFeed lo = new Mock_CustomPriceFeed("lo", address(weth), 311_094_720_000, 8);
        nav.addMonitorFeed(address(weth), address(hi), IPrices.PriceType.Custom, type(uint256).max);
        nav.addMonitorFeed(address(weth), address(lo), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        (, int256 monitorMedian, uint256 divergenceBps, bool irregular, uint256 count,,) =
            nav.getPriceDivergence(address(weth));
        assertEq(count, 2);
        assertEq(monitorMedian, 324_057_000_000, "median of the straddle == primary (a mean check would clear)");
        assertApproxEqAbs(divergenceBps, 400, 1, "worst-case single-monitor deviation");
        assertTrue(irregular, "worst-case must flag the straddle a mean/median check would miss");
    }

    function test_direction_primaryAboveMonitors() public {
        _attachWethMonitor(310_000_000_000, 250); // monitor $3100 < primary $3240.57
        (,,,,,, bool primaryAboveMonitors) = nav.getPriceDivergence(address(weth));
        assertTrue(primaryAboveMonitors, "primary ($3240) is above the monitor ($3100)");
    }

    /// @dev Regression (overflow hardening): a monitor reporting an extreme price near int256.max must NOT overflow
    ///      the worst-case bps math (uint256(d) * 10_000) and revert the NAV read — it uses Math.mulDiv now. The
    ///      monitor is wildly out of band, so the asset flags irregular; the primary price is untouched.
    function test_extremeMonitorPrice_noOverflowRevert() public {
        _attachWethMonitor(uint256(type(int256).max), 250);
        INAVCalculator.PriceFeedData memory pd = nav.getPriceData(address(weth)); // must not revert
        assertEq(pd.monitorFeedCount, 1);
        assertTrue(pd.irregular, "extreme monitor is out of band");
        assertEq(pd.price, 324_057_000_000, "primary price unchanged (divergence is a signal, not a re-price)");
        assertFalse(pd.stale);
    }

    /// @dev Regression (peg-guard overflow): an extreme primary price must NOT overflow the peg bps math and revert.
    function test_extremePegPrice_noOverflowRevert() public {
        vm.prank(navCalculatorManager);
        nav.setPegTolerance(address(usdc), 100);
        usdcAdapter.setPrice(uint256(type(int256).max)); // absurd $ far beyond the $1 peg
        INAVCalculator.PriceFeedData memory pd = nav.getPriceData(address(usdc)); // must not revert
        assertTrue(pd.irregular, "extreme peg deviation must flag irregular");
    }

    /// @dev A stale monitor is skipped: it neither contributes to monitorFeedCount nor to the divergence check.
    function test_staleMonitor_excluded() public {
        _attachWethMonitor(340_000_000_000, 250); // tolerance + 1 healthy, out-of-band monitor
        Mock_CustomPriceFeedStaled staleMon =
            new Mock_CustomPriceFeedStaled("stale-mon", address(weth), 999_000_000_000, 8);
        vm.prank(navCalculatorManager);
        nav.addMonitorFeed(address(weth), address(staleMon), IPrices.PriceType.Custom, type(uint256).max);

        INAVCalculator.PriceFeedData memory pd = nav.getPriceData(address(weth));
        assertEq(pd.monitorFeedCount, 1, "stale monitor must be excluded from the healthy count");
        assertTrue(pd.irregular, "the healthy monitor is still out of band");
    }

    /// @dev An UNUSABLE primary suppresses the divergence check: with no primary price at all there is nothing to
    ///      compare the monitors against, so `irregular` stays false and `monitorFeedCount`/`divergenceBps` stay 0.
    ///      (Mock_CustomPriceFeedStaled is stale AND rate-only, which ADR 0029 classes as unusable.)
    function test_unusablePrimary_suppressesIrregular() public {
        Mock_CustomPriceFeedStaled stalePrimary =
            new Mock_CustomPriceFeedStaled("weth-stale-primary", address(weth), 324_057_000_000, 8);
        Mock_CustomPriceFeed monitor = new Mock_CustomPriceFeed("weth-mon", address(weth), 340_000_000_000, 8);
        vm.startPrank(navCalculatorManager);
        nav.addOrModifyPriceFeed(address(weth), address(stalePrimary), IPrices.PriceType.Custom, type(uint256).max);
        nav.removePriceFeed(address(weth), address(wethAdapter));
        nav.setDivergenceTolerance(address(weth), 250);
        // Out of band ($3400 vs $3240.57 ~492 bps) — would flag irregular against a usable primary.
        nav.addMonitorFeed(address(weth), address(monitor), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        INAVCalculator.PriceFeedData memory pd = nav.getPriceData(address(weth));
        assertTrue(pd.stale, "primary is stale");
        assertEq(pd.price, 0, "and unusable: no price");
        assertFalse(pd.irregular, "divergence must be suppressed when the primary has no price");
        assertEq(pd.monitorFeedCount, 0, "no monitor contributes against an unusable primary");
        assertEq(pd.divergenceBps, 0);
        (int256 primaryPrice,,, bool irregular,, bool primaryStale,) = nav.getPriceDivergence(address(weth));
        assertEq(primaryPrice, 0);
        assertTrue(primaryStale);
        assertFalse(irregular);
    }

    /// @dev Test 8 (ADR 0029) — a USABLE STALE primary is still compared against the fresh monitors: a frozen feed
    ///      that drifted from the market raises `irregular` alongside `stale`, and every surface reports the stale
    ///      price (not 0) as the primary. Was: suppressed, `primaryPrice == 0`.
    function test_stalePrimary_stillCheckedAgainstMonitors() public {
        Mock_PriceOracleChainlink primary = new Mock_PriceOracleChainlink("weth-cl", 324_057_000_000, 8);
        Mock_CustomPriceFeed monitor = new Mock_CustomPriceFeed("weth-mon", address(weth), 340_000_000_000, 8);
        vm.startPrank(navCalculatorManager);
        nav.addOrModifyPriceFeed(address(weth), address(primary), IPrices.PriceType.Chainlink, 100);
        nav.removePriceFeed(address(weth), address(wethAdapter));
        nav.setDivergenceTolerance(address(weth), 250);
        nav.addMonitorFeed(address(weth), address(monitor), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
        vm.warp(block.timestamp + 200); // primary 200 s old > 100 s heartbeat → usable-stale

        INAVCalculator.PriceFeedData memory pd = nav.getPriceData(address(weth));
        assertTrue(pd.stale, "primary is stale");
        assertEq(pd.price, 324_057_000_000, "stale primary keeps its price");
        assertEq(pd.healthyFeedCount, 0);
        assertTrue(pd.irregular, "a stale primary that drifted from the monitors is irregular");
        assertEq(pd.monitorFeedCount, 1);
        assertGt(pd.divergenceBps, 250);

        (
            int256 primaryPrice,
            int256 monitorMedian,
            uint256 divergenceBps,
            bool irregular,
            uint256 monitorFeedCount,
            bool primaryStale,
            bool primaryAboveMonitors
        ) = nav.getPriceDivergence(address(weth));
        assertEq(primaryPrice, 324_057_000_000, "primaryPrice is the stale price, not 0");
        assertEq(monitorMedian, 340_000_000_000);
        assertEq(divergenceBps, pd.divergenceBps);
        assertTrue(irregular);
        assertEq(monitorFeedCount, 1);
        assertTrue(primaryStale);
        assertFalse(primaryAboveMonitors);

        (int256 lp,, bool lpStale, bool lpIrregular) = nav.latestPrice(address(weth));
        assertEq(lp, 324_057_000_000);
        assertTrue(lpStale);
        assertTrue(lpIrregular, "latestPrice parity");

        weth.mint(address(safe), 1 ether);
        INAVCalculator.NAV memory r = nav.getAccountNav(address(safe), address(0));
        assertTrue(_contains(r.stalePriceAssets, address(weth)), "listed stale");
        assertTrue(_contains(r.irregularPriceAssets, address(weth)), "AND listed irregular");
        assertEq(r.value, 324_057_000_000, "valued at the stale price");
    }

    /// @dev A stale primary still IN band with its monitors is stale but not irregular (the check ran and passed).
    function test_stalePrimary_inBand_notIrregular() public {
        Mock_PriceOracleChainlink primary = new Mock_PriceOracleChainlink("weth-cl", 324_057_000_000, 8);
        Mock_CustomPriceFeed monitor = new Mock_CustomPriceFeed("weth-mon", address(weth), 325_000_000_000, 8);
        vm.startPrank(navCalculatorManager);
        nav.addOrModifyPriceFeed(address(weth), address(primary), IPrices.PriceType.Chainlink, 100);
        nav.removePriceFeed(address(weth), address(wethAdapter));
        nav.setDivergenceTolerance(address(weth), 250);
        nav.addMonitorFeed(address(weth), address(monitor), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
        vm.warp(block.timestamp + 200);

        INAVCalculator.PriceFeedData memory pd = nav.getPriceData(address(weth));
        assertTrue(pd.stale);
        assertFalse(pd.irregular);
        assertEq(pd.monitorFeedCount, 1, "the check ran against the stale primary");
        assertGt(pd.divergenceBps, 0);
    }

    /// @dev SEQUENCER DOWN suppresses the divergence check: `buildPriceData` folds `sequencerDown` into the primary's
    ///      stale flag, so `irregularForSelected` treats the primary as unusable and the check is skipped. Prevents a
    ///      spurious `irregular` during an L2 outage (when the primary is frozen at its last value but the monitors
    ///      may have moved). Regression for the `feedStale || sequencerDown` fold.
    function test_sequencerDown_suppressesIrregular() public {
        _attachWethMonitor(340_000_000_000, 250); // ~492 bps out of band
        // Sanity: with the sequencer up, the out-of-band monitor flags irregular.
        assertTrue(nav.getPriceData(address(weth)).irregular, "control: irregular while sequencer is up");

        // Sequencer goes down (admin-gated feed swap, mirrors test_getPriceData_sequencerDown).
        vm.prank(admin);
        nav.setChainlinkL2SequencerUptimeFeed(address(sequencerUptimeFeedDown));

        INAVCalculator.PriceFeedData memory pd = nav.getPriceData(address(weth));
        assertTrue(pd.sequencerDown, "sequencer must be reported down");
        assertFalse(pd.irregular, "divergence must be suppressed while the sequencer is down");
        assertEq(pd.monitorFeedCount, 0, "no monitor contributes while the primary is sequencer-stale");
        assertEq(pd.divergenceBps, 0);
    }

    // =========================================================================
    // NAV.monitorsUnhealthyPriceAssets — monitors CONFIGURED but none readable
    // =========================================================================
    //
    // The gap this closes: when every monitor for an asset is unreadable, `_monitorDivergence`'s
    // `n > 0` guard skips the whole computation, so `divergenceBps` is 0 and `irregular` is false
    // because the arithmetic never ran — indistinguishable, from outside, from a clean check.

    /// @dev True if `list` contains `asset`. Local helper so each assertion reads as a claim about membership.
    function _contains(INAVCalculator.Asset[] memory list, address asset) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].asset == asset) return true;
        }
        return false;
    }

    /// @dev Gives the safe a WETH position so weth is an asset-with-position in the NAV read, then reads the NAV.
    function _navWithWethPosition() internal returns (INAVCalculator.NAV memory) {
        weth.mint(address(safe), 1 ether);
        return nav.getAccountNav(address(safe), address(0));
    }

    /// @dev A single configured monitor that cannot be read puts the asset in the list — and NOT in
    ///      `irregularPriceAssets`, which is precisely the silence this array breaks.
    function test_allMonitorsUnhealthy_assetIsListed() public {
        Mock_CustomPriceFeedStaled deadMonitor =
            new Mock_CustomPriceFeedStaled("WETH-monitor-stale", address(weth), 340_000_000_000, 8);
        vm.startPrank(navCalculatorManager);
        nav.setDivergenceTolerance(address(weth), 250);
        nav.addMonitorFeed(address(weth), address(deadMonitor), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        INAVCalculator.NAV memory r = _navWithWethPosition();
        assertTrue(
            _contains(r.monitorsUnhealthyPriceAssets, address(weth)),
            "weth must be listed: its only monitor is unreadable"
        );
        assertFalse(_contains(r.irregularPriceAssets, address(weth)), "must NOT be irregular: the check never ran");
        // The monitor IS configured — so this is not the 'no monitors' case.
        assertEq(nav.getMonitorFeedCount(address(weth)), 1, "monitor is configured, just unreadable");
    }

    /// @dev One readable monitor is enough for the check to run, so the asset must NOT be listed.
    function test_oneHealthyMonitor_assetNotListed() public {
        _attachWethMonitor(325_000_000_000, 250); // in-band, healthy
        INAVCalculator.NAV memory r = _navWithWethPosition();
        assertFalse(_contains(r.monitorsUnhealthyPriceAssets, address(weth)), "a readable monitor means the check ran");
    }

    /// @dev THE BITE TEST. Two monitors, one readable and one not: the asset is absent from the list because the
    ///      check still runs. Then the readable one is made unreadable (`setPrice(0)` → `_readFeedPrice` returns
    ///      ok=false) and the asset appears — with no other state changed. Proves the array tracks live monitor
    ///      health rather than configuration, and that it flips on exactly the transition that matters.
    function test_makingTheLastHealthyMonitorUnhealthy_flipsTheList() public {
        Mock_CustomPriceFeed healthy = _attachWethMonitor(325_000_000_000, 250);
        Mock_CustomPriceFeedStaled dead =
            new Mock_CustomPriceFeedStaled("WETH-monitor-2", address(weth), 325_000_000_000, 8);
        vm.prank(navCalculatorManager);
        nav.addMonitorFeed(address(weth), address(dead), IPrices.PriceType.Custom, type(uint256).max);
        assertEq(nav.getMonitorFeedCount(address(weth)), 2, "two monitors configured");

        // Before: one of the two answers, so the divergence check runs.
        INAVCalculator.NAV memory before = _navWithWethPosition();
        assertFalse(
            _contains(before.monitorsUnhealthyPriceAssets, address(weth)),
            "control: one healthy monitor of two means the asset is checked"
        );
        assertEq(nav.getPriceData(address(weth)).monitorFeedCount, 1, "exactly one monitor contributed");

        // Kill the last healthy monitor. A zero custom price fails `_readFeedPrice`'s validity gate.
        healthy.setPrice(0);

        INAVCalculator.NAV memory after_ = nav.getAccountNav(address(safe), address(0));
        assertTrue(
            _contains(after_.monitorsUnhealthyPriceAssets, address(weth)),
            "weth must appear once its last readable monitor dies"
        );
        assertEq(nav.getPriceData(address(weth)).monitorFeedCount, 0, "no monitor contributes any more");
        // Configuration is untouched — only runtime health changed. This is the whole point of the field.
        assertEq(nav.getMonitorFeedCount(address(weth)), 2, "still two monitors CONFIGURED");
    }

    /// @dev An asset with NO monitors configured must never be listed, however long it goes unchecked. This is the
    ///      distinction the field name has to carry: 'monitors configured but none healthy' is a runtime failure,
    ///      whereas 'no monitors configured' is a static config property derivable off-chain from
    ///      `getMonitorFeedCount == 0` + `divergenceToleranceBps == 0`, and is a separate, unruled question.
    function test_noMonitorsConfigured_neverListed() public {
        INAVCalculator.NAV memory r = _navWithWethPosition(); // no monitor attached at all
        assertEq(nav.getMonitorFeedCount(address(weth)), 0, "precondition: nothing configured");
        assertFalse(
            _contains(r.monitorsUnhealthyPriceAssets, address(weth)),
            "an unmonitored asset must NOT be reported as monitors-unhealthy"
        );
    }

    /// @dev When the PRIMARY is unusable the monitor count is also 0, but the monitors are not the reason — the
    ///      sequencer is. Keeps this array disjoint from `stalePriceAssets`, which already reports that case.
    function test_primaryUnusable_notListedHere() public {
        _attachWethMonitor(325_000_000_000, 250); // a perfectly healthy monitor
        vm.prank(admin);
        nav.setChainlinkL2SequencerUptimeFeed(address(sequencerUptimeFeedDown));

        INAVCalculator.NAV memory r = _navWithWethPosition();
        assertTrue(r.sequencerDown, "precondition: primary is unusable");
        assertFalse(
            _contains(r.monitorsUnhealthyPriceAssets, address(weth)),
            "a suppressed-by-primary check must not be blamed on the monitors"
        );
    }

    /// @dev `irregularPriceAssets` and `monitorsUnhealthyPriceAssets` are NOT mutually exclusive, and this pins it.
    ///      The peg guard is monitor-independent, so a stablecoin trading off $1 whose monitors are ALL unreadable is
    ///      simultaneously `irregular` (its peg is breached) and monitors-unhealthy (its divergence check never ran).
    ///      Surfaced by Copilot: earlier comments claimed `irregular` was false whenever this flag was set, which is
    ///      wrong in exactly this state — the two answer different questions and a consumer must not treat presence in
    ///      one as absence from the other.
    function test_pegBreachAndDeadMonitors_appearsInBothArrays() public {
        Mock_CustomPriceFeedStaled deadMonitor =
            new Mock_CustomPriceFeedStaled("usdc-monitor-stale", address(usdc), 100_000_000, 8);
        vm.startPrank(navCalculatorManager);
        nav.setDivergenceTolerance(address(usdc), 250);
        nav.setPegTolerance(address(usdc), 100); // peg guard ON, independent of monitors
        nav.addMonitorFeed(address(usdc), address(deadMonitor), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
        usdcAdapter.setPrice(103_000_000); // $1.03 -> 300 bps off peg, beyond the 100 bps tolerance
        usdc.mint(address(safe), 1_000e6);

        INAVCalculator.NAV memory r = nav.getAccountNav(address(safe), address(0));
        assertTrue(
            _contains(r.monitorsUnhealthyPriceAssets, address(usdc)),
            "monitors are all unreadable: divergence check did not run"
        );
        assertTrue(
            _contains(r.irregularPriceAssets, address(usdc)),
            "peg guard is monitor-independent: it still fires, so the asset is ALSO irregular"
        );
    }

    /// @dev The `monitorFeeds[asset].length > 0` conjunct is only load-bearing when `_hasDivergenceChecks` returns
    ///      true via its OTHER disjunct — a non-zero `pegToleranceBps` with ZERO monitors configured. In that shape
    ///      the `if` body DOES run, `healthyMonitors` is 0 (there is nothing to read), and without the length check
    ///      every peg-guarded stablecoin would be reported monitors-unhealthy at once. `test_noMonitorsConfigured_*`
    ///      does NOT cover this: with no peg tolerance the body is skipped entirely, so the conjunct is unreached.
    function test_pegToleranceWithZeroMonitors_notListed() public {
        vm.prank(navCalculatorManager);
        nav.setPegTolerance(address(usdc), 100); // enables the monitor-INDEPENDENT peg guard
        assertEq(nav.getMonitorFeedCount(address(usdc)), 0, "precondition: zero monitors, peg guard on");
        usdc.mint(address(safe), 1_000e6);

        INAVCalculator.NAV memory r = nav.getAccountNav(address(safe), address(0));
        assertFalse(
            _contains(r.monitorsUnhealthyPriceAssets, address(usdc)),
            "a peg-guarded asset with NO monitors must not be reported monitors-unhealthy"
        );
    }

    /// @dev ADR 0029: a STALE-but-priced primary is checked against its monitors, so a healthy monitor contributes
    ///      and the asset is NOT monitors-unhealthy. (Was: the check was suppressed for any stale primary.) DAI is the
    ///      only asset with a finite heartbeat, so warping ages DAI out and leaves the others fresh.
    function test_stalePrimaryWithHealthyMonitor_checkRuns_notListed() public {
        Mock_PriceOracleChainlink monitor = new Mock_PriceOracleChainlink("DAI-monitor", 100_000_000, 8);
        vm.startPrank(navCalculatorManager);
        nav.setDivergenceTolerance(address(dai), 100);
        nav.addMonitorFeed(address(dai), address(monitor), IPrices.PriceType.Chainlink, type(uint256).max);
        vm.stopPrank();
        dai.mint(address(safe), 1000e18);

        vm.warp(block.timestamp + 2 days); // ages DAI's primary out; sequencer stays UP

        INAVCalculator.NAV memory r = nav.getAccountNav(address(safe), address(0));
        assertTrue(_contains(r.stalePriceAssets, address(dai)), "precondition: DAI's primary is stale");
        assertEq(nav.getPriceData(address(dai)).monitorFeedCount, 1, "the check ran against the stale primary");
        assertFalse(_contains(r.monitorsUnhealthyPriceAssets, address(dai)), "a healthy monitor answered");
        assertEq(r.value, 1000e8, "valued at the stale $1");
    }

    /// @dev ADR 0029: `monitorsUnhealthy` can now be set for a STALE-but-priced primary — the check would have run,
    ///      and only the monitors' silence stopped it. So a stale DAI whose only monitor is dead is in BOTH arrays.
    function test_stalePricedPrimaryWithDeadMonitors_isListed() public {
        Mock_CustomPriceFeedStaled deadMonitor = new Mock_CustomPriceFeedStaled("DAI-dead", address(dai), 1e8, 8);
        vm.startPrank(navCalculatorManager);
        nav.setDivergenceTolerance(address(dai), 100);
        nav.addMonitorFeed(address(dai), address(deadMonitor), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
        dai.mint(address(safe), 1000e18);
        vm.warp(block.timestamp + 2 days);

        INAVCalculator.NAV memory r = nav.getAccountNav(address(safe), address(0));
        assertTrue(_contains(r.stalePriceAssets, address(dai)));
        assertTrue(_contains(r.monitorsUnhealthyPriceAssets, address(dai)), "stale-but-priced: monitors blamed");
    }

    /// @dev An UNUSABLE primary (past MAX_STALE_PRICE_AGE) with dead monitors is NOT blamed on the monitors: the
    ///      check could not have run for want of a primary price. Keeps the "unusable primary" case disjoint.
    function test_unusablePrimaryWithDeadMonitors_notListedHere() public {
        Mock_CustomPriceFeedStaled deadMonitor = new Mock_CustomPriceFeedStaled("DAI-dead", address(dai), 1e8, 8);
        vm.startPrank(navCalculatorManager);
        nav.setDivergenceTolerance(address(dai), 100);
        nav.addMonitorFeed(address(dai), address(deadMonitor), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
        dai.mint(address(safe), 1000e18);
        vm.warp(block.timestamp + MAX_STALE_PRICE_AGE + 1);

        INAVCalculator.NAV memory r = nav.getAccountNav(address(safe), address(0));
        assertTrue(_contains(r.stalePriceAssets, address(dai)), "precondition: DAI flagged");
        assertEq(nav.getPriceData(address(dai)).price, 0, "precondition: DAI unusable");
        assertFalse(
            _contains(r.monitorsUnhealthyPriceAssets, address(dai)),
            "an unusable-primary check must not be blamed on the monitors"
        );
    }

    /// @dev The paginated read carries the same signal, restricted to the slice's assets. Without this, the accounts
    ///      that must paginate — the largest ones — would be the only ones unable to see monitor failure.
    function test_partialNav_carriesTheSignal() public {
        Mock_CustomPriceFeedStaled deadMonitor =
            new Mock_CustomPriceFeedStaled("WETH-monitor-stale", address(weth), 340_000_000_000, 8);
        vm.startPrank(navCalculatorManager);
        nav.setDivergenceTolerance(address(weth), 250);
        nav.addMonitorFeed(address(weth), address(deadMonitor), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
        weth.mint(address(safe), 1 ether);

        INAVCalculator.PartialNAV memory p =
            nav.getAccountNavForAdapters(address(safe), address(0), nav.getAllAdapters());
        assertTrue(
            _contains(p.monitorsUnhealthyPriceAssets, address(weth)),
            "PartialNAV must carry monitorsUnhealthyPriceAssets"
        );
    }
}
