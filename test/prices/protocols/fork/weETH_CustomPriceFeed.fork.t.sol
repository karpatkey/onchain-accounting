// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {weETH_CustomPriceFeed} from "src/prices/protocols/weETH_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface IweETHRate {
    function getRate() external view returns (uint256);
}

/// @dev Reads base/USD from the REAL live NAV, upgraded to this build's implementation on the fork via
///      `_useNewNavImpl`. The on-chain weETH exchange rate (getRate) is read live.
contract weETH_CustomPriceFeedForkTest is TestEnvConfigurator {
    weETH_CustomPriceFeed oracle;

    address constant ASSET = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee; // weETH
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        _useNewNavImpl(NAV);

        oracle = new weETH_CustomPriceFeed(ASSET, NAV, WETH);
    }

    /// @dev Pure-fundamental ground truth: weETH.getRate() (eETH per weETH, 18dp) × NAV(ETH/USD, 8dp) / 1e18,
    ///      treating eETH/ETH ≡ 1.0.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(WETH);
        uint256 base8 = uint256(pd.price);
        uint256 rate = IweETHRate(ASSET).getRate();
        uint256 expected = (rate * base8) / 1e18;

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == weETH.getRate() * NAV(ETH/USD)");
        assertFalse(stale);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + 30 days);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked stale when the NAV base feed is stale");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), ASSET, "Underlying asset should match the priced token");
    }
}
