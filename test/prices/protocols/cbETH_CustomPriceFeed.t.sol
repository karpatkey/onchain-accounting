// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {cbETH_CustomPriceFeed} from "src/prices/protocols/cbETH_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title cbETH_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (ETH/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(cbEth, nav, baseAsset)`. Price math is exercised in the fork test against the live cbETH rate.
contract cbETH_CustomPriceFeedTest is Test {
    Mock_ERC20 cbEth;
    Mock_ERC20 weth;
    Mock_NAVCalculator nav;

    function setUp() public {
        cbEth = new Mock_ERC20("cbETH", 18);
        weth = new Mock_ERC20("WETH", 18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(weth), 3000e8, 8); // ETH/USD = $3000
    }

    function test_constructor_valid() public {
        cbETH_CustomPriceFeed oracle = new cbETH_CustomPriceFeed(address(cbEth), address(nav), address(weth));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(cbEth));
    }

    function test_invalidConstructorArgs() public {
        // zero underlying
        vm.expectRevert();
        new cbETH_CustomPriceFeed(address(0), address(nav), address(weth));

        // zero nav (not a contract)
        vm.expectRevert();
        new cbETH_CustomPriceFeed(address(cbEth), address(0), address(weth));

        // zero base asset
        vm.expectRevert();
        new cbETH_CustomPriceFeed(address(cbEth), address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new cbETH_CustomPriceFeed(address(cbEth), address(nav), address(nav));
    }
}
