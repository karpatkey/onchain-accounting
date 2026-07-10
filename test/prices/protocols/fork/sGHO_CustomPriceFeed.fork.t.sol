// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {sGHO_CustomPriceFeed} from "src/prices/protocols/sGHO_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract sGHO_CustomPriceFeedForkTest is TestEnvConfigurator {
    sGHO_CustomPriceFeed oracle;

    address constant SGHO = 0xE1753F2e00940cC31213dd92013cF019DFE4ca1d;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new sGHO_CustomPriceFeed(SGHO, NAV, GHO);
    }

    /// @dev In-EVM ground truth: convertToAssets(unit) * NAV(base/USD, 8 dec) / unit.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(GHO);
        uint256 base8 = uint256(pd.price);
        uint256 unit = 10 ** IERC4626(SGHO).decimals();
        uint256 assetsPerShare = IERC4626(SGHO).convertToAssets(unit);
        uint256 expected = (assetsPerShare * base8) / unit;

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == convertToAssets(unit) * NAV(base/USD) / unit");
        assertEq(stale, false);
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), SGHO, "Underlying asset should match the vault share token");
    }
}
