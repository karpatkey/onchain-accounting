// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {osToken_CustomPriceFeed} from "src/prices/protocols/osToken_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface IOsTokenVaultControllerView {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @title osToken_CustomPriceFeed fork tests
/// @notice Validates the generic osToken price feed against live chain state: `getLatestPrice` must equal
///         `convertToAssets(1e18) * NAV(base/USD) / 1e18`, with the base/USD term sourced from the live NAV.
///         Covered: osETH (mainnet, base WETH) and osGNO (Gnosis, base GNO).

contract osETH_CustomPriceFeedForkTest is TestEnvConfigurator {
    osToken_CustomPriceFeed oracle;

    address constant OSETH = 0xf1C9acDc66974dFB6dEcB12aA385b9cD01190E38;
    address constant CONTROLLER = 0x2A261e60FB14586B474C208b1B7AC6D0f5000306;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        oracle = new osToken_CustomPriceFeed(OSETH, CONTROLLER, NAV, WETH);
    }

    function test_getLatestPrice_matchesOnChain() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(WETH);
        uint256 base8 = uint256(pd.price);
        uint256 rate = IOsTokenVaultControllerView(CONTROLLER).convertToAssets(1e18);
        uint256 expected = rate * base8 / 1e18;

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale);
        assertEq(price, expected, "osETH price = convertToAssets(1e18) * NAV(ETH/USD) / 1e18");
        assertGt(price, 1000e8, "sanity: osETH > $1000");
        assertLt(price, 100_000e8, "sanity: osETH < $100k");
    }

    function test_metadata() public view {
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.underlyingAssetSupported(), OSETH);
    }
}

contract osGNO_CustomPriceFeedForkTest is TestEnvConfigurator {
    osToken_CustomPriceFeed oracle;

    address constant OSGNO = 0xF490c80aAE5f2616d3e3BDa2483E30C4CB21d1A0;
    address constant CONTROLLER = 0x60B2053d7f2a0bBa70fe6CDd88FB47b579B9179a;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    uint256 constant FORK_BLOCK = 47_106_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("gnosis-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        oracle = new osToken_CustomPriceFeed(OSGNO, CONTROLLER, NAV, GNO);
    }

    function test_getLatestPrice_matchesOnChain() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(GNO);
        uint256 base8 = uint256(pd.price);
        uint256 rate = IOsTokenVaultControllerView(CONTROLLER).convertToAssets(1e18);
        uint256 expected = rate * base8 / 1e18;

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale);
        assertEq(price, expected, "osGNO price = convertToAssets(1e18) * NAV(GNO/USD) / 1e18");
        assertGt(price, 10e8, "sanity: osGNO > $10");
    }

    function test_metadata() public view {
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.underlyingAssetSupported(), OSGNO);
    }
}
