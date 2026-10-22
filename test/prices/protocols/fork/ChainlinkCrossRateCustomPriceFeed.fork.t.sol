// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ChainlinkCrossRateCustomPriceFeed} from "src/prices/protocols/ChainlinkCrossRateCustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title ChainlinkCrossRateCustomPriceFeed fork test — mainnet WBTC depeg monitor (issue #356)
/// @dev WBTC's primary is Chainlink `BTC / USD`, which prices BITCOIN; the WBTC-specific monitor is
///      `WBTC / BTC` x `BTC / USD`, both read directly from Chainlink. Mainnet has no Chainlink `WBTC / USD`, and the
///      NAV-sourced {CrossRateCustomPriceFeed} cannot be used because the NAV's BTC/USD base IS WBTC
///      (`CustomFeedBaseCircular`). The suite proves the price against the live feeds at a pinned block, the ADR 0029
///      staleness semantics after a warp, and — the part only a fork can prove — that the LIVE NAV proxy (running
///      this build via `_useNewNavImpl`) accepts it as a WBTC monitor and raises `irregular` on a simulated depeg.
contract ChainlinkCrossRateCustomPriceFeedForkTest is TestEnvConfigurator {
    ChainlinkCrossRateCustomPriceFeed feed;

    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    /// @dev Chainlink `WBTC / BTC` proxy — 8 decimals, declared heartbeat 86400 (reference-data-directory).
    address constant WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    /// @dev Chainlink `BTC / USD` proxy — 8 decimals, declared heartbeat 3600. WBTC's NAV primary.
    address constant BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    /// @dev RedStone WBTC/BTC push feed — the rate leg of the second WBTC monitor, `WBTCCrossRateRedstone`.
    address constant RS_WBTC_BTC = 0xD260596f85C6D91Ccd40f7076eEb62ACb3B2ad53;
    /// @dev The live NAVCalculator proxy (fleet-wide since the 2026-08-18 redeploy).
    address constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    /// @dev The timelock that holds MANAGER on the live NAV (asserted in the test, not assumed).
    address constant TIMELOCK = 0xAB92EA75D07792915eB1f29259354866B880dFC2;

    uint256 constant RATE_HB = 86_400;
    uint256 constant BASE_HB = 3_600;
    uint256 constant MIN_R = 0.5e8;
    uint256 constant MAX_R = 1.5e8;
    uint256 constant FORK_BLOCK = 26_240_000;
    uint32 constant DIVERGENCE_BPS = 50;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        _useNewNavImpl(NAV);

        feed = new ChainlinkCrossRateCustomPriceFeed(WBTC, WBTC_BTC, RATE_HB, BTC_USD, BASE_HB, MIN_R, MAX_R);
    }

    /// @dev The premise: both addresses are the pairs they are supposed to be, at the decimals the math assumes.
    function test_legsAreTheExpectedPairs() public view {
        assertEq(AggregatorV3Interface(WBTC_BTC).description(), "WBTC / BTC");
        assertEq(AggregatorV3Interface(BTC_USD).description(), "BTC / USD");
        assertEq(AggregatorV3Interface(WBTC_BTC).decimals(), 8);
        assertEq(AggregatorV3Interface(BTC_USD).decimals(), 8);
    }

    /// @dev In-EVM ground truth, by hand: price == WBTC/BTC x BTC/USD / 1e8, fresh at the pinned block.
    function test_getLatestPrice_matchesHandComputedProduct() public view {
        (, int256 rate,, uint256 rateAt,) = AggregatorV3Interface(WBTC_BTC).latestRoundData();
        (, int256 btc,, uint256 btcAt,) = AggregatorV3Interface(BTC_USD).latestRoundData();
        uint256 expected = (uint256(rate) * uint256(btc)) / 1e8;

        (uint256 price, bool stale) = feed.getLatestPrice();
        assertFalse(stale, "both legs within their heartbeats at the pinned block");
        assertEq(price, expected, "WBTC/BTC x BTC/USD / 1e8");

        (,,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, rateAt < btcAt ? rateAt : btcAt, "updatedAt == the older leg");
        assertEq(feed.BASE_ASSET(), address(0));
    }

    /// @dev ADR 0029: past BTC/USD's 1h heartbeat the price is CARRIED unchanged and flagged stale.
    function test_afterBaseHeartbeat_samePriceButStale() public {
        (uint256 freshPrice, bool freshStale) = feed.getLatestPrice();
        assertFalse(freshStale);

        (,,, uint256 btcAt,) = AggregatorV3Interface(BTC_USD).latestRoundData();
        vm.warp(btcAt + BASE_HB + 1);

        (uint256 price, bool stale) = feed.getLatestPrice();
        assertTrue(stale, "BTC / USD past its heartbeat");
        assertEq(price, freshPrice, "a stale leg keeps the price");

        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, 0, "Chainlink-ABI readers see 0 while stale");

        (uint256 gu, uint256 ghb) = feed.governingFeedFreshness();
        assertEq(gu, btcAt, "the stale BTC / USD leg governs");
        assertEq(ghb, BASE_HB);
    }

    /// @dev **THE POINT OF THE CONTRACT.** The live NAV accepts it as a WBTC MONITOR (a NAV-sourced cross-rate would
    ///      revert `CustomFeedBaseCircular` here), and a WBTC depeg the BTC / USD primary cannot see raises
    ///      `irregular` at a 50 bps tolerance, while a 1 bp move does not.
    function test_liveNav_acceptsAsWbtcMonitor_andFlagsDepeg() public {
        assertTrue(IAccessControl(NAV).hasRole(MANAGER, TIMELOCK), "premise: the timelock holds MANAGER");

        vm.startPrank(TIMELOCK);
        INAVCalculator(NAV).setDivergenceTolerance(WBTC, DIVERGENCE_BPS);
        INAVCalculator(NAV).addMonitorFeed(WBTC, address(feed), IPrices.PriceType.Custom, RATE_HB);
        vm.stopPrank();

        IPrices.PriceFeedConfig[] memory monitors = IPrices(NAV).getMonitorFeeds(WBTC);
        bool found;
        for (uint256 i; i < monitors.length; ++i) {
            if (monitors[i].priceFeed == address(feed)) found = true;
        }
        assertTrue(found, "registered as a WBTC monitor");

        (uint80 rid,, uint256 startedAt, uint256 rateAt, uint80 air) = AggregatorV3Interface(WBTC_BTC).latestRoundData();

        // 1 bp above parity: inside 50 bps of the BTC / USD primary — not irregular.
        vm.mockCall(
            WBTC_BTC,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(rid, int256(1.0001e8), startedAt, rateAt, air)
        );
        INAVCalculator.PriceFeedData memory calm = INAVCalculator(NAV).getPriceData(WBTC);
        assertFalse(calm.stale, "primary fresh");
        assertFalse(calm.irregular, "1 bp is inside the 50 bps tolerance");

        // WBTC depegs to 0.97 BTC: 300 bps below the primary — irregular.
        vm.mockCall(
            WBTC_BTC,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(rid, int256(0.97e8), startedAt, rateAt, air)
        );
        INAVCalculator.PriceFeedData memory depeg = INAVCalculator(NAV).getPriceData(WBTC);
        assertTrue(depeg.irregular, "a 3% WBTC depeg is flagged irregular");
        assertEq(depeg.price, calm.price, "the monitor never moves the primary's price");
    }

    /// @dev The second WBTC monitor (`WBTCCrossRateRedstone`): the same class on RedStone's WBTC/BTC. Pins the leg's
    ///      identity and the arithmetic, and that its 86400 s heartbeat is consistent with the feed's own cadence at
    ///      the pinned block (RedStone's default push trigger is 0.5% deviation or 86400 s). Block-sensitive: RedStone
    ///      pushes this feed a few seconds after each 24 h, so a re-pinned block inside that overshoot would fail the
    ///      age assertion; pick a block mid-interval.
    function test_redstoneLeg_isTheExpectedPair_andPrices() public {
        assertEq(AggregatorV3Interface(RS_WBTC_BTC).description(), "RedStone Price Feed for WBTC/BTC");
        assertEq(AggregatorV3Interface(RS_WBTC_BTC).decimals(), 8);
        ChainlinkCrossRateCustomPriceFeed rs =
            new ChainlinkCrossRateCustomPriceFeed(WBTC, RS_WBTC_BTC, RATE_HB, BTC_USD, BASE_HB, MIN_R, MAX_R);

        (, int256 rate,, uint256 rateAt,) = AggregatorV3Interface(RS_WBTC_BTC).latestRoundData();
        (, int256 btc,, uint256 btcAt,) = AggregatorV3Interface(BTC_USD).latestRoundData();
        assertGe(uint256(rate), MIN_R, "inside the band");
        assertLe(uint256(rate), MAX_R, "inside the band");
        assertLt(block.timestamp - rateAt, RATE_HB, "the RedStone leg is younger than its 86400 s heartbeat");

        (uint256 price, bool stale) = rs.getLatestPrice();
        assertFalse(stale);
        assertEq(price, (uint256(rate) * uint256(btc)) / 1e8, "RedStone WBTC/BTC x BTC/USD / 1e8");
        (,,, uint256 updatedAt,) = rs.latestRoundData();
        assertEq(updatedAt, rateAt < btcAt ? rateAt : btcAt, "updatedAt == the older leg");

        // Past the RedStone leg's heartbeat, with BTC/USD kept FRESH (mocked to the warped time) so the stale verdict
        // can only come from the RedStone leg: the price is carried, flagged stale (ADR 0029).
        (uint80 bid,, uint256 bStarted,, uint80 bAir) = AggregatorV3Interface(BTC_USD).latestRoundData();
        vm.warp(rateAt + RATE_HB + 1);
        vm.mockCall(
            BTC_USD,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(bid, btc, bStarted, block.timestamp, bAir)
        );
        (uint256 later, bool laterStale) = rs.getLatestPrice();
        assertTrue(laterStale, "the RedStone leg alone is past its heartbeat");
        assertEq(later, price);
        (uint256 gu, uint256 ghb) = rs.governingFeedFreshness();
        assertEq(gu, rateAt, "the stale RedStone leg governs");
        assertEq(ghb, RATE_HB);
    }
}
