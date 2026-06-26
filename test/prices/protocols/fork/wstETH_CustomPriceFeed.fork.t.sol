// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {wstETH_CustomPriceFeed} from "src/prices/protocols/wstETH_CustomPriceFeed.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

interface IwstETHRate {
    function stEthPerToken() external view returns (uint256);
}

contract wstETH_CustomPriceFeedForkTest is TestEnvConfigurator {
    wstETH_CustomPriceFeed wstEthPriceOracle;

    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant STETH_TO_ETH_CHAINLINK = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address constant ETH_TO_USD_CHAINLINK = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 constant STETH_TO_ETH_HEARTBEAT = 86_400;
    uint256 constant ETH_TO_USD_HEARTBEAT = 3600;
    uint256 constant FORK_BLOCK = 24_199_054;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        wstEthPriceOracle = new wstETH_CustomPriceFeed(
            WSTETH, STETH_TO_ETH_CHAINLINK, ETH_TO_USD_CHAINLINK, STETH_TO_ETH_HEARTBEAT, ETH_TO_USD_HEARTBEAT
        );
    }

    /// @dev Independently recompute price = stEthPerToken * (stETH/ETH) * (ETH/USD) from the three live
    ///      values at the fork block and assert the oracle matches exactly (in-EVM ground truth).
    function test_getLatestPrice() public view {
        uint256 stEthPerToken = IwstETHRate(WSTETH).stEthPerToken();
        (, int256 stEthEth,,,) = AggregatorV3Interface(STETH_TO_ETH_CHAINLINK).latestRoundData();
        (, int256 ethUsd,,,) = AggregatorV3Interface(ETH_TO_USD_CHAINLINK).latestRoundData();

        // stEthPerToken (18) * stETH/ETH (18) / 1e18 = ETH per wstETH (18); * ETH/USD (8) / 1e18 = USD (8)
        uint256 ethPerWstEth = (stEthPerToken * uint256(stEthEth)) / 1e18;
        uint256 expected = (ethPerWstEth * uint256(ethUsd)) / 1e18;

        (uint256 price, bool stale) = wstEthPriceOracle.getLatestPrice();
        assertEq(price, expected, "price == stEthPerToken * stETH/ETH * ETH/USD");
        assertEq(stale, false);
    }

    /// @notice The fix: pricing via the real stETH/ETH rate (< 1) yields a strictly lower price than the old
    ///         1:1 assumption (stEthPerToken * ETH/USD), confirming the depeg is now reflected.
    function test_reflectsStEthDiscountVsOld1to1() public view {
        uint256 stEthPerToken = IwstETHRate(WSTETH).stEthPerToken();
        (, int256 ethUsd,,,) = AggregatorV3Interface(ETH_TO_USD_CHAINLINK).latestRoundData();
        uint256 old1to1 = (stEthPerToken * uint256(ethUsd)) / 1e18; // legacy formula (stETH == ETH)

        (uint256 price,) = wstEthPriceOracle.getLatestPrice();
        assertLt(price, old1to1, "new price must reflect stETH/ETH < 1 (no 1:1 over-valuation)");
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + STETH_TO_ETH_HEARTBEAT + 1);
        (uint256 price, bool stale) = wstEthPriceOracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(wstEthPriceOracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(wstEthPriceOracle.underlyingAssetSupported(), WSTETH, "Underlying asset should match wstETH token");
    }
}
