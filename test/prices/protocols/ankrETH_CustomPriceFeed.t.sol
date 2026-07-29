// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ankrETH_CustomPriceFeed} from "src/prices/protocols/ankrETH_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title ankrETH_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (ETH/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(ankrEth, nav, baseAsset)`. Price math (ratio()) is exercised in the fork test.
contract ankrETH_CustomPriceFeedTest is Test {
    Mock_ERC20 ankrEth;
    Mock_ERC20 weth;
    Mock_NAVCalculator nav;

    function setUp() public {
        ankrEth = new Mock_ERC20("ankrETH", 18);
        weth = new Mock_ERC20("WETH", 18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(weth), 3000e8, 8); // ETH/USD = $3000
    }

    function test_constructor_valid() public {
        ankrETH_CustomPriceFeed oracle = new ankrETH_CustomPriceFeed(address(ankrEth), address(nav), address(weth));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(ankrEth));
    }

    function test_invalidConstructorArgs() public {
        // zero underlying
        vm.expectRevert();
        new ankrETH_CustomPriceFeed(address(0), address(nav), address(weth));

        // zero nav (not a contract)
        vm.expectRevert();
        new ankrETH_CustomPriceFeed(address(ankrEth), address(0), address(weth));

        // zero base asset
        vm.expectRevert();
        new ankrETH_CustomPriceFeed(address(ankrEth), address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new ankrETH_CustomPriceFeed(address(ankrEth), address(nav), address(nav));
    }
}
