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

    /// @dev A STALE PRIMARY suppresses the divergence check entirely: with no usable primary price there is nothing to
    ///      compare the monitors against, so `irregular` stays false and `monitorFeedCount`/`divergenceBps` stay 0
    ///      (rather than flagging on a comparison against a zeroed primary). Regression for the `!primaryStale`
    ///      guard in `_monitorDivergence`.
    function test_stalePrimary_suppressesIrregular() public {
        // Swap weth's primary to a stale feed (it becomes the only pricing feed, so selection returns stale/price 0).
        Mock_CustomPriceFeedStaled stalePrimary =
            new Mock_CustomPriceFeedStaled("weth-stale-primary", address(weth), 324_057_000_000, 8);
        Mock_CustomPriceFeed monitor = new Mock_CustomPriceFeed("weth-mon", address(weth), 340_000_000_000, 8);
        vm.startPrank(navCalculatorManager);
        nav.addPriceFeed(address(weth), address(stalePrimary), IPrices.PriceType.Custom, type(uint256).max);
        nav.removePriceFeed(address(weth), address(wethAdapter));
        nav.setDivergenceTolerance(address(weth), 250);
        // Out of band ($3400 vs $3240.57 ~492 bps) — would flag irregular against a healthy primary.
        nav.addMonitorFeed(address(weth), address(monitor), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        INAVCalculator.PriceFeedData memory pd = nav.getPriceData(address(weth));
        assertTrue(pd.stale, "primary is stale");
        assertFalse(pd.irregular, "divergence must be suppressed when the primary is stale");
        assertEq(pd.monitorFeedCount, 0, "no monitor contributes against a stale primary");
        assertEq(pd.divergenceBps, 0);
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
}
