// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {sXDAI_CustomPriceFeed} from "src/prices/protocols/sXDAI_CustomPriceFeed.sol";
import {Mock_ERC20, Mock_ERC4626} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title sXDAI_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (xDAI/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(sDai, nav, baseAsset)`. Vault-rate math is exercised in the fork test.
contract sXDAI_CustomPriceFeedTest is Test {
    Mock_ERC4626 savingsXDai;
    Mock_ERC20 xdai;
    Mock_NAVCalculator nav;

    function setUp() public {
        xdai = new Mock_ERC20("WXDAI", 18);
        savingsXDai = new Mock_ERC4626("sDAI", 18, address(xdai), 1e18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(xdai), 1e8, 8); // xDAI/USD = $1
    }

    function test_constructor_valid() public {
        sXDAI_CustomPriceFeed oracle = new sXDAI_CustomPriceFeed(address(savingsXDai), address(nav), address(xdai));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(savingsXDai));
    }

    function test_invalidConstructorArgs() public {
        // zero vault
        vm.expectRevert();
        new sXDAI_CustomPriceFeed(address(0), address(nav), address(xdai));

        // zero nav (not a contract)
        vm.expectRevert();
        new sXDAI_CustomPriceFeed(address(savingsXDai), address(0), address(xdai));

        // zero base asset
        vm.expectRevert();
        new sXDAI_CustomPriceFeed(address(savingsXDai), address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new sXDAI_CustomPriceFeed(address(savingsXDai), address(nav), address(nav));
    }
}
