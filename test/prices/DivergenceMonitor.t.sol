// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Mock_CustomPriceFeed} from "test/mocks/price_oracles.sol";

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
        _attachWethMonitor(340_000_000_000, 250);
        (
            int256 primaryPrice,
            int256 monitorMean,
            uint256 divergenceBps,
            bool irregular,
            uint256 monitorFeedCount,
            bool primaryStale
        ) = nav.getPriceDivergence(address(weth));
        assertEq(primaryPrice, 324_057_000_000);
        assertEq(monitorMean, 340_000_000_000);
        assertGt(divergenceBps, 250);
        assertTrue(irregular);
        assertEq(monitorFeedCount, 1);
        assertFalse(primaryStale);
    }
}
