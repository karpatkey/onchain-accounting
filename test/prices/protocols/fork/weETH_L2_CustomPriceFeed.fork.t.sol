// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {weETH_L2_CustomPriceFeed} from "src/prices/protocols/weETH_L2_CustomPriceFeed.sol";

contract weETH_L2_CustomPriceFeedForkTest_Arbitrum is TestEnvConfigurator {
    weETH_L2_CustomPriceFeed oracle;

    address constant WEETH = 0x35751007a407ca6FEFfE80b3cB397736D2cf4dbe;
    address constant WEETH_TO_EETH_CHAINLINK = 0x20bAe7e1De9c596f5F7615aeaa1342Ba99294e12;
    address constant ETH_TO_USD_CHAINLINK = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    uint256 constant WEETH_TO_EETH_HEARTBEAT = 86_400;
    uint256 constant ETH_TO_USD_HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 428_258_960;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("arb-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new weETH_L2_CustomPriceFeed(
            WEETH, WEETH_TO_EETH_CHAINLINK, ETH_TO_USD_CHAINLINK, WEETH_TO_EETH_HEARTBEAT, ETH_TO_USD_HEARTBEAT
        );
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = oracle.getLatestPrice();
        // 1087324359253471007 * 222039950600 / 1e18 = 241429447014
        assertEq(price, 241_429_447_014, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + ETH_TO_USD_HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), WEETH, "Underlying asset should match weETH token");
    }
}

contract weETH_L2_CustomPriceFeedForkTest_Base is TestEnvConfigurator {
    weETH_L2_CustomPriceFeed oracle;

    address constant WEETH = 0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A;
    address constant WEETH_TO_EETH_CHAINLINK = 0x35e9D7001819Ea3B39Da906aE6b06A62cfe2c181;
    address constant ETH_TO_USD_CHAINLINK = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    uint256 constant WEETH_TO_EETH_HEARTBEAT = 86_400;
    uint256 constant ETH_TO_USD_HEARTBEAT = 1200;
    uint256 constant FORK_BLOCK = 41_675_313;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("base-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new weETH_L2_CustomPriceFeed(
            WEETH, WEETH_TO_EETH_CHAINLINK, ETH_TO_USD_CHAINLINK, WEETH_TO_EETH_HEARTBEAT, ETH_TO_USD_HEARTBEAT
        );
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = oracle.getLatestPrice();
        // 1087324359253471007 * 223142550000 / 1e18 = 242628330200
        assertEq(price, 242_628_330_200, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + ETH_TO_USD_HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), WEETH, "Underlying asset should match weETH token");
    }
}
