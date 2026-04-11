// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ETHPlus_PriceOracle} from "src/prices/protocols/ETHPlus_Price.sol";

contract ETHPlus_PriceOracleForkTest is TestEnvConfigurator {
    ETHPlus_PriceOracle oracle;

    address constant ETHPLUS = 0xE72B141DF173b999AE7c1aDcbF60Cc9833Ce56a8;
    uint256 constant FORK_BLOCK = 24_277_401;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new ETHPlus_PriceOracle(ETHPLUS);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = oracle.getLatestPrice();
        // (35930254610744758768926 / 33588540032392468729179) * 2980651180612428414751 / 1e10 = 318845522079
        assertEq(price, 318_845_522_079, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should be 8 for USD");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), ETHPLUS, "Underlying asset should match ETH+ token");
    }
}
