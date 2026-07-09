// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {sGHO_CustomPriceFeed} from "src/prices/protocols/sGHO_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title sGHO_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (GHO/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(sGho, nav, baseAsset)`. Vault-rate math is exercised in the fork test.
contract sGHO_CustomPriceFeedTest is Test {
    Mock_ERC20 sgho;
    Mock_ERC20 gho;
    Mock_NAVCalculator nav;

    function setUp() public {
        sgho = new Mock_ERC20("sGHO", 18);
        gho = new Mock_ERC20("GHO", 18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(gho), 1e8, 8); // GHO/USD = $1
    }

    function test_constructor_valid() public {
        sGHO_CustomPriceFeed oracle = new sGHO_CustomPriceFeed(address(sgho), address(nav), address(gho));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(sgho));
    }

    function test_invalidConstructorArgs() public {
        // zero vault
        vm.expectRevert();
        new sGHO_CustomPriceFeed(address(0), address(nav), address(gho));

        // zero nav (not a contract)
        vm.expectRevert();
        new sGHO_CustomPriceFeed(address(sgho), address(0), address(gho));

        // zero base asset
        vm.expectRevert();
        new sGHO_CustomPriceFeed(address(sgho), address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new sGHO_CustomPriceFeed(address(sgho), address(nav), address(nav));
    }
}
