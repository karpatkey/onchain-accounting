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

    // --- governingFeedFreshness: the leg with the greater age/heartbeat ratio wins ---

    uint256 constant BASE_HEARTBEAT = 3600; // base (X/USD) leg heartbeat; RATE (Y/X) leg uses HEARTBEAT = 86_400

    function _feed() internal returns (CrossRateCustomPriceFeed) {
        return new CrossRateCustomPriceFeed(
            address(underlyingAsset), address(yToXFeed), HEARTBEAT, address(nav), address(baseAsset)
        );
    }

    function test_governingFeedFreshness_rateLegGoverns() public {
        CrossRateCustomPriceFeed oracle = _feed();
        vm.warp(1_000_000);
        // rate age 40_000 / 86_400 = 0.46  >  base age 100 / 3600 = 0.028  → rate leg governs
        yToXFeed.setUpdatedAt(960_000);
        nav.setAssetFreshness(address(baseAsset), 999_900, BASE_HEARTBEAT);
        (uint256 updatedAt, uint256 heartbeat) = oracle.governingFeedFreshness();
        assertEq(updatedAt, 960_000, "rate leg updatedAt");
        assertEq(heartbeat, HEARTBEAT, "rate leg heartbeat");
    }

    function test_governingFeedFreshness_baseLegGoverns() public {
        CrossRateCustomPriceFeed oracle = _feed();
        vm.warp(1_000_000);
        // base age 3000 / 3600 = 0.83  >  rate age 100 / 86_400 = 0.001  → base leg governs
        yToXFeed.setUpdatedAt(999_900);
        nav.setAssetFreshness(address(baseAsset), 997_000, BASE_HEARTBEAT);
        (uint256 updatedAt, uint256 heartbeat) = oracle.governingFeedFreshness();
        assertEq(updatedAt, 997_000, "base leg updatedAt");
        assertEq(heartbeat, BASE_HEARTBEAT, "base leg heartbeat");
    }

    function test_governingFeedFreshness_reportsStaleLeg() public {
        CrossRateCustomPriceFeed oracle = _feed();
        vm.warp(1_000_000);
        // base leg is past its own heartbeat (age 5000 > 3600) and dominates the ratio → reported even though stale
        yToXFeed.setUpdatedAt(999_990);
        nav.setAssetFreshness(address(baseAsset), 995_000, BASE_HEARTBEAT);
        (uint256 updatedAt, uint256 heartbeat) = oracle.governingFeedFreshness();
        assertEq(updatedAt, 995_000, "stale base leg surfaced");
        assertEq(heartbeat, BASE_HEARTBEAT);
    }
}
