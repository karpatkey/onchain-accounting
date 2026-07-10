// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {sUSDS_CustomPriceFeed} from "src/prices/protocols/sUSDS_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract sUSDS_CustomPriceFeedTest is TestEnvConfigurator {
    sUSDS_CustomPriceFeed oracle;

    address constant S_USDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new sUSDS_CustomPriceFeed(S_USDS, NAV, USDS);
    }

    /// @dev In-EVM ground truth: convertToAssets(unit) * NAV(base/USD, 8 dec) / unit.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(USDS);
        uint256 base8 = uint256(pd.price);
        uint256 unit = 10 ** IERC4626(S_USDS).decimals();
        uint256 assetsPerShare = IERC4626(S_USDS).convertToAssets(unit);
        uint256 expected = (assetsPerShare * base8) / unit;

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == convertToAssets(unit) * NAV(base/USD) / unit");
        assertEq(stale, false);
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), S_USDS, "Underlying asset should match the vault share token");
    }
}
