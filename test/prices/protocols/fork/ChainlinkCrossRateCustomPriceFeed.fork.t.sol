// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ChainlinkCrossRateCustomPriceFeed} from "src/prices/protocols/ChainlinkCrossRateCustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";

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
    /// @dev RedStone BTC/USD — WBTC's live monitor, KEPT as the one monitor that shares no feed with the primary.
    address constant RS_BTC_USD = 0xAB7f623fb2F6fea6601D4350FA0E2290663C28Fc;
    /// @dev The live NAVCalculator proxy (fleet-wide since the 2026-08-18 redeploy).
    address constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    /// @dev The timelock that holds MANAGER on the live NAV (asserted in the test, not assumed).
    address constant TIMELOCK = 0xAB92EA75D07792915eB1f29259354866B880dFC2;

    uint256 constant RATE_HB = 86_400;
    uint256 constant BASE_HB = 3_600;
    uint256 constant MIN_R = 0.01e8; // the configured floor (custom-price-feeds/1.json WBTCCrossRate*)
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

    /// @dev Why WBTC keeps the RedStone BTC monitor next to the two WBTC-specific ones: both of those multiply by the
    ///      Chainlink BTC/USD primary, so when the primary FREEZES past its heartbeat they go stale with it and no
    ///      comparison runs (negative control). With the RedStone BTC monitor registered too, the same freeze during a
    ///      3% market move raises `irregular` (ADR 0029 runs divergence on a usable stale primary).
    function test_liveNav_frozenPrimary_onlyTheIndependentMonitorRaisesIrregular() public {
        ChainlinkCrossRateCustomPriceFeed rs =
            new ChainlinkCrossRateCustomPriceFeed(WBTC, RS_WBTC_BTC, RATE_HB, BTC_USD, BASE_HB, MIN_R, MAX_R);
        vm.startPrank(TIMELOCK);
        // Start from the two WBTC-specific monitors only (the live RedStone BTC monitor is removed for the control).
        IPrices.PriceFeedConfig[] memory live = IPrices(NAV).getMonitorFeeds(WBTC);
        for (uint256 i; i < live.length; ++i) {
            INAVCalculator(NAV).removeMonitorFeed(WBTC, live[i].priceFeed);
        }
        INAVCalculator(NAV).setDivergenceTolerance(WBTC, DIVERGENCE_BPS);
        INAVCalculator(NAV).addMonitorFeed(WBTC, address(feed), IPrices.PriceType.Custom, RATE_HB);
        INAVCalculator(NAV).addMonitorFeed(WBTC, address(rs), IPrices.PriceType.Custom, RATE_HB);
        vm.stopPrank();

        // Freeze the primary past its 3600 s heartbeat; keep both WBTC/BTC legs FRESH at parity, so the only reason
        // the two WBTC-specific monitors can go stale is the primary feed they multiply by.
        (,,, uint256 btcAt,) = AggregatorV3Interface(BTC_USD).latestRoundData();
        vm.warp(btcAt + BASE_HB + 1);
        _mockFresh(WBTC_BTC, 1e8);
        _mockFresh(RS_WBTC_BTC, 1e8);
        (, int256 btcFrozen,,,) = AggregatorV3Interface(BTC_USD).latestRoundData();
        // The market (RedStone BTC) has moved 3% below the frozen primary.
        _mockFresh(RS_BTC_USD, (btcFrozen * 97) / 100);

        (, bool clStale) = feed.getLatestPrice();
        (, bool rsStale) = rs.getLatestPrice();
        assertTrue(clStale && rsStale, "both WBTC-specific monitors go stale with the primary");
        INAVCalculator.PriceFeedData memory blind = INAVCalculator(NAV).getPriceData(WBTC);
        assertTrue(blind.stale, "the frozen primary is flagged stale");
        assertFalse(blind.irregular, "control: with only those two monitors the 3% move is invisible");
        assertEq(blind.monitorFeedCount, 0, "control: no monitor contributed");

        vm.prank(TIMELOCK);
        INAVCalculator(NAV).addMonitorFeed(WBTC, RS_BTC_USD, IPrices.PriceType.Redstone, RATE_HB);
        INAVCalculator.PriceFeedData memory seen = INAVCalculator(NAV).getPriceData(WBTC);
        assertTrue(seen.stale, "still stale");
        assertTrue(seen.irregular, "the independent RedStone BTC monitor raises irregular");
        assertEq(seen.monitorFeedCount, 1, "exactly the RedStone BTC monitor contributed");
        assertEq(seen.price, blind.price, "a monitor never moves the price");
    }

    /// @dev The rollout END STATE, built from the committed config rather than hand-picked constants: both Custom
    ///      monitors deployed from `custom-price-feeds/1.json`, WBTC's monitor list and tolerance from
    ///      `nav-config/assets-and-price-feeds/1.json`, reconciled onto the live NAV the way `MigrateToMonitorFeeds`
    ///      does (add config monitors not yet registered, then remove registered monitors absent from config). Pins
    ///      that the end state is exactly three monitors, that the live RedStone BTC monitor is KEPT with its existing
    ///      registration, that WBTC reads healthy and not irregular at the pinned block, and that both a WBTC depeg
    ///      and a frozen primary during a BTC move raise `irregular`.
    function test_configEndState_threeMonitors_healthy_andAlarmed() public {
        uint256 cid = 1;
        address clMon = _deployCrossRateFromConfig("WBTCCrossRate");
        address rsMon = _deployCrossRateFromConfig("WBTCCrossRateRedstone");

        // The live RedStone BTC monitor is registered today with exactly the type and heartbeat config now names.
        IPrices.PriceFeedConfig[] memory before = IPrices(NAV).getMonitorFeeds(WBTC);
        bool liveRs;
        for (uint256 i; i < before.length; ++i) {
            if (before[i].priceFeed == RS_BTC_USD) {
                liveRs = true;
                assertEq(uint256(before[i].priceType), uint256(IPrices.PriceType.Redstone), "live type");
                assertEq(before[i].chainlinkHeartbeat, 86_400, "live heartbeat");
            }
        }
        assertTrue(liveRs, "premise: RedStone BTC is WBTC's live monitor");

        uint256 n = ConfigReader.assetMonitorFeedCount(vm, cid, "WBTC");
        assertEq(n, 3, "config: three WBTC monitors");
        assertEq(ConfigReader.readAssetDivergenceToleranceBps(vm, cid, "WBTC"), DIVERGENCE_BPS, "config: 50 bps");
        address[] memory target = new address[](n);
        vm.startPrank(TIMELOCK);
        // Pass A of MigrateToMonitorFeeds sets the configured tolerance before adding monitors.
        INAVCalculator(NAV)
            .setDivergenceTolerance(WBTC, uint32(ConfigReader.readAssetDivergenceToleranceBps(vm, cid, "WBTC")));
        for (uint256 i; i < n; ++i) {
            (IPrices.PriceType pt, bool ok) = ConfigReader.readAssetMonitorFeedPriceType(vm, cid, "WBTC", i);
            assertTrue(ok, "config: known monitor type");
            uint256 hb = vm.parseUint(ConfigReader.readAssetMonitorFeedHeartbeat(vm, cid, "WBTC", i));
            if (pt == IPrices.PriceType.Custom) {
                string memory name = ConfigReader.readAssetMonitorFeedName(vm, cid, "WBTC", i);
                if (keccak256(bytes(name)) == keccak256("WBTCCrossRate")) {
                    target[i] = clMon;
                } else {
                    assertEq(name, "WBTCCrossRateRedstone", "config: unexpected Custom monitor");
                    target[i] = rsMon;
                }
            } else {
                target[i] = vm.parseAddress(ConfigReader.readAssetMonitorFeedAddress(vm, cid, "WBTC", i));
                assertEq(target[i], RS_BTC_USD, "config: the static monitor is RedStone BTC");
                assertEq(uint256(pt), uint256(IPrices.PriceType.Redstone), "config type == live type");
                assertEq(hb, 86_400, "config heartbeat == live heartbeat");
            }
            if (!_registered(target[i])) INAVCalculator(NAV).addMonitorFeed(WBTC, target[i], pt, hb);
        }
        for (uint256 i; i < before.length; ++i) {
            bool keep;
            for (uint256 j; j < n; ++j) {
                if (target[j] == before[i].priceFeed) keep = true;
            }
            if (!keep) INAVCalculator(NAV).removeMonitorFeed(WBTC, before[i].priceFeed);
        }
        vm.stopPrank();

        IPrices.PriceFeedConfig[] memory after_ = IPrices(NAV).getMonitorFeeds(WBTC);
        assertEq(after_.length, 3, "end state: exactly three monitors");
        assertTrue(_registered(clMon) && _registered(rsMon) && _registered(RS_BTC_USD), "end state: the three");
        for (uint256 i; i < after_.length; ++i) {
            if (after_[i].priceFeed == RS_BTC_USD) {
                assertEq(uint256(after_[i].priceType), uint256(IPrices.PriceType.Redstone), "kept: type unchanged");
                assertEq(after_[i].chainlinkHeartbeat, 86_400, "kept: heartbeat unchanged");
            }
        }
        assertEq(IPrices(NAV).getAssetPricing(WBTC).divergenceToleranceBps, DIVERGENCE_BPS, "on-chain tolerance 50");

        // Block-sensitive: RedStone BTC/USD pushes on 0.5% or 24 h, so a re-pinned block inside its heartbeat
        // overshoot would read 2 healthy monitors here; pick a block mid-interval.

        INAVCalculator.PriceFeedData memory calm = INAVCalculator(NAV).getPriceData(WBTC);
        assertFalse(calm.stale, "fresh at the pinned block");
        assertFalse(calm.irregular, "no false irregular at the pinned block");
        assertEq(calm.monitorFeedCount, 3, "all three monitors healthy");

        // A 3% WBTC depeg (both WBTC/BTC legs at 0.97): the WBTC-specific monitors raise irregular.
        uint256 snap = vm.snapshotState();
        _mockFresh(WBTC_BTC, 0.97e8);
        _mockFresh(RS_WBTC_BTC, 0.97e8);
        INAVCalculator.PriceFeedData memory depeg = INAVCalculator(NAV).getPriceData(WBTC);
        assertTrue(depeg.irregular, "WBTC depeg -> irregular");
        assertEq(depeg.price, calm.price, "a monitor never moves the price");
        vm.revertToState(snap);

        // A collapse to 0.3 BTC (Copilot, PR #358): below the old 0.5 floor both WBTC monitors dropped out and the
        // RedStone BTC monitor, which prices BTC, agreed with the primary — nothing flagged. The 0.01 floor keeps it in.
        snap = vm.snapshotState();
        _mockFresh(WBTC_BTC, 0.3e8);
        _mockFresh(RS_WBTC_BTC, 0.3e8);
        INAVCalculator.PriceFeedData memory collapse = INAVCalculator(NAV).getPriceData(WBTC);
        assertTrue(collapse.irregular, "a 70% WBTC collapse -> irregular");
        assertEq(collapse.monitorFeedCount, 3, "both WBTC monitors stay in the band");
        assertEq(collapse.price, calm.price, "a monitor never moves the price");
        vm.revertToState(snap);

        // A re-pointed rate leg answering like ETH / BTC (~0.03) is inside the 0.01 floor: loud, never silent.
        snap = vm.snapshotState();
        _mockFresh(WBTC_BTC, 0.03e8);
        assertTrue(INAVCalculator(NAV).getPriceData(WBTC).irregular, "a wrong-pair leg -> irregular");
        vm.revertToState(snap);

        // Primary frozen past its heartbeat while BTC moves 3%: only RedStone BTC can see it, and it does.
        (,,, uint256 btcAt,) = AggregatorV3Interface(BTC_USD).latestRoundData();
        vm.warp(btcAt + BASE_HB + 1);
        _mockFresh(WBTC_BTC, 1e8);
        _mockFresh(RS_WBTC_BTC, 1e8);
        (, int256 btcFrozen,,,) = AggregatorV3Interface(BTC_USD).latestRoundData();
        _mockFresh(RS_BTC_USD, (btcFrozen * 97) / 100);
        INAVCalculator.PriceFeedData memory frozen = INAVCalculator(NAV).getPriceData(WBTC);
        assertTrue(frozen.stale, "frozen primary -> stale");
        assertTrue(frozen.irregular, "frozen primary + 3% move -> irregular");
        assertEq(frozen.monitorFeedCount, 1, "only RedStone BTC is still healthy");
    }

    function _deployCrossRateFromConfig(string memory k) internal returns (address) {
        return address(
            new ChainlinkCrossRateCustomPriceFeed(
                vm.parseAddress(ConfigReader.readPriceFeedParam(vm, 1, k, "underlyingAsset")),
                vm.parseAddress(ConfigReader.readPriceFeedParam(vm, 1, k, "rateChainlink")),
                vm.parseUint(ConfigReader.readPriceFeedParam(vm, 1, k, "rateHeartbeat")),
                vm.parseAddress(ConfigReader.readPriceFeedParam(vm, 1, k, "baseUsdChainlink")),
                vm.parseUint(ConfigReader.readPriceFeedParam(vm, 1, k, "baseUsdHeartbeat")),
                vm.parseUint(ConfigReader.readPriceFeedParam(vm, 1, k, "minAnswer")),
                vm.parseUint(ConfigReader.readPriceFeedParam(vm, 1, k, "maxAnswer"))
            )
        );
    }

    function _registered(address f) internal view returns (bool) {
        IPrices.PriceFeedConfig[] memory m = IPrices(NAV).getMonitorFeeds(WBTC);
        for (uint256 i; i < m.length; ++i) {
            if (m[i].priceFeed == f) return true;
        }
        return false;
    }

    function _mockFresh(address aggregator, int256 answer) internal {
        (uint80 r,, uint256 started,, uint80 air) = AggregatorV3Interface(aggregator).latestRoundData();
        vm.mockCall(
            aggregator,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(r, answer, started, block.timestamp, air)
        );
    }
}
