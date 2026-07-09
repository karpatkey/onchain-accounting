// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {syrupUSDC_CustomPriceFeed} from "src/prices/protocols/syrupUSDC_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title syrupUSDC_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (USDC/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(syrupUsdc, nav, baseAsset)`. Vault-rate math is exercised in the fork test.
contract syrupUSDC_CustomPriceFeedTest is Test {
    Mock_ERC20 syrupUsdc;
    Mock_ERC20 usdc;
    Mock_NAVCalculator nav;

    function setUp() public {
        syrupUsdc = new Mock_ERC20("syrupUSDC", 6);
        usdc = new Mock_ERC20("USDC", 6);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(usdc), 1e8, 8); // USDC/USD = $1
    }

    function test_constructor_valid() public {
        syrupUSDC_CustomPriceFeed oracle =
            new syrupUSDC_CustomPriceFeed(address(syrupUsdc), address(nav), address(usdc));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(syrupUsdc));
    }

    function test_invalidConstructorArgs() public {
        // zero vault
        vm.expectRevert();
        new syrupUSDC_CustomPriceFeed(address(0), address(nav), address(usdc));

        // zero nav (not a contract)
        vm.expectRevert();
        new syrupUSDC_CustomPriceFeed(address(syrupUsdc), address(0), address(usdc));

        // zero base asset
        vm.expectRevert();
        new syrupUSDC_CustomPriceFeed(address(syrupUsdc), address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new syrupUSDC_CustomPriceFeed(address(syrupUsdc), address(nav), address(nav));
    }
}
