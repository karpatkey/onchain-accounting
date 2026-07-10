// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {sUSDe_CustomPriceFeed} from "src/prices/protocols/sUSDe_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract sUSDe_CustomPriceFeedForkTest is TestEnvConfigurator {
    sUSDe_CustomPriceFeed oracle;

    address constant S_USDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new sUSDe_CustomPriceFeed(S_USDE, NAV, USDE);
    }

    /// @dev In-EVM ground truth: convertToAssets(unit) * NAV(base/USD, 8 dec) / unit.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(USDE);
        uint256 base8 = uint256(pd.price);
        uint256 unit = 10 ** IERC4626(S_USDE).decimals();
        uint256 assetsPerShare = IERC4626(S_USDE).convertToAssets(unit);
        uint256 expected = (assetsPerShare * base8) / unit;

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == convertToAssets(unit) * NAV(base/USD) / unit");
        assertEq(stale, false);
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), S_USDE, "Underlying asset should match the vault share token");
    }
}
