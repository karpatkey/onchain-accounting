// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {CrossRateCustomPriceFeed} from "src/prices/protocols/CrossRateCustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_PriceOracleChainlink} from "test/mocks/price_oracles.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title CrossRateCustomPriceFeed unit tests (no fork)
/// @dev Computes Y/USD = (Y/X) * (X/USD), where X/USD (the base) now comes from the NAV via a Mock_NAVCalculator.
///      The constructor takes `(underlying, yToXFeed, heartbeat, nav, baseAsset)`.
contract CrossRateCustomPriceFeedTest is Test {
    Mock_ERC20 underlyingAsset; // Y
    Mock_PriceOracleChainlink yToXFeed; // Y/X rate feed
    Mock_ERC20 baseAsset; // X, priced by the NAV
    Mock_NAVCalculator nav;
    uint256 constant HEARTBEAT = 86_400;

    function setUp() public {
        underlyingAsset = new Mock_ERC20("Y", 18);
        yToXFeed = new Mock_PriceOracleChainlink("Y/X", 1.1e18, 18);
        baseAsset = new Mock_ERC20("WETH", 18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(baseAsset), 3000e8, 8); // X/USD = $3000
    }

    function test_constructor_valid() public {
        CrossRateCustomPriceFeed oracle = new CrossRateCustomPriceFeed(
            address(underlyingAsset), address(yToXFeed), HEARTBEAT, address(nav), address(baseAsset)
        );
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(underlyingAsset));
    }

    function test_invalidConstructorArgs_zeroUnderlying() public {
        vm.expectRevert();
        new CrossRateCustomPriceFeed(address(0), address(yToXFeed), HEARTBEAT, address(nav), address(baseAsset));
    }

    function test_invalidConstructorArgs_zeroYToXFeed() public {
        vm.expectRevert();
        new CrossRateCustomPriceFeed(address(underlyingAsset), address(0), HEARTBEAT, address(nav), address(baseAsset));
    }

    function test_invalidConstructorArgs_nonChainlinkYToXFeed() public {
        vm.expectRevert();
        new CrossRateCustomPriceFeed(
            address(underlyingAsset), address(underlyingAsset), HEARTBEAT, address(nav), address(baseAsset)
        );
    }

    function test_invalidConstructorArgs_zeroYToXHeartbeat() public {
        vm.expectRevert();
        new CrossRateCustomPriceFeed(address(underlyingAsset), address(yToXFeed), 0, address(nav), address(baseAsset));
    }

    function test_invalidConstructorArgs_zeroNav() public {
        vm.expectRevert();
        new CrossRateCustomPriceFeed(
            address(underlyingAsset), address(yToXFeed), HEARTBEAT, address(0), address(baseAsset)
        );
    }

    function test_invalidConstructorArgs_zeroBaseAsset() public {
        vm.expectRevert();
        new CrossRateCustomPriceFeed(address(underlyingAsset), address(yToXFeed), HEARTBEAT, address(nav), address(0));
    }

    function test_invalidConstructorArgs_nonErc20BaseAsset() public {
        vm.expectRevert();
        new CrossRateCustomPriceFeed(address(underlyingAsset), address(yToXFeed), HEARTBEAT, address(nav), address(nav));
    }
}
