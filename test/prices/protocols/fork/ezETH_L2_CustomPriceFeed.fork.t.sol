// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ezETH_L2_CustomPriceFeed} from "src/prices/protocols/ezETH_L2_CustomPriceFeed.sol";

contract ezETH_L2_CustomPriceFeedForkTest_Arbitrum is TestEnvConfigurator {
    ezETH_L2_CustomPriceFeed oracle;

    address constant EZETH = 0x2416092f143378750bb29b79eD961ab195CcEea5;
    address constant X_RENZO_DEPOSIT = 0x2EfA125B4fcD5B082a4233BA55b53FeB2Fb4Ff33;
    address constant ETH_TO_USD_CHAINLINK = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    uint256 constant ETH_TO_USD_HEARTBEAT = 3600;
    uint256 constant FORK_BLOCK = 427_928_961;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("arb-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new ezETH_L2_CustomPriceFeed(EZETH, X_RENZO_DEPOSIT, ETH_TO_USD_CHAINLINK, ETH_TO_USD_HEARTBEAT);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = oracle.getLatestPrice();
        // 1070827236233843156 * 233767368500 / 1e18 = 250324465132
        assertEq(price, 250_324_465_132, "Price should match calculated value");
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
        assertEq(oracle.underlyingAssetSupported(), EZETH, "Underlying asset should match ezETH token");
    }
}
