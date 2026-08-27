// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {sDAI_CustomPriceFeed} from "src/prices/protocols/sDAI_CustomPriceFeed.sol";
import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";
import {Mock_ERC20, Mock_ERC4626} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title sDAI_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (DAI/USD) comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(sDai, nav, baseAsset)`. Vault-rate math is exercised once in
///      test/prices/ERC4626VaultRatePriceFeed.t.sol and against the live vault in the fork test.
contract sDAI_CustomPriceFeedTest is Test {
    Mock_ERC4626 sDai;
    Mock_ERC20 dai;
    Mock_NAVCalculator nav;

    function setUp() public {
        dai = new Mock_ERC20("DAI", 18);
        sDai = new Mock_ERC4626("sDAI", 18, address(dai), 1e18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(dai), 1e8, 8); // DAI/USD = $1
    }

    function test_constructor_valid() public {
        sDAI_CustomPriceFeed oracle = new sDAI_CustomPriceFeed(address(sDai), address(nav), address(dai));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(sDai));
    }

    function test_invalidConstructorArgs() public {
        // zero vault
        vm.expectRevert();
        new sDAI_CustomPriceFeed(address(0), address(nav), address(dai));

        // zero nav (not a contract)
        vm.expectRevert();
        new sDAI_CustomPriceFeed(address(sDai), address(0), address(dai));

        // zero base asset
        vm.expectRevert();
        new sDAI_CustomPriceFeed(address(sDai), address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new sDAI_CustomPriceFeed(address(sDai), address(nav), address(nav));
    }

    /// @dev The base reverts when the declared base asset is not the vault's own underlying. Worth pinning
    ///      per-feed: it is the guard that would catch a copy-paste of the wrong `baseAsset` into config.
    function test_revertsOnBaseAssetMismatch() public {
        Mock_ERC20 other = new Mock_ERC20("OTHER", 18);
        // Assert the SPECIFIC guard, with its arguments. A bare expectRevert() would also pass if the
        // constructor reverted for an unrelated reason, which is the failure mode that makes a guard test
        // worthless. Custom errors carrying arguments need encodeWithSelector, not the bare selector.
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626VaultRatePriceFeed.BaseAssetMismatch.selector, address(sDai.asset()), address(other)
            )
        );
        new sDAI_CustomPriceFeed(address(sDai), address(nav), address(other));
    }
}
