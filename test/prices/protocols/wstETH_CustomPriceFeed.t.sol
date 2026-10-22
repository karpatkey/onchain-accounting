// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {wstETH_CustomPriceFeed} from "src/prices/protocols/wstETH_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @dev Minimal wstETH mock exposing a settable `stEthPerToken` on top of an ERC20 surface.
contract Mock_wstETH is Mock_ERC20 {
    uint256 public stEthPerToken;

    constructor(uint256 rate_) Mock_ERC20("wstETH", 18) {
        stEthPerToken = rate_;
    }

    function setRate(uint256 rate_) external {
        stEthPerToken = rate_;
    }
}

/// @title wstETH_CustomPriceFeed unit tests (no fork)
/// @dev Pure-fundamental feed: `price = stEthPerToken × (ETH/USD)`, treating stETH/ETH ≡ 1.0. Base/USD (ETH/USD)
///      comes from the NAV via a Mock_NAVCalculator; the constructor takes `(wstEth, nav, baseAsset)`.
contract wstETH_CustomPriceFeedTest is Test {
    Mock_wstETH wstEth;
    Mock_ERC20 weth; // base asset priced by the NAV
    Mock_NAVCalculator nav;

    function setUp() public {
        wstEth = new Mock_wstETH(1.1e18); // 1.1 stETH per wstETH
        weth = new Mock_ERC20("WETH", 18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(weth), 3000e8, 8); // ETH/USD = $3000
    }

    function test_constructor_valid() public {
        wstETH_CustomPriceFeed oracle = new wstETH_CustomPriceFeed(address(wstEth), address(nav), address(weth));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(wstEth));
        assertEq(address(oracle.NAV()), address(nav));
        assertEq(oracle.BASE_ASSET(), address(weth));
    }

    function test_getLatestPrice_fundamental() public {
        wstETH_CustomPriceFeed oracle = new wstETH_CustomPriceFeed(address(wstEth), address(nav), address(weth));
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale);
        // 1.1 stETH/wstETH × $3000 = $3300 (8 decimals)
        assertEq(price, 3300e8);
    }

    function test_getLatestPrice_staleWhenRateZero() public {
        wstEth.setRate(0);
        wstETH_CustomPriceFeed oracle = new wstETH_CustomPriceFeed(address(wstEth), address(nav), address(weth));
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale);
        assertEq(price, 0);
    }

    /// @dev ADR 0029: a stale base still prices the asset (rate × last base price), flagged stale (was: price 0).
    function test_getLatestPrice_staleWhenBaseStale() public {
        nav.setAssetStale(address(weth), true);
        wstETH_CustomPriceFeed oracle = new wstETH_CustomPriceFeed(address(wstEth), address(nav), address(weth));
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale);
        assertEq(price, 3300e8, "1.1 x last base price");
    }

    /// @dev A zero rate is structural: still 0 even when the base is merely stale.
    function test_getLatestPrice_zeroWhenBaseStaleAndRateZero() public {
        nav.setAssetStale(address(weth), true);
        wstEth.setRate(0);
        wstETH_CustomPriceFeed oracle = new wstETH_CustomPriceFeed(address(wstEth), address(nav), address(weth));
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale);
        assertEq(price, 0);
    }

    function test_constructor_revertsOnZeroWstEth() public {
        vm.expectRevert();
        new wstETH_CustomPriceFeed(address(0), address(nav), address(weth));
    }

    function test_constructor_revertsOnZeroNav() public {
        vm.expectRevert();
        new wstETH_CustomPriceFeed(address(wstEth), address(0), address(weth));
    }

    function test_constructor_revertsOnZeroBaseAsset() public {
        vm.expectRevert();
        new wstETH_CustomPriceFeed(address(wstEth), address(nav), address(0));
    }

    function test_constructor_revertsOnNonErc20BaseAsset() public {
        // nav has no totalSupply → assertERC20Address probe fails.
        vm.expectRevert();
        new wstETH_CustomPriceFeed(address(wstEth), address(nav), address(nav));
    }
}
