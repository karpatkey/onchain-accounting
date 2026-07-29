// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {sXDAI_CustomPriceFeed} from "src/prices/protocols/sXDAI_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract sXDAI_CustomPriceFeedTest is TestEnvConfigurator {
    sXDAI_CustomPriceFeed oracle;

    address constant S_XDAI = 0xaf204776c7245bF4147c2612BF6e5972Ee483701;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
    uint256 constant FORK_BLOCK = 47_106_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("gnosis-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        _useNewNavImpl(NAV);

        oracle = new sXDAI_CustomPriceFeed(S_XDAI, NAV, WXDAI);
    }

    /// @dev In-EVM ground truth: convertToAssets(unit) * NAV(base/USD, 8 dec) / unit.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(WXDAI);
        uint256 base8 = uint256(pd.price);
        uint256 unit = 10 ** IERC4626(S_XDAI).decimals();
        uint256 assetsPerShare = IERC4626(S_XDAI).convertToAssets(unit);
        uint256 expected = (assetsPerShare * base8) / unit;

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == convertToAssets(unit) * NAV(base/USD) / unit");
        assertEq(stale, false);
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), S_XDAI, "Underlying asset should match the vault share token");
    }
}
