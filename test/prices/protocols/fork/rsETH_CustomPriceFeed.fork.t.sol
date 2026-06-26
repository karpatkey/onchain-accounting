// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {rsETH_CustomPriceFeed} from "src/prices/protocols/rsETH_CustomPriceFeed.sol";

contract rsETH_CustomPriceFeedForkTest is TestEnvConfigurator {
    rsETH_CustomPriceFeed rsEthPriceOracle;

    address constant RSETH = 0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7;
    address constant RATE_PROVIDER = 0x0788906B19bA8f8d0e8a7015f0714DF3179D9aB6;
    address constant ETH_TO_USD_CHAINLINK = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 constant HEARTBEAT = 3600;
    uint256 constant FORK_BLOCK = 24_327_368;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        rsEthPriceOracle = new rsETH_CustomPriceFeed(RSETH, RATE_PROVIDER, ETH_TO_USD_CHAINLINK, HEARTBEAT);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = rsEthPriceOracle.getLatestPrice();
        // getLatestRate * ETH/USD / 1e18
        assertEq(price, 316_654_219_911, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        (uint256 price, bool stale) = rsEthPriceOracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(rsEthPriceOracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(rsEthPriceOracle.underlyingAssetSupported(), RSETH, "Underlying asset should match rsETH token");
    }
}
