// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {osToken_CustomPriceFeed} from "src/prices/protocols/osToken_CustomPriceFeed.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

interface IOsTokenVaultControllerView {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @title osToken_CustomPriceFeed fork tests
/// @notice Validates the generic osToken price feed against live chain state: `getLatestPrice` must equal
///         `convertToAssets(1e18) * underlying/USD / 1e18` read directly from the controller + Chainlink feed.
///         Covered: osETH (mainnet, underlying ETH) and osGNO (Gnosis, underlying GNO).

contract osETH_CustomPriceFeedForkTest is TestEnvConfigurator {
    osToken_CustomPriceFeed oracle;

    address constant OSETH = 0xf1C9acDc66974dFB6dEcB12aA385b9cD01190E38;
    address constant CONTROLLER = 0x2A261e60FB14586B474C208b1B7AC6D0f5000306;
    address constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 constant HEARTBEAT = 3600;
    uint256 constant FORK_BLOCK = 25_214_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        oracle = new osToken_CustomPriceFeed(OSETH, CONTROLLER, ETH_USD, HEARTBEAT);
    }

    function test_getLatestPrice_matchesOnChain() public view {
        uint256 rate = IOsTokenVaultControllerView(CONTROLLER).convertToAssets(1e18);
        (, int256 ethUsd,,,) = AggregatorV3Interface(ETH_USD).latestRoundData();
        uint256 expected = rate * uint256(ethUsd) / 1e18;

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale);
        assertEq(price, expected, "osETH price = convertToAssets(1e18) * ETH/USD / 1e18");
        assertGt(price, 1000e8, "sanity: osETH > $1000");
        assertLt(price, 100_000e8, "sanity: osETH < $100k");
    }

    function test_metadata() public view {
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.underlyingAssetSupported(), OSETH);
    }

    function test_stale() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0);
        assertTrue(stale);
    }
}

contract osGNO_CustomPriceFeedForkTest is TestEnvConfigurator {
    osToken_CustomPriceFeed oracle;

    address constant OSGNO = 0xF490c80aAE5f2616d3e3BDa2483E30C4CB21d1A0;
    address constant CONTROLLER = 0x60B2053d7f2a0bBa70fe6CDd88FB47b579B9179a;
    address constant GNO_USD = 0x22441d81416430A54336aB28765abd31a792Ad37;
    uint256 constant HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 46_400_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("gnosis-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        oracle = new osToken_CustomPriceFeed(OSGNO, CONTROLLER, GNO_USD, HEARTBEAT);
    }

    function test_getLatestPrice_matchesOnChain() public view {
        uint256 rate = IOsTokenVaultControllerView(CONTROLLER).convertToAssets(1e18);
        (, int256 gnoUsd,,,) = AggregatorV3Interface(GNO_USD).latestRoundData();
        uint256 expected = rate * uint256(gnoUsd) / 1e18;

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale);
        assertEq(price, expected, "osGNO price = convertToAssets(1e18) * GNO/USD / 1e18");
        assertGt(price, 10e8, "sanity: osGNO > $10");
    }

    function test_metadata() public view {
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.underlyingAssetSupported(), OSGNO);
    }
}
