// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {osToken_CustomPriceFeed} from "src/prices/protocols/osToken_CustomPriceFeed.sol";
import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_PriceOracleChainlink} from "test/mocks/price_oracles.sol";

/// @notice Minimal StakeWise OsTokenVaultController mock — returns a settable osToken→underlying rate.
contract Mock_OsTokenVaultController {
    uint256 public rate; // assets per 1e18 shares

    constructor(uint256 rate_) {
        rate = rate_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * rate / 1e18;
    }
}

/// @title osToken_CustomPriceFeed unit tests (no fork)
/// @notice Exercises the generic osToken price math (`convertToAssets(1e18) * underlying/USD / 1e18`), staleness,
///         and the ICustomPriceFeed surface, using mock controller + mock Chainlink feed.
contract osToken_CustomPriceFeedTest is Test {
    Mock_ERC20 osToken;
    Mock_OsTokenVaultController controller;
    Mock_PriceOracleChainlink underlyingUsd;
    osToken_CustomPriceFeed oracle;

    uint256 constant HEARTBEAT = 3600;
    uint256 constant RATE = 1.072e18; // 1 osETH = 1.072 ETH
    uint256 constant USD = 3000e8; // ETH/USD = $3000 (8 decimals)

    function setUp() public {
        vm.warp(1_000_000); // non-zero base time so staleness subtraction doesn't underflow
        osToken = new Mock_ERC20("osETH", 18);
        controller = new Mock_OsTokenVaultController(RATE);
        underlyingUsd = new Mock_PriceOracleChainlink("ETH/USD", USD, 8);
        oracle = new osToken_CustomPriceFeed(address(osToken), address(controller), address(underlyingUsd), HEARTBEAT);
    }

    function test_price() public view {
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale);
        // 1.072e18 * 3000e8 / 1e18 = 3216e8 = $3216 (8 decimals)
        assertEq(price, RATE * USD / 1e18);
        assertEq(price, 3216e8);
    }

    function test_metadata() public view {
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.underlyingAssetSupported(), address(osToken));
        assertTrue(oracle.supportsInterface(type(ICustomPriceFeed).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    function test_latestRoundData_matchesPrice() public view {
        (, int256 answer,,,) = oracle.latestRoundData();
        assertEq(uint256(answer), RATE * USD / 1e18);
    }

    function test_stale_whenFeedStale() public {
        underlyingUsd.setUpdatedAt(block.timestamp - HEARTBEAT); // exactly heartbeat old → stale
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale);
        assertEq(price, 0);
        (, int256 answer,,,) = oracle.latestRoundData();
        assertEq(answer, 0, "stale returns answer 0");
    }

    function test_stale_whenUsdNonPositive() public {
        Mock_PriceOracleChainlink zeroFeed = new Mock_PriceOracleChainlink("ETH/USD", 0, 8);
        osToken_CustomPriceFeed o =
            new osToken_CustomPriceFeed(address(osToken), address(controller), address(zeroFeed), HEARTBEAT);
        (uint256 price, bool stale) = o.getLatestPrice();
        assertTrue(stale);
        assertEq(price, 0);
    }

    function test_stale_whenRateZero() public {
        controller.setRate(0);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale);
        assertEq(price, 0);
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new osToken_CustomPriceFeed(address(0), address(controller), address(underlyingUsd), HEARTBEAT);

        vm.expectRevert();
        new osToken_CustomPriceFeed(address(osToken), address(0), address(underlyingUsd), HEARTBEAT);

        vm.expectRevert();
        new osToken_CustomPriceFeed(address(osToken), address(controller), address(0), HEARTBEAT);

        vm.expectRevert();
        new osToken_CustomPriceFeed(address(osToken), address(controller), address(underlyingUsd), 0);
    }
}
