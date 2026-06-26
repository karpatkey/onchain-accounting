// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {RWIV_CustomPriceFeed} from "src/prices/protocols/RWIV_CustomPriceFeed.sol";

contract RWIV_CustomPriceFeedForkTest is TestEnvConfigurator {
    RWIV_CustomPriceFeed rwivPriceOracle;

    address constant RWIV = 0xcAFeAA466736ac01e0AC9Ca72644beF348694731;
    address constant USDC_TO_USD_CHAINLINK = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    uint256 constant HEARTBEAT = 82_800;
    uint256 constant FORK_BLOCK = 25_380_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        rwivPriceOracle = new RWIV_CustomPriceFeed(RWIV, USDC_TO_USD_CHAINLINK, HEARTBEAT);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = rwivPriceOracle.getLatestPrice();
        // convertToAssets(1e6) * USDC/USD / 1e6
        // = 1015934 * 99966728 / 1e6 = 101559597
        assertEq(price, 101_559_597, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        (uint256 price, bool stale) = rwivPriceOracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(rwivPriceOracle.decimals(), 8, "Decimals should match USDC/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(rwivPriceOracle.underlyingAssetSupported(), RWIV, "Underlying asset should match RWIV token");
    }
}
