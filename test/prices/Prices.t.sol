// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

import {Prices} from "src/prices/Prices.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {
    Mock_CustomPriceFeed,
    Mock_PriceOracleChainlink,
    Mock_CustomPriceFeedStaled
} from "test/mocks/price_oracles.sol";

contract PricesHarness is Prices {
    constructor(address chainlinkUptimeFeed) initializer {
        __Prices_init(chainlinkUptimeFeed);
    }

    function setPriceOracle(address token, address oracle, uint256 chainlinkHeartbeat, IPrices.PriceType oracleType)
        public
    {
        _setPriceFeed(token, oracle, chainlinkHeartbeat, oracleType);
    }

    function setPriceFeed(address token, address oracle, uint256 chainlinkHeartbeat, IPrices.PriceType oracleType)
        public
    {
        _setPriceFeed(token, oracle, chainlinkHeartbeat, oracleType);
    }

    function removePriceOracle(address token) public {
        _unsetPriceFeed(token);
    }
}

contract PricesTest is Test {
    PricesHarness public manager;
    PricesHarness public managerL2;
    Mock_PriceOracleChainlink chainlinkUptimeFeed;
    Mock_CustomPriceFeed public oracleusdc;
    Mock_PriceOracleChainlink public oracleaBuidl;
    Mock_PriceOracleChainlink public disabledUptimeFeed;
    Mock_CustomPriceFeedStaled public customStaled;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address usdc = makeAddr("usdc");
    address buidl = makeAddr("buidl");

    function setUp() public {
        oracleusdc = new Mock_CustomPriceFeed("usdc", address(usdc), 100_000_000, 8);
        oracleaBuidl = new Mock_PriceOracleChainlink("buidl", 1000, 8);
        disabledUptimeFeed = new Mock_PriceOracleChainlink("UptimeFeed", 1, 8);
        manager = new PricesHarness(address(0));
        managerL2 = new PricesHarness(address(chainlinkUptimeFeed));
        customStaled = new Mock_CustomPriceFeedStaled("usdc", address(usdc), 100_000_000, 8);
    }

    function test_latestPrice_WithNonStalePrices() public {
        manager.setPriceFeed(usdc, address(oracleusdc), type(uint256).max, IPrices.PriceType.Custom);
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);

        vm.startPrank(alice);
        (uint256 value, uint8 decimals, bool stale) = manager.latestPrice(usdc);
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
        (uint256 value, uint8 decimals, bool stale) = manager.latestPrice(usdc);
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
        manager.setPriceFeed(usdc, address(oracleusdc), 0, IPrices.PriceType.Custom);
        manager.setPriceFeed(buidl, address(oracleaBuidl), 1, IPrices.PriceType.Chainlink);

        vm.warp(block.timestamp + 2);

        vm.startPrank(alice);
        (uint256 value, uint8 decimals, bool stale) = manager.latestPrice(usdc);
        assertEq(value, 100_000_000);
        assertEq(decimals, 8);
        assertFalse(stale);

        (value, decimals, stale) = manager.latestPrice(buidl);
        assertEq(value, 1000);
        assertEq(decimals, 8);
        assertTrue(stale);

        vm.stopPrank();
    }

    function test_latestPrice_CustomOracleStaled() public {
        manager.setPriceFeed(usdc, address(customStaled), 0, IPrices.PriceType.Custom);
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);

        vm.startPrank(alice);
        (uint256 value, uint8 decimals, bool stale) = manager.latestPrice(usdc);
        assertEq(value, 100_000_000);
        assertEq(decimals, 8);
        assertTrue(stale);

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
        (address oracle,,,) = manager.priceOracles(buidl);

        assertEq(oracle, address(0));
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

    function test_setPriceFeed_chainlinkZeroHeartbeat() public {
        vm.expectRevert();
        manager.setPriceFeed(buidl, address(oracleaBuidl), 0, IPrices.PriceType.Chainlink);
    }

    function test_unsetPriceFeed_notSet() public {
        // Unsetting non-existent feed should not revert (delete on non-existent mapping is safe)
        manager.removePriceOracle(usdc);
        (address oracle,,,) = manager.priceOracles(usdc);
        assertEq(oracle, address(0));
    }

    // ============================================
    // Getters Tests
    // ============================================

    function test_priceOracles() public {
        manager.setPriceFeed(usdc, address(oracleusdc), type(uint256).max, IPrices.PriceType.Custom);

        (address oracle, uint8 decimals, uint256 heartbeat, IPrices.PriceType priceType) = manager.priceOracles(usdc);
        assertEq(oracle, address(oracleusdc));
        assertEq(decimals, 8);
        assertEq(heartbeat, type(uint256).max);
        assertEq(uint8(priceType), uint8(IPrices.PriceType.Custom));
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

    function test_latestPrice_zeroPrice() public {
        // Create a mock oracle that returns zero price
        Mock_PriceOracleChainlink zeroPriceOracle = new Mock_PriceOracleChainlink("Zero", 0, 8);
        manager.setPriceFeed(buidl, address(zeroPriceOracle), type(uint256).max, IPrices.PriceType.Chainlink);

        (uint256 price, uint8 decimals, bool stale) = manager.latestPrice(buidl);
        assertEq(price, 0);
        assertEq(decimals, 8);
        assertTrue(stale); // Zero price should be marked as stale
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
}
