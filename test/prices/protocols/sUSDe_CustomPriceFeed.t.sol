// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {sUSDe_CustomPriceFeed} from "src/prices/protocols/sUSDe_CustomPriceFeed.sol";
import {Mock_ERC20, Mock_ERC4626} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title sUSDe_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (USDe/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(sUsde, nav, baseAsset)`. Vault-rate math is exercised in the fork test.
contract sUSDe_CustomPriceFeedTest is Test {
    Mock_ERC4626 sUsde;
    Mock_ERC20 usde;
    Mock_NAVCalculator nav;

    function setUp() public {
        usde = new Mock_ERC20("USDe", 18);
        sUsde = new Mock_ERC4626("sUSDe", 18, address(usde), 1e18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(usde), 1e8, 8); // USDe/USD = $1
    }

    function test_constructor_valid() public {
        sUSDe_CustomPriceFeed oracle = new sUSDe_CustomPriceFeed(address(sUsde), address(nav), address(usde));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(sUsde));
    }

    function test_invalidConstructorArgs() public {
        // zero vault
        vm.expectRevert();
        new sUSDe_CustomPriceFeed(address(0), address(nav), address(usde));

        // zero nav (not a contract)
        vm.expectRevert();
        new sUSDe_CustomPriceFeed(address(sUsde), address(0), address(usde));

        // zero base asset
        vm.expectRevert();
        new sUSDe_CustomPriceFeed(address(sUsde), address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new sUSDe_CustomPriceFeed(address(sUsde), address(nav), address(nav));
    }
}
