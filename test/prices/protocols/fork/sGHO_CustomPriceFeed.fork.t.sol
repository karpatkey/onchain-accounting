// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {sGHO_CustomPriceFeed} from "src/prices/protocols/sGHO_CustomPriceFeed.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract sGHO_CustomPriceFeedForkTest is TestEnvConfigurator {
    sGHO_CustomPriceFeed sghoPriceOracle;

    address constant SGHO = 0xE1753F2e00940cC31213dd92013cF019DFE4ca1d;
    address constant GHO_TO_USD_CHAINLINK = 0x3f12643D3f6f874d39C2a4c9f2Cd6f2DbAC877FC;
    uint256 constant HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 25_380_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        sghoPriceOracle = new sGHO_CustomPriceFeed(SGHO, GHO_TO_USD_CHAINLINK, HEARTBEAT);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = sghoPriceOracle.getLatestPrice();
        assertFalse(stale, "GHO/USD feed should be fresh at the pinned block");

        // price == sGHO.convertToAssets(1e18) * (GHO/USD) / 1e18, in the oracle's 8 decimals.
        uint256 shareRate = IERC4626(SGHO).convertToAssets(1e18); // GHO per sGHO share (18 decimals)
        (, int256 ghoUsd,,,) = AggregatorV3Interface(GHO_TO_USD_CHAINLINK).latestRoundData();
        uint256 expected = (shareRate * uint256(ghoUsd)) / 1e18;
        assertEq(price, expected, "price = GHO/USD x sGHO share rate");

        // Sanity: a yield vault share is worth >= 1 GHO, and GHO ~ $1, so sGHO/USD >= ~1e8 (8 decimals).
        assertGe(price, 1e8, "sGHO worth at least ~1 GHO");
        assertLe(price, 2e8, "sanity upper bound (GHO ~ $1, modest accrual)");
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        (uint256 price, bool stale) = sghoPriceOracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(sghoPriceOracle.decimals(), 8, "Decimals should match GHO/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(sghoPriceOracle.underlyingAssetSupported(), SGHO, "Underlying asset should match sGHO token");
    }
}
