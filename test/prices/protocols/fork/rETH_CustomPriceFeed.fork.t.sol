// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {rETH_CustomPriceFeed} from "src/prices/protocols/rETH_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface IrETHRate {
    function getExchangeRate() external view returns (uint256);
}

contract rETH_CustomPriceFeedForkTest is TestEnvConfigurator {
    rETH_CustomPriceFeed rEthPriceOracle;

    address constant RETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        _useNewNavImpl(NAV);

        rEthPriceOracle = new rETH_CustomPriceFeed(RETH, NAV, WETH);
    }

    /// @dev In-EVM ground truth: rETH.getExchangeRate() (18 dec) * NAV base/USD (8 dec) / 1e18.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(WETH);
        uint256 base8 = uint256(pd.price);
        uint256 rate = IrETHRate(RETH).getExchangeRate();
        uint256 expected = (rate * base8) / 1e18;

        (uint256 price, bool stale) = rEthPriceOracle.getLatestPrice();
        assertEq(price, expected, "price == rETH.getExchangeRate() * NAV(ETH/USD) / 1e18");
        assertEq(stale, false);
    }

    function test_decimals() public view {
        assertEq(rEthPriceOracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(rEthPriceOracle.underlyingAssetSupported(), RETH, "Underlying asset should match rETH token");
    }
}
