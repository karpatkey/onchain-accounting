// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {RWIV_CustomPriceFeed} from "src/prices/protocols/RWIV_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract RWIV_CustomPriceFeedForkTest is TestEnvConfigurator {
    RWIV_CustomPriceFeed oracle;

    address constant RWIV = 0xcAFeAA466736ac01e0AC9Ca72644beF348694731;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        _useNewNavImpl(NAV);

        oracle = new RWIV_CustomPriceFeed(RWIV, NAV, USDC);
    }

    /// @dev In-EVM ground truth: convertToAssets(unit) * NAV(base/USD, 8 dec) / unit.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(USDC);
        uint256 base8 = uint256(pd.price);
        uint256 unit = 10 ** IERC4626(RWIV).decimals();
        uint256 assetsPerShare = IERC4626(RWIV).convertToAssets(unit);
        uint256 expected = (assetsPerShare * base8) / unit;

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == convertToAssets(unit) * NAV(base/USD) / unit");
        assertEq(stale, false);
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), RWIV, "Underlying asset should match the vault share token");
    }
}
