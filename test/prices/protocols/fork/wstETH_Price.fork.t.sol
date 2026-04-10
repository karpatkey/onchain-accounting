// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {wstETH_PriceOracle} from "src/prices/protocols/wstETH_Price.sol";

contract wstETH_PriceOracleForkTest is TestEnvConfigurator {
    wstETH_PriceOracle wstEthPriceOracle;

    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant ETH_TO_USD_CHAINLINK = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 constant HEARTBEAT = 3600;
    uint256 constant FORK_BLOCK = 24_199_054;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        wstEthPriceOracle = new wstETH_PriceOracle(WSTETH, ETH_TO_USD_CHAINLINK, HEARTBEAT);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = wstEthPriceOracle.getLatestPrice();
        // stEthPerToken * ETH/USD / 1e18
        assertEq(price, 377_736_678_586, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        (uint256 price, bool stale) = wstEthPriceOracle.getLatestPrice();
        assertGt(price, 0, "Price should still be returned when stale");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(wstEthPriceOracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(wstEthPriceOracle.underlyingAssetSupported(), WSTETH, "Underlying asset should match wstETH token");
    }
}
