// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {cbETH_CustomPriceFeed} from "src/prices/protocols/cbETH_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface IcbETHRate {
    function exchangeRate() external view returns (uint256);
}

contract cbETH_CustomPriceFeedForkTest is TestEnvConfigurator {
    cbETH_CustomPriceFeed cbEthPriceOracle;

    address constant CBETH = 0xBe9895146f7AF43049ca1c1AE358B0541Ea49704;
    // Live NAV proxy (same address on every chain); WETH is its registered base whose ETH/USD price we source.
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        cbEthPriceOracle = new cbETH_CustomPriceFeed(CBETH, NAV, WETH);
    }

    /// @dev In-EVM ground truth: cbETH.exchangeRate() (18 dec) * NAV base/USD (8 dec) / 1e18.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(WETH);
        uint256 base8 = uint256(pd.price); // NAV reports 8 decimals for WETH
        uint256 rate = IcbETHRate(CBETH).exchangeRate();
        uint256 expected = (rate * base8) / 1e18;

        (uint256 price, bool stale) = cbEthPriceOracle.getLatestPrice();
        assertEq(price, expected, "price == cbETH.exchangeRate() * NAV(ETH/USD) / 1e18");
        assertEq(stale, false);
    }

    function test_decimals() public view {
        assertEq(cbEthPriceOracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(cbEthPriceOracle.underlyingAssetSupported(), CBETH, "Underlying asset should match cbETH token");
    }
}
