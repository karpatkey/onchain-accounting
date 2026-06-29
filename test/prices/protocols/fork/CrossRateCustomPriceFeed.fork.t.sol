// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {CrossRateCustomPriceFeed} from "src/prices/protocols/CrossRateCustomPriceFeed.sol";

/// @title CrossRateCustomPriceFeed fork tests (wstETH/USD via ETH/USD * wstETH/ETH on Gnosis)
contract CrossRateCustomPriceFeedForkTest is TestEnvConfigurator {
    CrossRateCustomPriceFeed public oracle;

    address public wsteth = address(0x6C76971f98945AE98dD7d4DFcA8711ebea946eA6); // Gnosis wstETH
    address public ethUsdChainlink = address(0xa767f745331D267c7751297D982b050c93985627); // ETH/USD
    address public wstEthEthChainlink = address(0x0064AC007fF665CF8D0D3Af5E0AD1c26a3f853eA); // wstETH/ETH
    uint256 public constant HEARTBEAT = 86400;
    uint256 public constant FORK_BLOCK = 36_738_104;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("gnosis-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new CrossRateCustomPriceFeed(wsteth, wstEthEthChainlink, ethUsdChainlink, HEARTBEAT, HEARTBEAT);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertGt(price, 0, "Price should be positive");
        assertEq(stale, false, "Price should not be stale");
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        (, bool stale) = oracle.getLatestPrice();
        assertEq(stale, true, "Price should be stale");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match X/USD (ETH/USD) feed");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), wsteth, "Underlying asset should match wstETH");
    }
}
