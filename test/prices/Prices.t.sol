// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

import {Prices} from "src/prices/Prices.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {
    Mock_ChainlinkL2SequencerUptimeFeed,
    Mock_ChainlinkL2SequencerUptimeFeedUninitialized,
    Mock_CustomPriceFeed,
    Mock_PriceOracleChainlink,
    Mock_CustomPriceFeedStaled
} from "test/mocks/price_oracles.sol";

contract Mock_CustomPriceFeedZeroUpdatedAt is Mock_CustomPriceFeed {
    constructor() Mock_CustomPriceFeed("zero_upd", address(0x1234), 100_000_000, 8) {}

    function latestRoundData() external pure override returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 0, 0, 0, 0); // updatedAt = 0 → sentinel: treated as block.timestamp-1
    }
}

contract PricesHarness is Prices {
    constructor(address chainlinkUptimeFeed) initializer {
        __Prices_init(chainlinkUptimeFeed);
    }

    function setPriceOracle(address token, address oracle, uint256 chainlinkHeartbeat, IPrices.PriceType oracleType)
        public
    {
        _addPriceFeed(token, oracle, chainlinkHeartbeat, oracleType);
    }

    function setPriceFeed(address token, address oracle, uint256 chainlinkHeartbeat, IPrices.PriceType oracleType)
        public
    {
        _addPriceFeed(token, oracle, chainlinkHeartbeat, oracleType);
    }

    function removePriceOracle(address token) public {
        _removeAllPriceFeeds(token);
    }

    function removePriceFeedAt(address token, uint256 index) public {
        _removePriceFeedAt(token, index);
    }

    function removePriceFeedByAddr(address token, address feed) public {
        _removePriceFeed(token, feed);
    }
}

contract PricesTest is Test {
    PricesHarness public manager;
    PricesHarness public managerL2;
    Mock_PriceOracleChainlink chainlinkUptimeFeed;
    Mock_CustomPriceFeed public oracleusdc;
    Mock_PriceOracleChainlink public oracleaBuidl;
    Mock_PriceOracleChainlink public disabledUptimeFeed;
    Mock_ChainlinkL2SequencerUptimeFeed public enabledUptimeFeed;
    Mock_ChainlinkL2SequencerUptimeFeedUninitialized public uninitializedUptimeFeed;
    Mock_CustomPriceFeedStaled public customStaled;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address usdc = makeAddr("usdc");
    address buidl = makeAddr("buidl");

    function setUp() public {
        // PriceFeedLib is pre-linked at this deterministic CREATE2 address (foundry.toml libraries config).
        // In tests there's no chain state, so etch the runtime code there so DELEGATECALL succeeds.
        address priceFeedLibImpl = vm.deployCode("PriceFeedLib.sol:PriceFeedLib");
        vm.etch(0x8d8C2aba9A9a3898285F81b95F332FB4B88ab72B, priceFeedLibImpl.code);
        vm.etch(0x02F27E28452E6F419b97935f6346381E2b5003B1, vm.deployCode("NavRegistryLib.sol:NavRegistryLib").code);

        oracleusdc = new Mock_CustomPriceFeed("usdc", address(usdc), 100_000_000, 8);
        oracleaBuidl = new Mock_PriceOracleChainlink("buidl", 1000, 8);
        disabledUptimeFeed = new Mock_PriceOracleChainlink("UptimeFeed", 1, 8);
        enabledUptimeFeed = new Mock_ChainlinkL2SequencerUptimeFeed();
        uninitializedUptimeFeed = new Mock_ChainlinkL2SequencerUptimeFeedUninitialized();
        manager = new PricesHarness(address(0));
        managerL2 = new PricesHarness(address(chainlinkUptimeFeed));
        customStaled = new Mock_CustomPriceFeedStaled("usdc", address(usdc), 100_000_000, 8);
    }

    function test_latestPrice_WithNonStalePrices() public {
        manager.setPriceFeed(usdc, address(oracleusdc), type(uint256).max, IPrices.PriceType.Custom);
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);

        vm.startPrank(alice);
        (int256 value, uint8 decimals, bool stale) = manager.latestPrice(usdc);
        assertEq(value, 100_000_000);
        assertEq(decimals, 8);
        assertFalse(stale);

        (value, decimals, stale) = manager.latestPrice(buidl);
        assertEq(value, 1000);
        assertEq(decimals, 8);
        assertFalse(stale);

        vm.stopPrank();
    }

    function test_latestPrice_BeforeGracePeriod() public {
        manager = new PricesHarness(address(disabledUptimeFeed));
        manager.setPriceFeed(usdc, address(oracleusdc), type(uint256).max, IPrices.PriceType.Custom);
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);

        vm.startPrank(alice);
        (int256 value, uint8 decimals, bool stale) = manager.latestPrice(usdc);
        assertEq(value, 100_000_000);
        assertEq(decimals, 8);
        assertTrue(stale);

        (value, decimals, stale) = manager.latestPrice(buidl);
        assertEq(value, 1000);
        assertEq(decimals, 8);
        assertTrue(stale);

        vm.stopPrank();
    }

    function test_latestPrice_AfterHearBeat() public {
        // Chainlink: stale when block.timestamp - latestRoundData().updatedAt > heartbeat.
        // Custom: stale is determined solely by getLatestPrice().stale (per-feed checks inside the adapter).
        manager.setPriceFeed(usdc, address(oracleusdc), type(uint256).max, IPrices.PriceType.Custom);
        manager.setPriceFeed(buidl, address(oracleaBuidl), 1, IPrices.PriceType.Chainlink);

        vm.warp(block.timestamp + 2);

        vm.startPrank(alice);
        // Custom feed: mock always returns stale=false from getLatestPrice() — not stale by heartbeat.
        (int256 value, uint8 decimals, bool stale) = manager.latestPrice(usdc);
        assertEq(value, 100_000_000);
        assertEq(decimals, 8);
        assertFalse(stale);

        // Chainlink feed: updatedAt is stale after warp past heartbeat=1.
        // New multi-feed behaviour: all feeds stale → price=0 (not the stale value).
        (value, decimals, stale) = manager.latestPrice(buidl);
        assertEq(value, 0);
        assertEq(decimals, 8);
        assertTrue(stale);

        vm.stopPrank();
    }

    function test_latestPrice_CustomOracleStaled() public {
        // Mock_CustomPriceFeedStaled.getLatestPrice() returns stale=true — always stale.
        manager.setPriceFeed(usdc, address(customStaled), 1, IPrices.PriceType.Custom);
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);

        vm.warp(2);

        vm.startPrank(alice);
        // New multi-feed behaviour: all feeds stale → price=0 (not the stale value).
        (int256 value, uint8 decimals, bool stale) = manager.latestPrice(usdc);
        assertEq(value, 0);
        assertEq(decimals, 8);
        assertTrue(stale); // stale: getLatestPrice() returns stale=true

        (value, decimals, stale) = manager.latestPrice(buidl);
        assertEq(value, 1000);
        assertEq(decimals, 8);
        assertFalse(stale);

        vm.stopPrank();
    }

    function test_RevertIf_OracleNotSet() public {
        vm.expectRevert();
        manager.latestPrice(usdc);
    }

    function test_setPriceFeed_Chainlink() public {
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);
    }

    function test_setPriceFeed_CustomOracle() public {
        manager.setPriceFeed(usdc, address(oracleusdc), type(uint256).max, IPrices.PriceType.Custom);
    }

    function test_unsetPriceFeed() public {
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);
        manager.removePriceOracle(buidl);

        assertEq(manager.getPriceFeedCount(buidl), 0);
    }

    function test_CheckCustomOracleSupport_ValidCustomOracle() public view {
        manager.checkPriceOracleSupport(address(usdc), address(oracleusdc), IPrices.PriceType.Custom);
        manager.checkPriceOracleSupport(address(usdc), address(oracleaBuidl), IPrices.PriceType.Chainlink);
    }

    function test_RevertIf_InvalidOracleTypeCL() public {
        vm.expectRevert();
        manager.checkPriceOracleSupport(address(usdc), address(oracleusdc), IPrices.PriceType.Chainlink);
    }

    function test_RevertIf_CheckCustomOracleSupport_InvalidOracleTypeCM() public {
        vm.expectRevert();
        manager.checkPriceOracleSupport(address(usdc), address(oracleaBuidl), IPrices.PriceType.Custom);
    }

    // ============================================
    // Price Feed Management Tests
    // ============================================

    function test_setPriceFeed_zeroAddress() public {
        vm.expectRevert();
        manager.setPriceFeed(usdc, address(0), type(uint256).max, IPrices.PriceType.Custom);
    }

    function test_setPriceFeed_invalidOracleType() public {
        vm.expectRevert();
        manager.setPriceFeed(usdc, address(oracleusdc), type(uint256).max, IPrices.PriceType.Chainlink);
    }

    function test_setPriceFeed_zeroHeartbeat_chainlink() public {
        vm.expectRevert();
        manager.setPriceFeed(buidl, address(oracleaBuidl), 0, IPrices.PriceType.Chainlink);
    }

    function test_setPriceFeed_zeroHeartbeat_custom() public {
        vm.expectRevert();
        manager.setPriceFeed(usdc, address(oracleusdc), 0, IPrices.PriceType.Custom);
    }

    function test_unsetPriceFeed_notSet() public {
        // Unsetting non-existent feed should not revert (delete on non-existent mapping is safe)
        manager.removePriceOracle(usdc);
        assertEq(manager.getPriceFeedCount(usdc), 0);
    }

    // ============================================
    // Getters Tests
    // ============================================

    function test_priceOracles() public {
        manager.setPriceFeed(usdc, address(oracleusdc), type(uint256).max, IPrices.PriceType.Custom);

        IPrices.PriceFeedConfig memory cfg = manager.getPriceFeedAt(usdc, 0);
        assertEq(cfg.priceFeed, address(oracleusdc));
        assertEq(cfg.decimals, 8);
        assertEq(cfg.chainlinkHeartbeat, type(uint256).max);
        assertEq(uint8(cfg.priceType), uint8(IPrices.PriceType.Custom));
    }

    function test_chainlinkL2SequencerUptimeFeed() public view {
        address uptimeFeed = address(manager.chainlinkL2SequencerUptimeFeed());
        // For manager (L1), should be address(0)
        assertEq(uptimeFeed, address(0));
    }

    function test_chainlinkL2SequencerGracePeriod() public view {
        uint256 gracePeriod = manager.chainlinkL2SequencerGracePeriod();
        assertEq(gracePeriod, 1 hours);
    }

    // ============================================
    // Edge Cases Tests
    // ============================================

    function test_setPriceFeed_zeroPrice_reverts() public {
        // A zero-price feed is rejected at registration time
        Mock_PriceOracleChainlink zeroPriceOracle = new Mock_PriceOracleChainlink("Zero", 0, 8);
        vm.expectRevert(IPrices.InvalidPriceOracle.selector);
        manager.setPriceFeed(buidl, address(zeroPriceOracle), type(uint256).max, IPrices.PriceType.Chainlink);
    }

    function test_checkL2SequencerUptime_noFeed() public view {
        // manager has no uptime feed (L1 scenario)
        bool stale = manager.checkL2SequencerUptime();
        assertFalse(stale); // Should return false when no feed is set
    }

    function test_checkL2SequencerUptime_withinGracePeriod() public {
        // Create manager with uptime feed
        managerL2 = new PricesHarness(address(disabledUptimeFeed));

        // The uptime feed is disabled (answer = 1), so sequencer is down
        bool stale = managerL2.checkL2SequencerUptime();
        assertTrue(stale);
    }

    function test_checkL2SequencerUptime_initializedUpAfterGracePeriod() public {
        managerL2 = new PricesHarness(address(enabledUptimeFeed));
        vm.warp(block.timestamp + 2 hours + 1);

        bool stale = managerL2.checkL2SequencerUptime();
        assertFalse(stale);
    }

    function test_checkL2SequencerUptime_uninitializedStartedAtZero() public {
        managerL2 = new PricesHarness(address(uninitializedUptimeFeed));

        bool stale = managerL2.checkL2SequencerUptime();
        assertTrue(stale);
    }

    // ============================================
    // Multi-feed Tests
    // ============================================

    function test_multiFeed_registration() public {
        assertEq(manager.getPriceFeedCount(buidl), 0);
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);
        assertEq(manager.getPriceFeedCount(buidl), 1);

        Mock_PriceOracleChainlink oracle2 = new Mock_PriceOracleChainlink("b", 200, 8);
        Mock_PriceOracleChainlink oracle3 = new Mock_PriceOracleChainlink("c", 300, 8);
        manager.setPriceFeed(buidl, address(oracle2), type(uint256).max, IPrices.PriceType.Chainlink);
        manager.setPriceFeed(buidl, address(oracle3), type(uint256).max, IPrices.PriceType.Chainlink);

        assertEq(manager.getPriceFeedCount(buidl), 3);

        IPrices.PriceFeedConfig[] memory feeds = manager.getPriceFeeds(buidl);
        assertEq(feeds.length, 3);
        assertEq(feeds[0].priceFeed, address(oracleaBuidl));
        assertEq(feeds[1].priceFeed, address(oracle2));
        assertEq(feeds[2].priceFeed, address(oracle3));
    }

    function test_multiFeed_cannotRemoveLastFeed() public {
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);

        vm.expectRevert(abi.encodeWithSelector(IPrices.CannotRemoveLastFeed.selector, buidl));
        manager.removePriceFeedAt(buidl, 0);
    }

    function test_multiFeed_removePriceFeedAt_swapWithLast() public {
        Mock_PriceOracleChainlink oracle2 = new Mock_PriceOracleChainlink("b", 200, 8);
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink); // index 0
        manager.setPriceFeed(buidl, address(oracle2), type(uint256).max, IPrices.PriceType.Chainlink); // index 1

        // Remove index 0: oracle2 swapped to index 0 (swap-with-last).
        manager.removePriceFeedAt(buidl, 0);

        assertEq(manager.getPriceFeedCount(buidl), 1);
        assertEq(manager.getPriceFeedAt(buidl, 0).priceFeed, address(oracle2));
    }

    function test_multiFeed_removePriceFeed_byAddress() public {
        Mock_PriceOracleChainlink oracle2 = new Mock_PriceOracleChainlink("b", 200, 8);
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);
        manager.setPriceFeed(buidl, address(oracle2), type(uint256).max, IPrices.PriceType.Chainlink);

        manager.removePriceFeedByAddr(buidl, address(oracleaBuidl));

        assertEq(manager.getPriceFeedCount(buidl), 1);
        assertEq(manager.getPriceFeedAt(buidl, 0).priceFeed, address(oracle2));
    }

    function test_multiFeed_removePriceFeed_notFound() public {
        Mock_PriceOracleChainlink oracle2 = new Mock_PriceOracleChainlink("b", 200, 8);
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);
        manager.setPriceFeed(buidl, address(oracle2), type(uint256).max, IPrices.PriceType.Chainlink);

        address nonExistent = makeAddr("nonExistent");
        vm.expectRevert(abi.encodeWithSelector(IPrices.PriceFeedNotFound.selector, buidl, nonExistent));
        manager.removePriceFeedByAddr(buidl, nonExistent);
    }

    function test_multiFeed_duplicateFeed_reverts() public {
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);

        vm.expectRevert(
            abi.encodeWithSelector(IPrices.PriceFeedAlreadyRegistered.selector, buidl, address(oracleaBuidl))
        );
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);
    }

    function test_multiFeed_freshestWins() public {
        // Three feeds at t=100, t=200, t=300; current block at t=400.
        vm.warp(100);
        Mock_PriceOracleChainlink oracle1 = new Mock_PriceOracleChainlink("a", 111, 8); // updatedAt=100
        vm.warp(200);
        Mock_PriceOracleChainlink oracle2 = new Mock_PriceOracleChainlink("b", 222, 8); // updatedAt=200
        vm.warp(300);
        Mock_PriceOracleChainlink oracle3 = new Mock_PriceOracleChainlink("c", 333, 8); // updatedAt=300

        vm.warp(400);
        PricesHarness h = new PricesHarness(address(0));
        h.setPriceFeed(buidl, address(oracle1), type(uint256).max, IPrices.PriceType.Chainlink);
        h.setPriceFeed(buidl, address(oracle2), type(uint256).max, IPrices.PriceType.Chainlink);
        h.setPriceFeed(buidl, address(oracle3), type(uint256).max, IPrices.PriceType.Chainlink);

        (int256 price,, bool stale) = h.latestPrice(buidl);
        assertEq(price, 333); // oracle3 freshest (updatedAt=300)
        assertFalse(stale);
    }

    function test_multiFeed_oneStaleHeartbeat_secondWins() public {
        // oracle1 stale (heartbeat exceeded), oracle2 fresh — oracle2 wins.
        vm.warp(100);
        Mock_PriceOracleChainlink oracle1 = new Mock_PriceOracleChainlink("a", 111, 8); // updatedAt=100
        vm.warp(200);
        Mock_PriceOracleChainlink oracle2 = new Mock_PriceOracleChainlink("b", 222, 8); // updatedAt=200

        vm.warp(400);
        PricesHarness h = new PricesHarness(address(0));
        h.setPriceFeed(buidl, address(oracle1), 250, IPrices.PriceType.Chainlink); // 400-100=300 > 250 → stale
        h.setPriceFeed(buidl, address(oracle2), 250, IPrices.PriceType.Chainlink); // 400-200=200 < 250 → fresh

        (int256 price,, bool stale) = h.latestPrice(buidl);
        assertEq(price, 222);
        assertFalse(stale);
    }

    function test_multiFeed_allStale_returnsZeroAndStale() public {
        vm.warp(100);
        Mock_PriceOracleChainlink oracle1 = new Mock_PriceOracleChainlink("a", 111, 8); // updatedAt=100
        vm.warp(200);
        Mock_PriceOracleChainlink oracle2 = new Mock_PriceOracleChainlink("b", 222, 8); // updatedAt=200

        vm.warp(400);
        PricesHarness h = new PricesHarness(address(0));
        h.setPriceFeed(buidl, address(oracle1), 50, IPrices.PriceType.Chainlink); // 400-100=300 > 50 → stale
        h.setPriceFeed(buidl, address(oracle2), 50, IPrices.PriceType.Chainlink); // 400-200=200 > 50 → stale

        (int256 price, uint8 decimals, bool stale) = h.latestPrice(buidl);
        assertEq(price, 0); // all stale → zero
        assertEq(decimals, 8); // first feed's decimals for unit consistency
        assertTrue(stale);
    }

    function test_multiFeed_customFeed_zeroUpdatedAt_survivesAsSentinel() public {
        // Custom feed returning updatedAt=0 means "no trackable oracle".
        // Treated as block.timestamp-1 so it passes the staleness gate (survives) but
        // loses to any feed that reports a real on-chain update timestamp.
        vm.warp(1000);
        Mock_CustomPriceFeedZeroUpdatedAt customZero = new Mock_CustomPriceFeedZeroUpdatedAt();
        PricesHarness h = new PricesHarness(address(0));
        h.setPriceFeed(buidl, address(customZero), type(uint256).max, IPrices.PriceType.Custom);

        (int256 price,, bool stale) = h.latestPrice(buidl);
        assertEq(price, 100_000_000); // survives — effective time = block.timestamp-1, not 0
        assertFalse(stale);
    }

    // ============================================
    // API3 Feed Tests
    // ============================================

    function test_registerAPI3_storesEightDecimals() public {
        // API3 proxy returns 18 decimals; PriceFeedLib must store 8 in the config.
        Mock_PriceOracleChainlink api3Feed = new Mock_PriceOracleChainlink("ETH/USD API3", 3000e18, 18);
        manager.setPriceFeed(buidl, address(api3Feed), type(uint256).max, IPrices.PriceType.API3);

        IPrices.PriceFeedConfig memory cfg = manager.getPriceFeedAt(buidl, 0);
        assertEq(cfg.decimals, 8, "API3 feed must be stored with 8 output decimals");
        assertEq(uint8(cfg.priceType), uint8(IPrices.PriceType.API3));
    }

    function test_registerAPI3_nonStandardDecimalsReverts() public {
        // Only 18-dec proxies are valid API3 feeds; 8-dec must revert.
        Mock_PriceOracleChainlink badFeed = new Mock_PriceOracleChainlink("bad API3", 3000e8, 8);
        vm.expectRevert(IPrices.InvalidPriceOracle.selector);
        manager.setPriceFeed(buidl, address(badFeed), type(uint256).max, IPrices.PriceType.API3);
    }

    function test_registerAPI3_thenChainlink_decimalConsistencyPasses() public {
        // API3 stored as 8-dec → adding an 8-dec Chainlink feed must succeed.
        Mock_PriceOracleChainlink api3Feed = new Mock_PriceOracleChainlink("ETH/USD API3", 3000e18, 18);
        manager.setPriceFeed(buidl, address(api3Feed), type(uint256).max, IPrices.PriceType.API3);

        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);

        assertEq(manager.getPriceFeedCount(buidl), 2);
        assertEq(manager.getPriceFeedAt(buidl, 0).decimals, 8);
        assertEq(manager.getPriceFeedAt(buidl, 1).decimals, 8);
    }

    function test_latestPrice_API3_scaledCorrectly() public {
        // Proxy returns 3000e18 (18-dec); latestPrice must return 3000e8 (8-dec).
        Mock_PriceOracleChainlink api3Feed = new Mock_PriceOracleChainlink("ETH/USD API3", 3000e18, 18);
        manager.setPriceFeed(buidl, address(api3Feed), type(uint256).max, IPrices.PriceType.API3);

        (int256 price, uint8 decimals, bool stale) = manager.latestPrice(buidl);
        assertEq(price, 3000e8, "18-dec API3 price must be scaled to 8-dec");
        assertEq(decimals, 8);
        assertFalse(stale);
    }

    function test_multiFeed_clockSkewNormalization() public {
        // A feed whose updatedAt > block.timestamp (future-dated timestamp)
        // must be clamped to block.timestamp and NOT systematically beat a normally-timed feed.
        // Register both feeds at t=300 (no future-timestamp at registration), then adjust normalOracle
        // to t=100 via setter and warp back to test the read-path clamping.
        vm.warp(300);
        Mock_PriceOracleChainlink futureOracle = new Mock_PriceOracleChainlink("future", 999, 8); // _updatedAt=300
        Mock_PriceOracleChainlink normalOracle = new Mock_PriceOracleChainlink("normal", 111, 8); // _updatedAt=300
        PricesHarness h = new PricesHarness(address(0));
        h.setPriceFeed(buidl, address(normalOracle), type(uint256).max, IPrices.PriceType.Chainlink); // index 0
        h.setPriceFeed(buidl, address(futureOracle), type(uint256).max, IPrices.PriceType.Chainlink); // index 1

        // Rewind normalOracle to t=100; futureOracle stays at t=300.
        normalOracle.setUpdatedAt(100);
        vm.warp(100);

        // normalOracle: updatedAt=100 → effectiveTime=min(100,100)=100
        // futureOracle: updatedAt=300 > block.timestamp=100 → effectiveTime=min(300,100)=100 (clamped)
        // Both tie at 100; index 0 (normalOracle) wins the tie.
        (int256 price,, bool stale) = h.latestPrice(buidl);
        assertFalse(stale);
        assertEq(price, 111); // normalOracle wins; futureOracle clamped, no longer beats it
    }
}
