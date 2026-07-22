// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console2} from "forge-std/console2.sol";

import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {NAVCalculatorForkHarness} from "test/nav/fork/NAVCalculatorForkTestBase.fork.sol";

/// @notice Fork test: two real redundant price feeds for WBTC on Ethereum Mainnet.
///
/// Feed addresses:
///   Chainlink BTC/USD  — 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c  (1h heartbeat, 0.5% deviation)
///   Redstone  BTC/USD  — 0xAB7f623fb2F6fea6601D4350FA0E2290663C28Fc  (24h heartbeat, 0.5% deviation)
///
/// API3 WBTC/USD (0x041a131Fa91Ad61dD85262A42c04975986580d50) is omitted: the communal proxy
/// is not yet deployed on Ethereum mainnet. Register when it becomes live (PriceType.API3 handles
/// the 18-dec→8-dec normalisation automatically — no decimal-consistency conflict).
///
/// Staleness cascade:
///   +3 601 s  → Chainlink (1h) expires; Redstone (24h) survives and serves the real BTC price.
///   +86 401 s → every feed expires; latestPrice returns (0, 8, true).
contract WbtcMultiFeedForkTest is NAVCalculatorForkHarness {
    uint256 public constant FORK_BLOCK = 24_987_608;

    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // Chainlink BTC/USD — Ethereum Mainnet (1 h heartbeat, 0.5 % deviation)
    address public constant CHAINLINK_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    uint256 public constant CHAINLINK_HEARTBEAT = 3_600;

    // Redstone Classic Push BTC/USD — Ethereum Mainnet (24 h heartbeat, 0.5 % deviation)
    address public constant REDSTONE_BTC_USD = 0xAB7f623fb2F6fea6601D4350FA0E2290663C28Fc;
    uint256 public constant REDSTONE_HEARTBEAT = 86_400;

    // Maximum acceptable divergence between feeds at the fork block: 1 % (100 bps)
    uint256 public constant MAX_FEED_DIVERGENCE_BPS = 100;

    // ─── Harness hooks ─────────────────────────────────────────────────────────

    function setUp() public {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        setupNavCalculator();
    }

    function setupRegisterAssets() internal override {
        nav.registerAsset(WBTC, CHAINLINK_BTC_USD, IPrices.PriceType.Chainlink, CHAINLINK_HEARTBEAT);
        nav.addPriceFeed(WBTC, REDSTONE_BTC_USD, IPrices.PriceType.Redstone, REDSTONE_HEARTBEAT);
    }

    function setupBalanceAdapter() internal override {}

    // ─── Registration ──────────────────────────────────────────────────────────

    function test_twoFeedsRegistered() public view {
        IPrices.PriceFeedConfig[] memory feeds = nav.getPriceFeeds(WBTC);

        assertEq(feeds.length, 2);

        assertEq(feeds[0].priceFeed, CHAINLINK_BTC_USD);
        assertEq(uint8(feeds[0].priceType), uint8(IPrices.PriceType.Chainlink));
        assertEq(feeds[0].chainlinkHeartbeat, CHAINLINK_HEARTBEAT);
        assertEq(feeds[0].decimals, 8);

        assertEq(feeds[1].priceFeed, REDSTONE_BTC_USD);
        assertEq(uint8(feeds[1].priceType), uint8(IPrices.PriceType.Redstone));
        assertEq(feeds[1].chainlinkHeartbeat, REDSTONE_HEARTBEAT);
        assertEq(feeds[1].decimals, 8);
    }

    // ─── Healthy reads at fork block ───────────────────────────────────────────

    function test_latestPrice_notStale() public view {
        (int256 price, uint8 decimals, bool stale,) = nav.latestPrice(WBTC);

        assertFalse(stale);
        assertEq(decimals, 8);
        assertTrue(price > 10_000e8, "price below $10 000 at fork block");
        assertTrue(price < 1_000_000e8, "price above $1 000 000 at fork block");

        console2.log("WBTC latestPrice (USD):", uint256(price) / 1e8);
    }

    function test_getPriceData_logsWinningFeed() public view {
        INAVCalculator.PriceFeedData memory d = nav.getPriceData(WBTC);

        assertFalse(d.stale);
        assertFalse(d.sequencerDown);
        assertTrue(d.price > 0);

        console2.log("Winning feed       :", d.priceFeed);
        console2.log("PriceType          :", uint8(d.priceType), "(0=CL 1=RS)");
        console2.log("Winning price (USD):", uint256(d.price) / 1e8);
        console2.log("Winning updatedAt  :", d.updatedAt);
        console2.log("block.timestamp    :", block.timestamp);
    }

    // ─── Cross-feed price agreement ────────────────────────────────────────────

    /// Both feeds should quote BTC/USD within 1 % of each other at the fork block.
    function test_feedPricesAgreeWithinTolerance() public view {
        (, int256 chainlinkPrice,,,) = AggregatorV3Interface(CHAINLINK_BTC_USD).latestRoundData();
        (, int256 redstonePrice,,,) = AggregatorV3Interface(REDSTONE_BTC_USD).latestRoundData();

        assertTrue(chainlinkPrice > 0, "Chainlink price must be positive");
        assertTrue(redstonePrice > 0, "Redstone price must be positive");

        uint256 a = uint256(chainlinkPrice);
        uint256 b = uint256(redstonePrice);
        uint256 diff = a > b ? a - b : b - a;
        uint256 diffBps = diff * 10_000 / a;

        console2.log("Chainlink BTC/USD (USD):", a / 1e8);
        console2.log("Redstone  BTC/USD (USD):", b / 1e8);
        console2.log("Divergence (bps)       :", diffBps);

        assertLt(diffBps, MAX_FEED_DIVERGENCE_BPS, "Chainlink and Redstone BTC prices diverge by more than 1%");
    }

    // ─── Freshest-wins and staleness cascade ───────────────────────────────────

    /// After Chainlink's 1h heartbeat expires, Redstone (24h) wins and still returns
    /// the real on-chain BTC price.
    function test_redundancy_redstoneOutlastsChainlink() public {
        vm.warp(block.timestamp + CHAINLINK_HEARTBEAT + 1);

        (int256 price,, bool stale,) = nav.latestPrice(WBTC);
        INAVCalculator.PriceFeedData memory d = nav.getPriceData(WBTC);

        assertFalse(stale, "Redstone must keep the read healthy after Chainlink heartbeat expires");
        assertEq(d.priceFeed, REDSTONE_BTC_USD, "Redstone must be the winning feed");
        assertEq(uint8(d.priceType), uint8(IPrices.PriceType.Redstone));
        assertTrue(price > 10_000e8);

        console2.log("Winner after 1h warp :", d.priceFeed, "(Redstone, 24h heartbeat)");
        console2.log("Price (USD)          :", uint256(price) / 1e8);
    }

    /// After Redstone's 24h heartbeat expires every feed is stale.
    function test_allFeedsStale_after24hWarp() public {
        vm.warp(block.timestamp + REDSTONE_HEARTBEAT + 1);

        (int256 price,, bool stale,) = nav.latestPrice(WBTC);

        assertTrue(stale, "expected all-stale after 24h warp");
        assertEq(price, 0, "price must be 0 when all feeds are stale");
    }

    // ─── Constraints ───────────────────────────────────────────────────────────

    function test_cannotAddDuplicateFeed() public {
        vm.prank(admin);
        vm.expectRevert();
        nav.addPriceFeed(WBTC, CHAINLINK_BTC_USD, IPrices.PriceType.Chainlink, CHAINLINK_HEARTBEAT);
    }

    function test_cannotRemoveLastFeed() public {
        vm.startPrank(admin);
        nav.removePriceFeed(WBTC, CHAINLINK_BTC_USD);

        vm.expectRevert(); // CannotRemoveLastFeed
        nav.removePriceFeed(WBTC, REDSTONE_BTC_USD);
        vm.stopPrank();

        assertEq(nav.getPriceFeedCount(WBTC), 1);
        assertEq(nav.getPriceFeedAt(WBTC, 0).priceFeed, REDSTONE_BTC_USD);
    }
}
