// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {sUSDe_PriceOracle} from "src/prices/protocols/sUSDe_Price.sol";

contract sUSDe_PriceOracleForkTest is TestEnvConfigurator {
    sUSDe_PriceOracle sUsdePriceOracle;

    address constant S_USDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant USDE_TO_USD_CHAINLINK = 0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961;
    uint256 constant HEARTBEAT = 82_800;
    uint256 constant FORK_BLOCK = 24_486_042;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        sUsdePriceOracle = new sUSDe_PriceOracle(S_USDE, USDE_TO_USD_CHAINLINK, HEARTBEAT);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = sUsdePriceOracle.getLatestPrice();
        // convertToAssets(1e18) * USDe/USD / 1e18
        // = 1220890733787148734 * 99916413 / 1e18 = 121987022
        assertEq(price, 121_987_022, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        (uint256 price, bool stale) = sUsdePriceOracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(sUsdePriceOracle.decimals(), 8, "Decimals should match USDe/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(sUsdePriceOracle.underlyingAssetSupported(), S_USDE, "Underlying asset should match sUSDe token");
    }
}
