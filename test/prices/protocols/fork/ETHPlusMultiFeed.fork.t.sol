// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console2} from "forge-std/console2.sol";

import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {NAVCalculatorForkHarness} from "test/nav/fork/NAVCalculatorForkTestBase.fork.sol";
import {Mock_PriceOracleChainlink} from "test/mocks/price_oracles.sol";
import {ETHPlus_PriceOracle, IBasketHandler, CollateralStatus} from "src/prices/protocols/ETHPlus_Price.sol";

/// @notice Fork test: four redundant price feeds for ETH+ — Custom (basket accounting),
/// Chainlink, Redstone (stub), and API3 (stub).
///
/// Context: the ETHPlus_PriceOracle custom adapter (Reserve Protocol basket accounting)
/// was the original pricing approach for ETH+. Once a direct Chainlink ETH+/USD feed
/// became available, production switched to it. This test registers both for redundancy,
/// demonstrating that a basket-IFFY event does not prevent NAV from being read and that
/// freshest-wins correctly selects the healthy feed.
///
/// Redstone and API3 are stubbed with local AggregatorV3 mocks (same on-chain interface).
/// Replace with real deployed addresses when confirmed:
///   Redstone Classic ETH+/USD (Ethereum) — https://app.redstone.finance/ → Classic feeds
///   API3 ETH+/USD dAPI proxy (Ethereum)  — https://market.api3.org/
///
/// Heartbeat design:
///   Custom (basket)  = 86 400 s  (24 h — RESERVE_PROTOCOL_HEARTBEAT)
///   Chainlink        = 86 400 s  (24 h)
///   Redstone stub    =  3 600 s  (1 h — shorter for test differentiation)
///   API3 stub        = 172 800 s (48 h — longest, outlasts all others)
///
/// Key scenarios tested:
///   basket IFFY      → custom skipped; Chainlink wins (direct fallback)
///   +3 601 s warp    → Redstone stub expires; custom + Chainlink + API3 still healthy
///   +86 401 s warp   → custom (basket heartbeat) + Chainlink + Redstone stale; API3 wins
///   +172 801 s warp  → every feed expires; latestPrice returns stale = true
contract ETHPlusMultiFeedForkTest is NAVCalculatorForkHarness {
    uint256 public constant FORK_BLOCK = 24_277_401;

    address public constant ETHPLUS = 0xE72B141DF173b999AE7c1aDcbF60Cc9833Ce56a8;

    // Chainlink ETH+/USD — Ethereum Mainnet (86 400 s heartbeat)
    address public constant CHAINLINK_ETHPLUS_USD = 0x66Ab900341C98de949EC31d11b3C4180743844F1;
    uint256 public constant CHAINLINK_HEARTBEAT = 86_400;

    uint256 public constant CUSTOM_HEARTBEAT = 86_400;
    uint256 public constant REDSTONE_HEARTBEAT = 3_600;
    uint256 public constant API3_HEARTBEAT = 172_800;

    // Stub price for Redstone and API3 mocks (≈$3 200 USD at fork block, 8 decimals)
    uint256 public constant STUB_ETHPLUS_PRICE = 3_200e8;

    // ─── Feed instances ────────────────────────────────────────────────────────

    ETHPlus_PriceOracle public customFeed; // real basket-accounting adapter
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
        // Deploy the real ETHPlus_PriceOracle (basket accounting, no stub)
        customFeed = new ETHPlus_PriceOracle(ETHPLUS, CUSTOM_HEARTBEAT);

        // Stubs fix _updatedAt = block.timestamp at construction (= fork block timestamp).
        // Staleness is therefore controllable via vm.warp without touching real feeds.
        redstoneFeed = new Mock_PriceOracleChainlink("Redstone ETH+/USD stub", STUB_ETHPLUS_PRICE, 8);
        api3Feed = new Mock_PriceOracleChainlink("API3 ETH+/USD stub", STUB_ETHPLUS_PRICE, 8);

        // Primary: custom basket-accounting oracle (original approach)
        nav.registerAsset(ETHPLUS, address(customFeed), IPrices.PriceType.Custom, CUSTOM_HEARTBEAT);
        // Direct Chainlink feed (production choice)
        nav.addPriceFeed(ETHPLUS, CHAINLINK_ETHPLUS_USD, IPrices.PriceType.Chainlink, CHAINLINK_HEARTBEAT);
        // Redundancy stubs
        nav.addPriceFeed(ETHPLUS, address(redstoneFeed), IPrices.PriceType.Redstone, REDSTONE_HEARTBEAT);
        nav.addPriceFeed(ETHPLUS, address(api3Feed), IPrices.PriceType.API3, API3_HEARTBEAT);
    }

    function setupBalanceOracle() internal override {}

    // ─── Registration ──────────────────────────────────────────────────────────

    function test_fourFeedsRegistered() public view {
        IPrices.PriceFeedConfig[] memory feeds = nav.getPriceFeeds(ETHPLUS);

        assertEq(feeds.length, 4);

        assertEq(feeds[0].priceFeed, address(customFeed));
        assertEq(uint8(feeds[0].priceType), uint8(IPrices.PriceType.Custom));
        assertEq(feeds[0].chainlinkHeartbeat, CUSTOM_HEARTBEAT);

        assertEq(feeds[1].priceFeed, CHAINLINK_ETHPLUS_USD);
        assertEq(uint8(feeds[1].priceType), uint8(IPrices.PriceType.Chainlink));
        assertEq(feeds[1].chainlinkHeartbeat, CHAINLINK_HEARTBEAT);

        assertEq(feeds[2].priceFeed, address(redstoneFeed));
        assertEq(uint8(feeds[2].priceType), uint8(IPrices.PriceType.Redstone));
        assertEq(feeds[2].chainlinkHeartbeat, REDSTONE_HEARTBEAT);

        assertEq(feeds[3].priceFeed, address(api3Feed));
        assertEq(uint8(feeds[3].priceType), uint8(IPrices.PriceType.API3));
        assertEq(feeds[3].chainlinkHeartbeat, API3_HEARTBEAT);
    }

    // ─── Healthy reads ─────────────────────────────────────────────────────────

    function test_latestPrice_notStale_atForkBlock() public view {
        (int256 price, uint8 decimals, bool stale) = nav.latestPrice(ETHPLUS);

        assertFalse(stale);
        assertEq(decimals, 8);
        assertTrue(price > 100e8, "price below $100 at fork block");
        assertTrue(price < 100_000e8, "price above $100 000 at fork block");

        console2.log("ETH+ latestPrice (USD):", uint256(price) / 1e8);
    }

    function test_getPriceData_logsWinningFeed() public view {
        INAVCalculator.PriceFeedData memory d = nav.getPriceData(ETHPLUS);

        assertFalse(d.stale);
        assertFalse(d.sequencerDown);
        assertTrue(d.price > 0);

        console2.log("Winning feed addr  :", d.priceFeed);
        console2.log("Winning PriceType  :", uint8(d.priceType), "(0=CL 1=Custom 2=RS 3=API3)");
        console2.log("Winning price (USD):", uint256(d.price) / 1e8);
        console2.log("Winning updatedAt  :", d.updatedAt);
        console2.log("block.timestamp    :", block.timestamp);
    }

    // ─── Basket-IFFY scenario ──────────────────────────────────────────────────

    /// When Reserve Protocol flags the ETH+ basket as IFFY, getLatestPrice() returns
    /// stale=true and the custom feed is skipped. The Chainlink ETH+/USD feed becomes
    /// the active price source, keeping the NAV read healthy.
    function test_chainlinkFallback_whenCustomFeedBasketIffy() public {
        // Remove stubs so Chainlink is the only non-custom candidate; makes winner deterministic.
        vm.startPrank(admin);
        nav.removePriceFeed(ETHPLUS, address(redstoneFeed));
        nav.removePriceFeed(ETHPLUS, address(api3Feed));
        vm.stopPrank();

        address basketHandlerAddr = _basketHandlerAddress();
        vm.mockCall(
            basketHandlerAddr, abi.encodeWithSelector(IBasketHandler.status.selector), abi.encode(CollateralStatus.IFFY)
        );

        (int256 price,, bool stale) = nav.latestPrice(ETHPLUS);
        INAVCalculator.PriceFeedData memory d = nav.getPriceData(ETHPLUS);

        assertFalse(stale, "Chainlink must keep the read healthy when basket is IFFY");
        assertTrue(price > 0);
        assertEq(d.priceFeed, CHAINLINK_ETHPLUS_USD, "Chainlink must win");
        assertEq(uint8(d.priceType), uint8(IPrices.PriceType.Chainlink), "priceType must be Chainlink");

        console2.log("Winner when basket IFFY:", d.priceFeed);
        console2.log("Price (USD)            :", uint256(d.price) / 1e8);
    }

    // ─── Freshest-wins and staleness ───────────────────────────────────────────

    /// Warp forward 1 hour + 1 second.
    /// Redstone stub (heartbeat 1 h) expires; custom + Chainlink + API3 still healthy.
    function test_redstoneFeedExpires_after1hWarp() public {
        vm.warp(block.timestamp + REDSTONE_HEARTBEAT + 1);

        (int256 price,, bool stale) = nav.latestPrice(ETHPLUS);
        INAVCalculator.PriceFeedData memory d = nav.getPriceData(ETHPLUS);

        assertFalse(stale, "three feeds still healthy after 1h warp");
        assertTrue(price > 0);
        assertNotEq(d.priceFeed, address(redstoneFeed), "Redstone stub must not win after its heartbeat expired");

        console2.log("Winner after 1h warp:", d.priceFeed);
    }

    /// Warp forward 86 401 s (past the 24 h window).
    /// Custom feed is stale (block.timestamp - lastSave > RESERVE_PROTOCOL_HEARTBEAT).
    /// Chainlink ETH+/USD is stale (block.timestamp - updatedAt > 86 400 s).
    /// Redstone stub (1 h) is stale.
    /// Only the API3 stub (48 h heartbeat, updatedAt = fork block timestamp) survives.
    function test_redundancy_api3OutlastsOthers_after86401sWarp() public {
        vm.warp(block.timestamp + CHAINLINK_HEARTBEAT + 1);

        (int256 price,, bool stale) = nav.latestPrice(ETHPLUS);
        INAVCalculator.PriceFeedData memory d = nav.getPriceData(ETHPLUS);

        assertFalse(stale, "API3 stub should keep the read healthy after 86 401 s warp");
        assertEq(d.priceFeed, address(api3Feed), "API3 stub must win after others expire");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(price, int256(STUB_ETHPLUS_PRICE), "price must come from the API3 stub");

        console2.log("Winner after 86 401 s warp:", d.priceFeed, "(API3 stub, 48 h heartbeat)");
    }

    /// Warp forward 48 hours + 1 second — every feed exceeds its heartbeat.
    function test_allFeedsStale_after48hWarp() public {
        vm.warp(block.timestamp + API3_HEARTBEAT + 1);

        (int256 price,, bool stale) = nav.latestPrice(ETHPLUS);

        assertTrue(stale, "expected all-stale after 48 h warp");
        assertEq(price, 0, "price must be 0 when all feeds are stale");
    }

    // ─── Constraints ───────────────────────────────────────────────────────────

    function test_cannotAddDuplicateFeed() public {
        vm.prank(admin);
        vm.expectRevert();
        nav.addPriceFeed(ETHPLUS, address(customFeed), IPrices.PriceType.Custom, CUSTOM_HEARTBEAT);
    }

    /// Remove three feeds one by one; the final removal must revert with CannotRemoveLastFeed.
    function test_cannotRemoveLastFeed() public {
        vm.startPrank(admin);
        nav.removePriceFeed(ETHPLUS, address(customFeed));
        nav.removePriceFeed(ETHPLUS, CHAINLINK_ETHPLUS_USD);
        nav.removePriceFeed(ETHPLUS, address(redstoneFeed));

        vm.expectRevert(); // CannotRemoveLastFeed
        nav.removePriceFeed(ETHPLUS, address(api3Feed));
        vm.stopPrank();

        assertEq(nav.getPriceFeedCount(ETHPLUS), 1);
        assertEq(nav.getPriceFeedAt(ETHPLUS, 0).priceFeed, address(api3Feed));
    }

    // ─── Helpers ───────────────────────────────────────────────────────────────

    function _basketHandlerAddress() internal view returns (address) {
        (bool ok, bytes memory data) = ETHPLUS.staticcall(abi.encodeWithSignature("main()"));
        require(ok, "main() call failed");
        address mainAddr = abi.decode(data, (address));
        (ok, data) = mainAddr.staticcall(abi.encodeWithSignature("basketHandler()"));
        require(ok, "basketHandler() call failed");
        return abi.decode(data, (address));
    }
}
