// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console2} from "forge-std/console2.sol";

import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {NAVCalculatorForkHarness} from "test/nav/fork/NAVCalculatorForkTestBase.fork.sol";
import {Mock_PriceOracleChainlink} from "test/mocks/price_oracles.sol";

/// @notice Fork test: three redundant price feeds for WBTC — Chainlink, Redstone, API3.
///
/// Redstone and API3 are stubbed with local AggregatorV3 mocks (same on-chain interface shape).
/// Replace `redstoneFeed` / `api3Feed` with real deployed addresses when confirmed:
///   Redstone Classic BTC/USD (Ethereum) — https://app.redstone.finance/ → Classic feeds
///   API3 WBTC/USD dAPI proxy (Ethereum) — https://market.api3.org/
///
/// Heartbeat design:
///   Chainlink / Redstone = 3 600 s   (1 h)
///   API3                 = 86 400 s  (24 h)
///
/// The heartbeat difference lets us demonstrate redundancy with a simple vm.warp:
///   +3 601 s  → Chainlink and Redstone stub expire; API3 stub (24 h) survives and wins.
///   +86 401 s → every feed expires; latestPrice returns stale = true.
contract WbtcMultiFeedForkTest is NAVCalculatorForkHarness {
    uint256 public constant FORK_BLOCK = 24_987_608;

    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // Chainlink BTC/USD — Ethereum Mainnet
    // 1 h heartbeat, 0.5 % deviation threshold
    address public constant CHAINLINK_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    uint256 public constant CHAINLINK_HEARTBEAT = 3_600;

    uint256 public constant REDSTONE_HEARTBEAT = 3_600;
    uint256 public constant API3_HEARTBEAT = 86_400;

    // Stub price for the Redstone and API3 mocks (~$95 000 at the fork block, 8 decimals)
    uint256 public constant STUB_BTC_PRICE = 95_000e8;

    // ─── Feed instances ────────────────────────────────────────────────────────

    Mock_PriceOracleChainlink public redstoneFeed; // AggregatorV3 stub — Redstone shape
    Mock_PriceOracleChainlink public api3Feed; // AggregatorV3 stub — API3 shape

    // ─── Harness hooks ─────────────────────────────────────────────────────────

    function setUp() public {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        setupNavCalculator();
    }

    function setupRegisterAssets() internal override {
        // Stubs fix _updatedAt = block.timestamp at construction (= fork block timestamp).
        // Staleness is therefore controllable via vm.warp without touching the real feeds.
        redstoneFeed = new Mock_PriceOracleChainlink("Redstone BTC/USD stub", STUB_BTC_PRICE, 8);
        api3Feed = new Mock_PriceOracleChainlink("API3 WBTC/USD stub", STUB_BTC_PRICE, 8);

        // Primary: real Chainlink BTC/USD on-chain feed
        nav.registerAsset(WBTC, CHAINLINK_BTC_USD, IPrices.PriceType.Chainlink, CHAINLINK_HEARTBEAT);

        // Redundancy feeds
        nav.addPriceFeed(WBTC, address(redstoneFeed), IPrices.PriceType.Redstone, REDSTONE_HEARTBEAT);
        nav.addPriceFeed(WBTC, address(api3Feed), IPrices.PriceType.API3, API3_HEARTBEAT);
    }

    function setupBalanceOracle() internal override {} // price-only test

    // ─── Registration ──────────────────────────────────────────────────────────

    function test_threeFeedsRegistered() public view {
        IPrices.PriceFeedConfig[] memory feeds = nav.getPriceFeeds(WBTC);

        assertEq(feeds.length, 3);

        assertEq(feeds[0].priceFeed, CHAINLINK_BTC_USD);
        assertEq(uint8(feeds[0].priceType), uint8(IPrices.PriceType.Chainlink));
        assertEq(feeds[0].chainlinkHeartbeat, CHAINLINK_HEARTBEAT);
        assertEq(feeds[0].decimals, 8);

        assertEq(feeds[1].priceFeed, address(redstoneFeed));
        assertEq(uint8(feeds[1].priceType), uint8(IPrices.PriceType.Redstone));
        assertEq(feeds[1].chainlinkHeartbeat, REDSTONE_HEARTBEAT);

        assertEq(feeds[2].priceFeed, address(api3Feed));
        assertEq(uint8(feeds[2].priceType), uint8(IPrices.PriceType.API3));
        assertEq(feeds[2].chainlinkHeartbeat, API3_HEARTBEAT);
    }

    // ─── Healthy reads ─────────────────────────────────────────────────────────

    function test_latestPrice_notStale() public view {
        (int256 price, uint8 decimals, bool stale) = nav.latestPrice(WBTC);

        assertFalse(stale);
        assertEq(decimals, 8);
        assertTrue(price > 10_000e8, "price below $10 000 at fork block");
        assertTrue(price < 1_000_000e8, "price above $1 000 000 at fork block");

        console2.log("WBTC latestPrice (USD) :", uint256(price) / 1e8);
    }

    /// getPriceData returns the full context of the winning feed, including which one it is.
    /// PriceType enum: 0=Chainlink 1=Custom 2=Redstone 3=API3
    function test_getPriceData_logsWinningFeed() public view {
        INAVCalculator.PriceFeedData memory d = nav.getPriceData(WBTC);

        assertFalse(d.stale);
        assertFalse(d.sequencerDown);
        assertTrue(d.price > 0);

        console2.log("Winning feed addr  :", d.priceFeed);
        console2.log("Winning PriceType  :", uint8(d.priceType), "(0=CL 2=RS 3=API3)");
        console2.log("Winning price (USD):", uint256(d.price) / 1e8);
        console2.log("Winning updatedAt  :", d.updatedAt);
        console2.log("block.timestamp    :", block.timestamp);
    }

    // ─── Freshest-wins and staleness ───────────────────────────────────────────

    /// Warp forward by 1 hour + 1 second.
    /// Chainlink (heartbeat 1h) and Redstone stub (1h) expire.
    /// API3 stub (heartbeat 24h, _updatedAt = fork block timestamp) survives and wins.
    function test_redundancy_api3OutlastsShortHeartbeatFeeds() public {
        vm.warp(block.timestamp + CHAINLINK_HEARTBEAT + 1);

        (int256 price,, bool stale) = nav.latestPrice(WBTC);
        INAVCalculator.PriceFeedData memory d = nav.getPriceData(WBTC);

        assertFalse(stale, "API3 stub should keep the read healthy after 1h warp");
        assertEq(d.priceFeed, address(api3Feed), "API3 stub should win after others expire");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(price, int256(STUB_BTC_PRICE), "winning price should come from the API3 stub");

        console2.log("Winner after 1h warp:", d.priceFeed, "(API3 stub, 24h heartbeat)");
    }

    /// Warp forward by 24 hours + 1 second — every feed exceeds its heartbeat.
    function test_allFeedsStale_after24hWarp() public {
        vm.warp(block.timestamp + API3_HEARTBEAT + 1);

        (int256 price,, bool stale) = nav.latestPrice(WBTC);

        assertTrue(stale, "expected all-stale after 24h warp");
        assertEq(price, 0, "price must be 0 when all feeds are stale");
    }

    // ─── Constraints ───────────────────────────────────────────────────────────

    function test_cannotAddDuplicateFeed() public {
        vm.prank(admin);
        vm.expectRevert();
        nav.addPriceFeed(WBTC, CHAINLINK_BTC_USD, IPrices.PriceType.Chainlink, CHAINLINK_HEARTBEAT);
    }

    /// Remove two feeds one by one; the third removal must revert with CannotRemoveLastFeed.
    function test_cannotRemoveLastFeed() public {
        vm.startPrank(admin);
        nav.removePriceFeed(WBTC, CHAINLINK_BTC_USD);
        nav.removePriceFeed(WBTC, address(redstoneFeed));

        vm.expectRevert(); // CannotRemoveLastFeed
        nav.removePriceFeed(WBTC, address(api3Feed));
        vm.stopPrank();

        assertEq(nav.getPriceFeedCount(WBTC), 1);
        assertEq(nav.getPriceFeedAt(WBTC, 0).priceFeed, address(api3Feed));
    }
}
