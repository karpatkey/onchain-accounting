// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {wstETH_L2_CustomPriceFeed} from "src/prices/protocols/wstETH_L2_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract wstETH_L2_CustomPriceFeedForkTest_Arbitrum is TestEnvConfigurator {
    wstETH_L2_CustomPriceFeed oracle;

    address constant ASSET = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address constant RATE_FEED = 0xb523AE262D20A936BC152e6023996e46FDC2A95D;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant BASE = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    uint256 constant RATE_HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 481_880_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("arb-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new wstETH_L2_CustomPriceFeed(ASSET, RATE_FEED, RATE_HEARTBEAT, NAV, BASE);
    }

    /// @dev In-EVM ground truth: rateFeed answer * NAV(base/USD, 8 dec) / 10**rateFeedDecimals.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(BASE);
        uint256 base8 = uint256(pd.price);
        (, int256 rate,,,) = AggregatorV3Interface(RATE_FEED).latestRoundData();
        uint256 rateDecimals = AggregatorV3Interface(RATE_FEED).decimals();
        uint256 expected = (uint256(rate) * base8) / (10 ** rateDecimals);

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == (asset/base) * NAV(base/USD) / 10**rateDecimals");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + RATE_HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale past the rate heartbeat");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), ASSET, "Underlying asset should match the priced token");
    }
}

contract wstETH_L2_CustomPriceFeedForkTest_Base is TestEnvConfigurator {
    wstETH_L2_CustomPriceFeed oracle;

    address constant ASSET = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address constant RATE_FEED = 0x43a5C292A453A3bF3606fa856197f09D7B74251a;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant BASE = 0x4200000000000000000000000000000000000006;
    uint256 constant RATE_HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 48_385_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("base-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new wstETH_L2_CustomPriceFeed(ASSET, RATE_FEED, RATE_HEARTBEAT, NAV, BASE);
    }

    /// @dev In-EVM ground truth: rateFeed answer * NAV(base/USD, 8 dec) / 10**rateFeedDecimals.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(BASE);
        uint256 base8 = uint256(pd.price);
        (, int256 rate,,,) = AggregatorV3Interface(RATE_FEED).latestRoundData();
        uint256 rateDecimals = AggregatorV3Interface(RATE_FEED).decimals();
        uint256 expected = (uint256(rate) * base8) / (10 ** rateDecimals);

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == (asset/base) * NAV(base/USD) / 10**rateDecimals");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + RATE_HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale past the rate heartbeat");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), ASSET, "Underlying asset should match the priced token");
    }
}

contract wstETH_L2_CustomPriceFeedForkTest_Optimism is TestEnvConfigurator {
    wstETH_L2_CustomPriceFeed oracle;

    address constant ASSET = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb;
    address constant RATE_FEED = 0xe59EBa0D492cA53C6f46015EEa00517F2707dc77;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant BASE = 0x4200000000000000000000000000000000000006;
    uint256 constant RATE_HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 153_980_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("opt-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new wstETH_L2_CustomPriceFeed(ASSET, RATE_FEED, RATE_HEARTBEAT, NAV, BASE);
    }

    /// @dev In-EVM ground truth: rateFeed answer * NAV(base/USD, 8 dec) / 10**rateFeedDecimals.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(BASE);
        uint256 base8 = uint256(pd.price);
        (, int256 rate,,,) = AggregatorV3Interface(RATE_FEED).latestRoundData();
        uint256 rateDecimals = AggregatorV3Interface(RATE_FEED).decimals();
        uint256 expected = (uint256(rate) * base8) / (10 ** rateDecimals);

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == (asset/base) * NAV(base/USD) / 10**rateDecimals");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + RATE_HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale past the rate heartbeat");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), ASSET, "Underlying asset should match the priced token");
    }
}

contract wstETH_L2_CustomPriceFeedForkTest_Gnosis is TestEnvConfigurator {
    wstETH_L2_CustomPriceFeed oracle;

    address constant ASSET = 0x6C76971f98945AE98dD7d4DFcA8711ebea946eA6;
    address constant RATE_FEED = 0x0064AC007fF665CF8D0D3Af5E0AD1c26a3f853eA;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant BASE = 0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1;
    uint256 constant RATE_HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 47_106_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("gnosis-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new wstETH_L2_CustomPriceFeed(ASSET, RATE_FEED, RATE_HEARTBEAT, NAV, BASE);
    }

    /// @dev In-EVM ground truth: rateFeed answer * NAV(base/USD, 8 dec) / 10**rateFeedDecimals.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(BASE);
        uint256 base8 = uint256(pd.price);
        (, int256 rate,,,) = AggregatorV3Interface(RATE_FEED).latestRoundData();
        uint256 rateDecimals = AggregatorV3Interface(RATE_FEED).decimals();
        uint256 expected = (uint256(rate) * base8) / (10 ** rateDecimals);

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == (asset/base) * NAV(base/USD) / 10**rateDecimals");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + RATE_HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale past the rate heartbeat");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), ASSET, "Underlying asset should match the priced token");
    }
}
