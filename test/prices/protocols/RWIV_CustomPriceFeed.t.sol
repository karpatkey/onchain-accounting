// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {RWIV_CustomPriceFeed} from "src/prices/protocols/RWIV_CustomPriceFeed.sol";
import {Mock_ERC20, Mock_ERC4626} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title RWIV_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (USDC/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(rwiv, nav, baseAsset)`. Vault-rate math is exercised in the fork test.
contract RWIV_CustomPriceFeedTest is Test {
    Mock_ERC4626 rwiv;
    Mock_ERC20 usdc;
    Mock_NAVCalculator nav;

    function setUp() public {
        usdc = new Mock_ERC20("USDC", 6);
        rwiv = new Mock_ERC4626("RWIV", 6, address(usdc), 1e6);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(usdc), 1e8, 8); // USDC/USD = $1
    }

    function test_constructor_valid() public {
        RWIV_CustomPriceFeed oracle = new RWIV_CustomPriceFeed(address(rwiv), address(nav), address(usdc));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(rwiv));
    }

    function test_invalidConstructorArgs() public {
        // zero vault
        vm.expectRevert();
        new RWIV_CustomPriceFeed(address(0), address(nav), address(usdc));

        // zero nav (not a contract)
        vm.expectRevert();
        new RWIV_CustomPriceFeed(address(rwiv), address(0), address(usdc));

        // zero base asset
        vm.expectRevert();
        new RWIV_CustomPriceFeed(address(rwiv), address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new RWIV_CustomPriceFeed(address(rwiv), address(nav), address(nav));
    }
}
