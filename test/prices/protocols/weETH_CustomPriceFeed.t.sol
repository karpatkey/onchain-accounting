// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {weETH_CustomPriceFeed} from "src/prices/protocols/weETH_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @dev Minimal weETH mock exposing a settable `getRate` (eETH per weETH) on top of an ERC20 surface.
contract Mock_weETH is Mock_ERC20 {
    uint256 public getRate;

    constructor(uint256 rate_) Mock_ERC20("weETH", 18) {
        getRate = rate_;
    }

    function setRate(uint256 rate_) external {
        getRate = rate_;
    }
}

/// @title weETH_CustomPriceFeed unit tests (no fork)
/// @dev Pure-fundamental feed: `price = weETH.getRate() × (ETH/USD)`, treating eETH/ETH ≡ 1.0. Base/USD comes from the
///      NAV via a Mock_NAVCalculator; the constructor takes `(weEth, nav, baseAsset)`.
contract weETH_CustomPriceFeedTest is Test {
    Mock_weETH weEth;
    Mock_ERC20 weth;
    Mock_NAVCalculator nav;

    function setUp() public {
        weEth = new Mock_weETH(1.06e18); // 1.06 eETH per weETH
        weth = new Mock_ERC20("WETH", 18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(weth), 3000e8, 8); // ETH/USD = $3000
    }

    function test_constructor_valid() public {
        weETH_CustomPriceFeed oracle = new weETH_CustomPriceFeed(address(weEth), address(nav), address(weth));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(weEth));
        assertEq(address(oracle.NAV()), address(nav));
        assertEq(oracle.BASE_ASSET(), address(weth));
    }

    function test_getLatestPrice_fundamental() public {
        weETH_CustomPriceFeed oracle = new weETH_CustomPriceFeed(address(weEth), address(nav), address(weth));
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale);
        // 1.06 eETH/weETH × $3000 = $3180 (8 decimals)
        assertEq(price, 3180e8);
    }

    function test_getLatestPrice_staleWhenRateZero() public {
        weEth.setRate(0);
        weETH_CustomPriceFeed oracle = new weETH_CustomPriceFeed(address(weEth), address(nav), address(weth));
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale);
        assertEq(price, 0);
    }

    function test_invalidConstructorArgs() public {
        // zero underlying
        vm.expectRevert();
        new weETH_CustomPriceFeed(address(0), address(nav), address(weth));

        // zero nav (not a contract)
        vm.expectRevert();
        new weETH_CustomPriceFeed(address(weEth), address(0), address(weth));

        // zero base asset
        vm.expectRevert();
        new weETH_CustomPriceFeed(address(weEth), address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new weETH_CustomPriceFeed(address(weEth), address(nav), address(nav));
    }
}
