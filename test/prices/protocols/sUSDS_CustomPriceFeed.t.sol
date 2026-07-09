// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {sUSDS_CustomPriceFeed} from "src/prices/protocols/sUSDS_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title sUSDS_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (USDS/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(sUsds, nav, baseAsset)`. Vault-rate math is exercised in the fork test.
contract sUSDS_CustomPriceFeedTest is Test {
    Mock_ERC20 sUsds;
    Mock_ERC20 usds;
    Mock_NAVCalculator nav;

    function setUp() public {
        sUsds = new Mock_ERC20("sUSDS", 18);
        usds = new Mock_ERC20("USDS", 18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(usds), 1e8, 8); // USDS/USD = $1
    }

    function test_constructor_valid() public {
        sUSDS_CustomPriceFeed oracle = new sUSDS_CustomPriceFeed(address(sUsds), address(nav), address(usds));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(sUsds));
    }

    function test_invalidConstructorArgs() public {
        // zero vault
        vm.expectRevert();
        new sUSDS_CustomPriceFeed(address(0), address(nav), address(usds));

        // zero nav (not a contract)
        vm.expectRevert();
        new sUSDS_CustomPriceFeed(address(sUsds), address(0), address(usds));

        // zero base asset
        vm.expectRevert();
        new sUSDS_CustomPriceFeed(address(sUsds), address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new sUSDS_CustomPriceFeed(address(sUsds), address(nav), address(nav));
    }
}
