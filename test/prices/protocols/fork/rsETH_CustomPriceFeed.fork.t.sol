// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {rsETH_CustomPriceFeed} from "src/prices/protocols/rsETH_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface IRsethRateProvider {
    function getLatestRate() external view returns (uint256);
}

contract rsETH_CustomPriceFeedForkTest is TestEnvConfigurator {
    rsETH_CustomPriceFeed rsEthPriceOracle;

    address constant RSETH = 0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7;
    address constant RATE_PROVIDER = 0x0788906B19bA8f8d0e8a7015f0714DF3179D9aB6;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        rsEthPriceOracle = new rsETH_CustomPriceFeed(RSETH, RATE_PROVIDER, NAV, WETH);
    }

    /// @dev In-EVM ground truth: rateProvider.getLatestRate() (18 dec) * NAV base/USD (8 dec) / 1e18.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(WETH);
        uint256 base8 = uint256(pd.price);
        uint256 rate = IRsethRateProvider(RATE_PROVIDER).getLatestRate();
        uint256 expected = (rate * base8) / 1e18;

        (uint256 price, bool stale) = rsEthPriceOracle.getLatestPrice();
        assertEq(price, expected, "price == getLatestRate() * NAV(ETH/USD) / 1e18");
        assertEq(stale, false);
    }

    function test_decimals() public view {
        assertEq(rsEthPriceOracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(rsEthPriceOracle.underlyingAssetSupported(), RSETH, "Underlying asset should match rsETH token");
    }
}
