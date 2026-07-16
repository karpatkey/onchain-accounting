// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {eETH_CustomPriceFeed} from "src/prices/protocols/eETH_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @dev Reads base/USD from the REAL live NAV, upgraded to this build's implementation on the fork via
///      `_useNewNavImpl`. eETH ≡ ETH 1:1, so the fundamental price IS ETH/USD.
contract eETH_CustomPriceFeedForkTest is TestEnvConfigurator {
    eETH_CustomPriceFeed eEthPriceOracle;

    address constant EETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        _useNewNavImpl(NAV);

        eEthPriceOracle = new eETH_CustomPriceFeed(EETH, NAV, WETH);
    }

    /// @dev Pure-fundamental ground truth: eETH ≡ ETH 1:1, so price == NAV(ETH/USD).
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(WETH);
        uint256 expected = uint256(pd.price);

        (uint256 price, bool stale) = eEthPriceOracle.getLatestPrice();
        assertEq(price, expected, "price == NAV(ETH/USD) (eETH tracks ETH 1:1)");
        assertFalse(stale);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + 30 days);
        (uint256 price, bool stale) = eEthPriceOracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked stale when the NAV base feed is stale");
    }

    function test_decimals() public view {
        assertEq(eEthPriceOracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(eEthPriceOracle.underlyingAssetSupported(), EETH, "Underlying asset should match eETH token");
    }
}
