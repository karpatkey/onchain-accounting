// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ankrETH_CustomPriceFeed} from "src/prices/protocols/ankrETH_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface IankrETHRatio {
    function ratio() external view returns (uint256);
}

contract ankrETH_CustomPriceFeedForkTest is TestEnvConfigurator {
    ankrETH_CustomPriceFeed ankrEthPriceOracle;

    address constant ANKR_ETH = 0xE95A203B1a91a908F9B9CE46459d101078c2c3cb;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        ankrEthPriceOracle = new ankrETH_CustomPriceFeed(ANKR_ETH, NAV, WETH);
    }

    /// @dev In-EVM ground truth: NAV base/USD (8 dec) * 1e18 / ankrETH.ratio() (ankrETH-per-ETH, 18 dec).
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(WETH);
        uint256 base8 = uint256(pd.price);
        uint256 ratio = IankrETHRatio(ANKR_ETH).ratio();
        uint256 expected = (base8 * 1e18) / ratio;

        (uint256 price, bool stale) = ankrEthPriceOracle.getLatestPrice();
        assertEq(price, expected, "price == NAV(ETH/USD) * 1e18 / ankrETH.ratio()");
        assertEq(stale, false);
    }

    function test_decimals() public view {
        assertEq(ankrEthPriceOracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(ankrEthPriceOracle.underlyingAssetSupported(), ANKR_ETH, "Underlying asset should match ankrETH token");
    }
}
