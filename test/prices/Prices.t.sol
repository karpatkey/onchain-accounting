// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test, console} from "forge-std/Test.sol";

import {Prices} from "src/prices/Prices.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {
    Mock_PriceOracleCustom,
    Mock_PriceOracleChainlink
} from "test/mocks/price_oracles.sol";

contract PricesHarness is Prices {
    constructor(address chainlinkUptimeFeed) initializer {
        __Prices_init(chainlinkUptimeFeed);
    }

    function setPriceOracle(address token, address oracle, uint256 chainlinkHeartbeat, IPrices.PriceType oracleType)
        public
    {
        _setPriceOracle(token, oracle, chainlinkHeartbeat, oracleType);
    }

    function removePriceOracle(address token) public {
        _removePriceOracle(token);
    }
}

contract PricesTest is Test {
    PricesHarness public manager;
    PricesHarness public managerL2;
    Mock_PriceOracleChainlink chainlinkUptimeFeed;
    Mock_PriceOracleCustom public oracleusdc;
    Mock_PriceOracleChainlink public oracleaBUIDL;
    Mock_PriceOracleChainlink public disabledUptimeFeed;
    Mock_PriceOracleCustom public customStaled;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address usdc = makeAddr("usdc");
    address BUIDL = makeAddr("buidl");

    function setUp() public {
        oracleusdc = new Mock_PriceOracleCustom("usdc", address(usdc), 100_000_000, 8);
        oracleaBUIDL = new Mock_PriceOracleChainlink("BUIDL", 1000, 8);
        disabledUptimeFeed = new Mock_PriceOracleChainlink("UptimeFeed", 1, 8);
        manager = new PricesHarness(address(0));
        managerL2 = new PricesHarness(address(chainlinkUptimeFeed));
        customStaled = new Mock_PriceOracleCustom("usdc", address(usdc), 100_000_000, 8);
        customStaled.setStale(true);
    }

    function test_latestPrice_WithNonStalePrices() public {
        manager.setPriceOracle(usdc, address(oracleusdc), type(uint256).max, IPrices.PriceType.Custom);
        manager.setPriceOracle(BUIDL, address(oracleaBUIDL), type(uint256).max, IPrices.PriceType.Chainlink);

        vm.startPrank(alice);
        (uint256 value, uint8 decimals, bool stale) = manager.latestPrice(usdc);
        assertEq(value, 100_000_000);
        assertEq(decimals, 8);
        assertFalse(stale);

        (value, decimals, stale) = manager.latestPrice(BUIDL);
        assertEq(value, 1000);
        assertEq(decimals, 8);
        assertFalse(stale);

        vm.stopPrank();
    }

    function test_latestPrice_BeforeGracePeriod() public {
        manager = new PricesHarness(address(disabledUptimeFeed));
        manager.setPriceOracle(usdc, address(oracleusdc), type(uint256).max, IPrices.PriceType.Custom);
        manager.setPriceOracle(BUIDL, address(oracleaBUIDL), type(uint256).max, IPrices.PriceType.Chainlink);

        vm.startPrank(alice);
        (uint256 value, uint8 decimals, bool stale) = manager.latestPrice(usdc);
        assertEq(value, 100_000_000);
        assertEq(decimals, 8);
        assertTrue(stale);

        (value, decimals, stale) = manager.latestPrice(BUIDL);
        assertEq(value, 1000);
        assertEq(decimals, 8);
        assertTrue(stale);

        vm.stopPrank();
    }

    function test_latestPrice_AfterHearBeat() public {
        manager.setPriceOracle(usdc, address(oracleusdc), 0, IPrices.PriceType.Custom);
        manager.setPriceOracle(BUIDL, address(oracleaBUIDL), 1, IPrices.PriceType.Chainlink);

        vm.warp(block.timestamp + 2);

        vm.startPrank(alice);
        (uint256 value, uint8 decimals, bool stale) = manager.latestPrice(usdc);
        assertEq(value, 100_000_000);
        assertEq(decimals, 8);
        assertFalse(stale);

        (value, decimals, stale) = manager.latestPrice(BUIDL);
        assertEq(value, 1000);
        assertEq(decimals, 8);
        assertTrue(stale);

        vm.stopPrank();
    }

    function test_latestPrice_CustomOracleStaled() public {
        manager.setPriceOracle(usdc, address(customStaled), 0, IPrices.PriceType.Custom);
        manager.setPriceOracle(BUIDL, address(oracleaBUIDL), type(uint256).max, IPrices.PriceType.Chainlink);

        vm.startPrank(alice);
        (uint256 value, uint8 decimals, bool stale) = manager.latestPrice(usdc);
        assertEq(value, 100_000_000);
        assertEq(decimals, 8);
        assertTrue(stale);

        (value, decimals, stale) = manager.latestPrice(BUIDL);
        assertEq(value, 1000);
        assertEq(decimals, 8);
        assertFalse(stale);

        vm.stopPrank();
    }

    function test_RevertIf_OracleNotSet() public {
        vm.expectRevert();
        manager.latestPrice(usdc);
    }

    function test_setPriceOracle_Chainlink() public {
        manager.setPriceOracle(BUIDL, address(oracleaBUIDL), type(uint256).max, IPrices.PriceType.Chainlink);
    }

    function test_setPriceOracle_CustomOracle() public {
        manager.setPriceOracle(usdc, address(oracleusdc), type(uint256).max, IPrices.PriceType.Custom);
    }

    function test_RemoveOracle() public {
        manager.setPriceOracle(BUIDL, address(oracleaBUIDL), type(uint256).max, IPrices.PriceType.Chainlink);
        manager.removePriceOracle(BUIDL);
        (address oracle,,,) = manager.priceOracles(BUIDL);

        assertEq(oracle, address(0));
    }

    function test_CheckCustomOracleSupport_ValidCustomOracle() public view {
        manager.checkPriceOracleSupport(address(usdc), address(oracleusdc), IPrices.PriceType.Custom);
        manager.checkPriceOracleSupport(address(usdc), address(oracleaBUIDL), IPrices.PriceType.Chainlink);
    }

    function test_RevertIf_InvalidOracleTypeCL() public {
        vm.expectRevert();
        manager.checkPriceOracleSupport(address(usdc), address(oracleusdc), IPrices.PriceType.Chainlink);
    }

    function test_RevertIf_CheckCustomOracleSupport_InvalidOracleTypeCM() public {
        vm.expectRevert();
        manager.checkPriceOracleSupport(address(usdc), address(oracleaBUIDL), IPrices.PriceType.Custom);
    }
}
