// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {wstETH_CustomPriceFeed} from "src/prices/protocols/wstETH_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface IwstETHRate {
    function stEthPerToken() external view returns (uint256);
}

/// @dev Reads base/USD from the REAL live NAV, which `_useNewNavImpl` upgrades to this build's implementation on the
///      fork (the deployed proxy predates this PR's PriceFeedData shape). The on-chain rate (stEthPerToken) is read
///      live, so this verifies the pure-fundamental price math end to end.
contract wstETH_CustomPriceFeedForkTest is TestEnvConfigurator {
    wstETH_CustomPriceFeed wstEthPriceOracle;

    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        _useNewNavImpl(NAV);

        wstEthPriceOracle = new wstETH_CustomPriceFeed(WSTETH, NAV, WETH);
    }

    /// @dev Pure-fundamental ground truth: stEthPerToken (stETH per wstETH, 18dp) × NAV(ETH/USD, 8dp) / 1e18,
    ///      treating stETH/ETH ≡ 1.0 (no market leg).
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(WETH);
        uint256 base8 = uint256(pd.price);
        uint256 stEthPerToken = IwstETHRate(WSTETH).stEthPerToken();
        uint256 expected = (stEthPerToken * base8) / 1e18;

        (uint256 price, bool stale) = wstEthPriceOracle.getLatestPrice();
        assertEq(price, expected, "price == stEthPerToken * NAV(ETH/USD)");
        assertFalse(stale);
    }

    /// @dev Fundamental feed carries no own heartbeat; it goes stale only when the NAV's base (WETH) feed is stale.
    /// @dev ADR 0029: a stale NAV base still prices the asset (flagged stale) until the base's last update is
    ///      `MAX_STALE_PRICE_AGE` old; past that the base has no usable price and the feed returns (0, true).
    function test_getLatestPriceStale() public {
        (uint256 freshPrice, bool freshStale) = wstEthPriceOracle.getLatestPrice();
        assertFalse(freshStale, "control: fresh at the fork block");
        assertGt(freshPrice, 0);

        vm.warp(block.timestamp + 2 days); // base past its heartbeat, well inside the cap
        (uint256 price, bool stale) = wstEthPriceOracle.getLatestPrice();
        assertEq(stale, true, "Price should be marked stale when the NAV base feed is stale");
        assertEq(price, freshPrice, "a stale base keeps the last price (ADR 0029)");

        vm.warp(block.timestamp + 30 days); // base past MAX_STALE_PRICE_AGE: no usable base price
        (price, stale) = wstEthPriceOracle.getLatestPrice();
        assertEq(price, 0, "no usable base price past the 7-day cap");
        assertEq(stale, true);
    }

    function test_decimals() public view {
        assertEq(wstEthPriceOracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(wstEthPriceOracle.underlyingAssetSupported(), WSTETH, "Underlying asset should match wstETH token");
    }
}
