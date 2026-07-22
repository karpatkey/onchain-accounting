// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {eETH_CustomPriceFeed} from "src/prices/protocols/eETH_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title eETH_CustomPriceFeed unit tests (no fork)
/// @dev Pure-fundamental feed: eETH ≡ ETH 1:1, so `price = ETH/USD`. Base/USD comes from the NAV via a
///      Mock_NAVCalculator; the constructor takes `(eEth, nav, baseAsset)`.
contract eETH_CustomPriceFeedTest is Test {
    Mock_ERC20 eEth;
    Mock_ERC20 weth; // base asset priced by the NAV
    Mock_NAVCalculator nav;

    function setUp() public {
        eEth = new Mock_ERC20("eETH", 18);
        weth = new Mock_ERC20("WETH", 18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(weth), 3000e8, 8); // ETH/USD = $3000
    }

    function test_constructor_valid() public {
        eETH_CustomPriceFeed oracle = new eETH_CustomPriceFeed(address(eEth), address(nav), address(weth));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(eEth));
        assertEq(address(oracle.NAV()), address(nav));
        assertEq(oracle.BASE_ASSET(), address(weth));
    }

    function test_getLatestPrice_tracksEth() public {
        eETH_CustomPriceFeed oracle = new eETH_CustomPriceFeed(address(eEth), address(nav), address(weth));
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale);
        assertEq(price, 3000e8); // eETH ≡ ETH → $3000
    }

    function test_getLatestPrice_staleWhenBaseStale() public {
        nav.setAssetStale(address(weth), true);
        eETH_CustomPriceFeed oracle = new eETH_CustomPriceFeed(address(eEth), address(nav), address(weth));
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale);
        assertEq(price, 0);
    }

    function test_invalidConstructorArgs() public {
        // zero eETH
        vm.expectRevert();
        new eETH_CustomPriceFeed(address(0), address(nav), address(weth));

        // zero nav (not a contract)
        vm.expectRevert();
        new eETH_CustomPriceFeed(address(eEth), address(0), address(weth));

        // zero base asset
        vm.expectRevert();
        new eETH_CustomPriceFeed(address(eEth), address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new eETH_CustomPriceFeed(address(eEth), address(nav), address(nav));
    }
}
