// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {eETH_CustomPriceFeed} from "src/prices/protocols/eETH_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

interface IweETHRate {
    function getRate() external view returns (uint256);
}

contract eETH_CustomPriceFeedForkTest is TestEnvConfigurator {
    eETH_CustomPriceFeed eEthPriceOracle;

    address constant EETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant WEETH_TO_ETH_CHAINLINK = 0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant WEETH_TO_ETH_HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        eEthPriceOracle =
            new eETH_CustomPriceFeed(EETH, WEETH, WEETH_TO_ETH_CHAINLINK, WEETH_TO_ETH_HEARTBEAT, NAV, WETH);
    }

    /// @dev In-EVM ground truth: eETH/ETH = (weETH/ETH) * 1e18 / weETH.getRate(); price = eETH/ETH * NAV(ETH/USD) / 1e18.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(WETH);
        uint256 base8 = uint256(pd.price);
        (, int256 weEthEth,,,) = AggregatorV3Interface(WEETH_TO_ETH_CHAINLINK).latestRoundData();
        uint256 weEthPerEeth = IweETHRate(WEETH).getRate();

        uint256 eEthToEth = (uint256(weEthEth) * 1e18) / weEthPerEeth;
        uint256 expected = (eEthToEth * base8) / 1e18;

        (uint256 price, bool stale) = eEthPriceOracle.getLatestPrice();
        assertEq(price, expected, "price == (weETH/ETH / eETH-per-weETH) * NAV(ETH/USD)");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + WEETH_TO_ETH_HEARTBEAT + 1);
        (uint256 price, bool stale) = eEthPriceOracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale past the rate heartbeat");
    }

    function test_decimals() public view {
        assertEq(eEthPriceOracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(eEthPriceOracle.underlyingAssetSupported(), EETH, "Underlying asset should match eETH token");
    }
}
