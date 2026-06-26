// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ETHx_CustomPriceFeed} from "src/prices/protocols/ETHx_CustomPriceFeed.sol";

contract ETHx_CustomPriceFeedForkTest is TestEnvConfigurator {
    ETHx_CustomPriceFeed ethxPriceOracle;

    address constant ETHX = 0xA35b1B31Ce002FBF2058D22F30f95D405200A15b;
    address constant STAKE_POOLS_MANAGER = 0xcf5EA1b38380f6aF39068375516Daf40Ed70D299;
    address constant ETH_TO_USD_CHAINLINK = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 constant HEARTBEAT = 3600;
    uint256 constant FORK_BLOCK = 25_015_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        ethxPriceOracle = new ETHx_CustomPriceFeed(ETHX, STAKE_POOLS_MANAGER, ETH_TO_USD_CHAINLINK, HEARTBEAT);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = ethxPriceOracle.getLatestPrice();
        // getExchangeRate * ETH/USD / 1e18, both 18-dp rate and 8-dp ETH/USD.
        // At block 25_015_000: rate=1088288441358846187, ETH/USD=232530173000.
        assertEq(price, 253_059_899_543, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        (uint256 price, bool stale) = ethxPriceOracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(ethxPriceOracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(ethxPriceOracle.underlyingAssetSupported(), ETHX, "Underlying asset should match ETHx token");
    }
}
