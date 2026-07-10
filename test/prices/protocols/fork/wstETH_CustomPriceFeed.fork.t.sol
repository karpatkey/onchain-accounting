// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {wstETH_CustomPriceFeed} from "src/prices/protocols/wstETH_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

interface IwstETHRate {
    function stEthPerToken() external view returns (uint256);
}

contract wstETH_CustomPriceFeedForkTest is TestEnvConfigurator {
    wstETH_CustomPriceFeed wstEthPriceOracle;

    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant STETH_TO_ETH_CHAINLINK = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant STETH_TO_ETH_HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        wstEthPriceOracle =
            new wstETH_CustomPriceFeed(WSTETH, STETH_TO_ETH_CHAINLINK, STETH_TO_ETH_HEARTBEAT, NAV, WETH);
    }

    /// @dev In-EVM ground truth: stEthPerToken * (stETH/ETH) / 10**rateDec = ETH per wstETH; * NAV(ETH/USD) / 1e18.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(WETH);
        uint256 base8 = uint256(pd.price);
        uint256 stEthPerToken = IwstETHRate(WSTETH).stEthPerToken();
        (, int256 stEthEth,,,) = AggregatorV3Interface(STETH_TO_ETH_CHAINLINK).latestRoundData();
        uint256 rateDecimals = AggregatorV3Interface(STETH_TO_ETH_CHAINLINK).decimals();

        uint256 ethPerWstEth = (stEthPerToken * uint256(stEthEth)) / (10 ** rateDecimals);
        uint256 expected = (ethPerWstEth * base8) / 1e18;

        (uint256 price, bool stale) = wstEthPriceOracle.getLatestPrice();
        assertEq(price, expected, "price == stEthPerToken * (stETH/ETH) * NAV(ETH/USD)");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + STETH_TO_ETH_HEARTBEAT + 1);
        (uint256 price, bool stale) = wstEthPriceOracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale past the rate heartbeat");
    }

    function test_decimals() public view {
        assertEq(wstEthPriceOracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(wstEthPriceOracle.underlyingAssetSupported(), WSTETH, "Underlying asset should match wstETH token");
    }
}
