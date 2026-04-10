// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {weETH_PriceOracle} from "src/prices/protocols/weETH_Price.sol";

contract weETH_PriceOracleForkTest is TestEnvConfigurator {
    weETH_PriceOracle weEthPriceOracle;

    address constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant WEETH_TO_ETH_CHAINLINK = 0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22;
    address constant ETH_TO_USD_CHAINLINK = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 constant WEETH_TO_ETH_HEARTBEAT = 86_400;
    uint256 constant ETH_TO_USD_HEARTBEAT = 3600;
    uint256 constant FORK_BLOCK = 24_412_470;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        weEthPriceOracle =
            new weETH_PriceOracle(WEETH, WEETH_TO_ETH_CHAINLINK, ETH_TO_USD_CHAINLINK, WEETH_TO_ETH_HEARTBEAT, ETH_TO_USD_HEARTBEAT);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = weEthPriceOracle.getLatestPrice();
        // weETH/ETH * ETH/USD / 1e18
        assertEq(price, 231_077_158_224, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + WEETH_TO_ETH_HEARTBEAT + 1);
        (uint256 price, bool stale) = weEthPriceOracle.getLatestPrice();
        assertGt(price, 0, "Price should still be returned when stale");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(weEthPriceOracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(weEthPriceOracle.underlyingAssetSupported(), WEETH, "Underlying asset should match weETH token");
    }
}
