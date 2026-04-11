// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {rsETH_L2_PriceOracle} from "src/prices/protocols/rsETH_L2_Price.sol";

contract rsETH_L2_PriceOracleForkTest_Arbitrum is TestEnvConfigurator {
    rsETH_L2_PriceOracle oracle;

    address constant RSETH = 0x4186BFC76E2E237523CBC30FD220FE055156b41F;
    address constant RSETH_TO_ETH_CHAINLINK = 0x3A917e6B5732dFCc4A45257e3930979fAE6a3737;
    address constant ETH_TO_USD_CHAINLINK = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    uint256 constant RSETH_TO_ETH_HEARTBEAT = 86_400;
    uint256 constant ETH_TO_USD_HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 428_316_316;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("arb-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new rsETH_L2_PriceOracle(
            RSETH, RSETH_TO_ETH_CHAINLINK, ETH_TO_USD_CHAINLINK, RSETH_TO_ETH_HEARTBEAT, ETH_TO_USD_HEARTBEAT
        );
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = oracle.getLatestPrice();
        // 1064188561412771784 * 231481000000 / 1e18 = 246339432384
        assertEq(price, 246_339_432_384, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + ETH_TO_USD_HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertGt(price, 0, "Price should still be returned when stale");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), RSETH, "Underlying asset should match rsETH token");
    }
}
