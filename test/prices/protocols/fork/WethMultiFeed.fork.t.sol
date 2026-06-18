// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console2} from "forge-std/console2.sol";

import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {NAVCalculatorForkHarness} from "test/nav/fork/NAVCalculatorForkTestBase.fork.sol";

/// @notice Fork test: Chainlink + API3 redundant price feeds for WETH on Ethereum Mainnet.
///
/// Feed addresses:
///   Chainlink ETH/USD  — 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419  (1h heartbeat, 0.5% deviation, 8 dec)
///   API3 ETH/USD       — 0x5b0cf2b36a65a6BB085D501B971e4c102B9Cd473  (24h heartbeat, 1% deviation, 18 dec proxy → stored as 8 dec)
///
/// PriceFeedLib scales the 18-dec API3 proxy answer by ÷1e10 at read time so both feeds
/// report the same 8-decimal USD price, passing the decimal-consistency guard.
///
/// Staleness cascade:
///   +3 601 s  → Chainlink (1h) expires; API3 (24h) survives and serves the real ETH price.
///   +86 401 s → every feed expires; latestPrice returns (0, 8, true).
contract WethMultiFeedForkTest is NAVCalculatorForkHarness {
    uint256 public constant FORK_BLOCK = 24_987_608;

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Chainlink ETH/USD — Ethereum Mainnet (1h heartbeat, 0.5% deviation)
    address public constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 public constant CHAINLINK_HEARTBEAT = 3_600;

    // API3 ETH/USD communal proxy — Ethereum Mainnet (24h heartbeat, 1% deviation, 18 dec)
    address public constant API3_ETH_USD = 0x5b0cf2b36a65a6BB085D501B971e4c102B9Cd473;
    uint256 public constant API3_HEARTBEAT = 86_400;

    // Maximum acceptable divergence between feeds at the fork block: 1% (100 bps)
    uint256 public constant MAX_FEED_DIVERGENCE_BPS = 100;

    // ─── Harness hooks ─────────────────────────────────────────────────────────

    function setUp() public {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        setupNavCalculator();
    }

    function setupRegisterAssets() internal override {
        nav.registerAsset(WETH, CHAINLINK_ETH_USD, IPrices.PriceType.Chainlink, CHAINLINK_HEARTBEAT);
        nav.addPriceFeed(WETH, API3_ETH_USD, IPrices.PriceType.API3, API3_HEARTBEAT);
    }

    function setupBalanceAdapter() internal override {}

    // ─── Registration ──────────────────────────────────────────────────────────

    function test_twoFeedsRegistered() public view {
        IPrices.PriceFeedConfig[] memory feeds = nav.getPriceFeeds(WETH);

        assertEq(feeds.length, 2);

        assertEq(feeds[0].priceFeed, CHAINLINK_ETH_USD);
        assertEq(uint8(feeds[0].priceType), uint8(IPrices.PriceType.Chainlink));
        assertEq(feeds[0].chainlinkHeartbeat, CHAINLINK_HEARTBEAT);
        assertEq(feeds[0].decimals, 8);

        assertEq(feeds[1].priceFeed, API3_ETH_USD);
        assertEq(uint8(feeds[1].priceType), uint8(IPrices.PriceType.API3));
        assertEq(feeds[1].chainlinkHeartbeat, API3_HEARTBEAT);
        assertEq(feeds[1].decimals, 8, "API3 18-dec proxy must be stored as 8-dec");
    }

    // ─── Healthy reads at fork block ───────────────────────────────────────────

    function test_latestPrice_notStale() public view {
        (int256 price, uint8 decimals, bool stale) = nav.latestPrice(WETH);

        assertFalse(stale);
        assertEq(decimals, 8);
        assertTrue(price > 500e8, "ETH price below $500 at fork block");
        assertTrue(price < 10_000e8, "ETH price above $10 000 at fork block");

        console2.log("WETH latestPrice (USD):", uint256(price) / 1e8);
    }

    function test_getPriceData_logsWinningFeed() public view {
        INAVCalculator.PriceFeedData memory d = nav.getPriceData(WETH);

        assertFalse(d.stale);
        assertFalse(d.sequencerDown);
        assertTrue(d.price > 0);

        console2.log("Winning feed       :", d.priceFeed);
        console2.log("PriceType          :", uint8(d.priceType), "(0=CL 2=API3)");
        console2.log("Winning price (USD):", uint256(d.price) / 1e8);
        console2.log("Winning updatedAt  :", d.updatedAt);
        console2.log("block.timestamp    :", block.timestamp);
    }

    // ─── Cross-feed price agreement ────────────────────────────────────────────

    /// Both feeds should quote ETH/USD within 1% of each other at the fork block.
    function test_feedPricesAgreeWithinTolerance() public view {
        (, int256 chainlinkPrice,,,) = AggregatorV3Interface(CHAINLINK_ETH_USD).latestRoundData();
        (, int256 api3RawPrice,,,) = AggregatorV3Interface(API3_ETH_USD).latestRoundData();

        assertTrue(chainlinkPrice > 0, "Chainlink price must be positive");
        assertTrue(api3RawPrice > 0, "API3 raw price must be positive");

        // API3 proxy returns 18-dec; normalise to 8-dec for comparison.
        int256 api3Price = api3RawPrice / 1e10;

        uint256 a = uint256(chainlinkPrice);
        uint256 b = uint256(api3Price);
        uint256 diff = a > b ? a - b : b - a;
        uint256 diffBps = diff * 10_000 / a;

        console2.log("Chainlink ETH/USD (USD):", a / 1e8);
        console2.log("API3      ETH/USD (USD):", b / 1e8);
        console2.log("Divergence (bps)       :", diffBps);

        assertLt(diffBps, MAX_FEED_DIVERGENCE_BPS, "Chainlink and API3 ETH prices diverge by more than 1%");
    }

    // ─── Freshest-wins and staleness cascade ───────────────────────────────────

    /// After Chainlink's 1h heartbeat expires, API3 (24h) wins and still returns
    /// the real on-chain ETH price.
    function test_redundancy_API3OutlastsChainlink() public {
        vm.warp(block.timestamp + CHAINLINK_HEARTBEAT + 1);

        (int256 price,, bool stale) = nav.latestPrice(WETH);
        INAVCalculator.PriceFeedData memory d = nav.getPriceData(WETH);

        assertFalse(stale, "API3 must keep the read healthy after Chainlink heartbeat expires");
        assertEq(d.priceFeed, API3_ETH_USD, "API3 must be the winning feed");
        assertEq(uint8(d.priceType), uint8(IPrices.PriceType.API3));
        assertTrue(price > 500e8);

        console2.log("Winner after 1h warp :", d.priceFeed, "(API3, 24h heartbeat)");
        console2.log("Price (USD)          :", uint256(price) / 1e8);
    }

    /// After API3's 24h heartbeat expires every feed is stale.
    function test_allFeedsStale_after86400Warp() public {
        vm.warp(block.timestamp + API3_HEARTBEAT + 1);

        (int256 price,, bool stale) = nav.latestPrice(WETH);

        assertTrue(stale, "expected all-stale after 24h warp");
        assertEq(price, 0, "price must be 0 when all feeds are stale");
    }

    // ─── Constraints ───────────────────────────────────────────────────────────

    function test_cannotAddDuplicateFeed() public {
        vm.prank(admin);
        vm.expectRevert();
        nav.addPriceFeed(WETH, CHAINLINK_ETH_USD, IPrices.PriceType.Chainlink, CHAINLINK_HEARTBEAT);
    }

    function test_cannotRemoveLastFeed() public {
        vm.startPrank(admin);
        nav.removePriceFeed(WETH, CHAINLINK_ETH_USD);

        vm.expectRevert(); // CannotRemoveLastFeed
        nav.removePriceFeed(WETH, API3_ETH_USD);
        vm.stopPrank();

        assertEq(nav.getPriceFeedCount(WETH), 1);
        assertEq(nav.getPriceFeedAt(WETH, 0).priceFeed, API3_ETH_USD);
    }
}
