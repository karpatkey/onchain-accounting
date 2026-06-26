// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {NXM_CustomPriceFeed} from "src/prices/protocols/NXM_CustomPriceFeed.sol";

/// @title wNXM fork tests
/// @notice wNXM reuses NXM_CustomPriceFeed: it is the 1:1 wrapper a Nexus member can unwrap to NXM, so it is
///         priced at the same RAMM book value as NXM. Verifies the wNXM instance reports wNXM as its
///         underlying and returns the identical book price as a same-block NXM instance.
contract wNXM_CustomPriceFeedForkTest is TestEnvConfigurator {
    NXM_CustomPriceFeed wnxmPriceOracle;
    NXM_CustomPriceFeed nxmPriceOracle;

    address constant NXM = 0xd7c49CEE7E9188cCa6AD8FF264C1DA2e69D4Cf3B;
    address constant WNXM = 0x0d438F3b5175Bebc262bF23753C1E53d03432bDE;
    address constant RAMM = 0xcafea54f03E1Cc036653444e581A10a43B2487CD;
    address constant ETH_TO_USD_CHAINLINK = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 constant HEARTBEAT = 3600;
    uint256 constant FORK_BLOCK = 25_345_348;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        wnxmPriceOracle = new NXM_CustomPriceFeed(WNXM, RAMM, ETH_TO_USD_CHAINLINK, HEARTBEAT);
        nxmPriceOracle = new NXM_CustomPriceFeed(NXM, RAMM, ETH_TO_USD_CHAINLINK, HEARTBEAT);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = wnxmPriceOracle.getLatestPrice();
        // Same RAMM book value as NXM: RAMM.getInternalPrice() [ETH/NXM] * ETH/USD / 1e18
        assertEq(price, 4_666_288_516, "wNXM priced at NXM book value");
        assertEq(stale, false);
    }

    function test_matchesNxmPrice() public view {
        (uint256 wnxmPrice,) = wnxmPriceOracle.getLatestPrice();
        (uint256 nxmPrice,) = nxmPriceOracle.getLatestPrice();
        assertEq(wnxmPrice, nxmPrice, "wNXM and NXM share the same RAMM book price");
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        (uint256 price, bool stale) = wnxmPriceOracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(wnxmPriceOracle.underlyingAssetSupported(), WNXM, "Underlying asset should match wNXM token");
    }
}
