// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ETHx_CustomPriceFeed} from "src/prices/protocols/ETHx_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface IStaderStakePoolsManagerRate {
    function getExchangeRate() external view returns (uint256);
}

contract ETHx_CustomPriceFeedForkTest is TestEnvConfigurator {
    ETHx_CustomPriceFeed ethxPriceOracle;

    address constant ETHX = 0xA35b1B31Ce002FBF2058D22F30f95D405200A15b;
    address constant STAKE_POOLS_MANAGER = 0xcf5EA1b38380f6aF39068375516Daf40Ed70D299;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        ethxPriceOracle = new ETHx_CustomPriceFeed(ETHX, STAKE_POOLS_MANAGER, NAV, WETH);
    }

    /// @dev In-EVM ground truth: StaderStakePoolsManager.getExchangeRate() (18 dec) * NAV base/USD (8 dec) / 1e18.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(WETH);
        uint256 base8 = uint256(pd.price);
        uint256 rate = IStaderStakePoolsManagerRate(STAKE_POOLS_MANAGER).getExchangeRate();
        uint256 expected = (rate * base8) / 1e18;

        (uint256 price, bool stale) = ethxPriceOracle.getLatestPrice();
        assertEq(price, expected, "price == getExchangeRate() * NAV(ETH/USD) / 1e18");
        assertEq(stale, false);
    }

    function test_decimals() public view {
        assertEq(ethxPriceOracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(ethxPriceOracle.underlyingAssetSupported(), ETHX, "Underlying asset should match ETHx token");
    }
}
