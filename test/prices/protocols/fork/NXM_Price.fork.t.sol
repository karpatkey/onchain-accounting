// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {NXM_PriceOracle} from "src/prices/protocols/NXM_Price.sol";

contract NXM_PriceOracleForkTest is TestEnvConfigurator {
    NXM_PriceOracle nxmPriceOracle;

    address constant NXM = 0xd7c49CEE7E9188cCa6AD8FF264C1DA2e69D4Cf3B;
    address constant RAMM = 0xcafea54f03E1Cc036653444e581A10a43B2487CD;
    address constant ETH_TO_USD_CHAINLINK = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 constant HEARTBEAT = 3600;
    uint256 constant FORK_BLOCK = 25_345_348;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        nxmPriceOracle = new NXM_PriceOracle(NXM, RAMM, ETH_TO_USD_CHAINLINK, HEARTBEAT);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = nxmPriceOracle.getLatestPrice();
        // RAMM.getInternalPrice() [ETH/NXM] * ETH/USD / 1e18
        assertEq(price, 4_666_288_516, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        (uint256 price, bool stale) = nxmPriceOracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(nxmPriceOracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(nxmPriceOracle.underlyingAssetSupported(), NXM, "Underlying asset should match NXM token");
    }
}
