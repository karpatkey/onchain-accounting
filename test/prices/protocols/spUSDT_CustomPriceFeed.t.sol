// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {spUSDT_CustomPriceFeed} from "src/prices/protocols/spUSDT_CustomPriceFeed.sol";
import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";
import {Mock_ERC20, Mock_ERC4626} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title spUSDT_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (USDT/USD) comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(spUsdt, nav, baseAsset)`. Vault-rate math is exercised once in
///      test/prices/ERC4626VaultRatePriceFeed.t.sol and against the live vault in the fork test.
contract spUSDT_CustomPriceFeedTest is Test {
    Mock_ERC4626 spUsdt;
    Mock_ERC20 usdt;
    Mock_NAVCalculator nav;

    function setUp() public {
        usdt = new Mock_ERC20("USDT", 6);
        spUsdt = new Mock_ERC4626("spUSDT", 6, address(usdt), 1e6);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(usdt), 1e8, 8); // USDT/USD = $1
    }

    function test_constructor_valid() public {
        spUSDT_CustomPriceFeed oracle = new spUSDT_CustomPriceFeed(address(spUsdt), address(nav), address(usdt));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(spUsdt));
    }

    function test_invalidConstructorArgs() public {
        // zero vault
        vm.expectRevert();
        new spUSDT_CustomPriceFeed(address(0), address(nav), address(usdt));

        // zero nav (not a contract)
        vm.expectRevert();
        new spUSDT_CustomPriceFeed(address(spUsdt), address(0), address(usdt));

        // zero base asset
        vm.expectRevert();
        new spUSDT_CustomPriceFeed(address(spUsdt), address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new spUSDT_CustomPriceFeed(address(spUsdt), address(nav), address(nav));
    }

    /// @dev The base reverts when the declared base asset is not the vault's own underlying. Worth pinning
    ///      per-feed: it is the guard that would catch a copy-paste of the wrong `baseAsset` into config.
    function test_revertsOnBaseAssetMismatch() public {
        Mock_ERC20 other = new Mock_ERC20("OTHER", 6);
        // Assert the SPECIFIC guard, with its arguments. A bare expectRevert() would also pass if the
        // constructor reverted for an unrelated reason, which is the failure mode that makes a guard test
        // worthless. Custom errors carrying arguments need encodeWithSelector, not the bare selector.
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626VaultRatePriceFeed.BaseAssetMismatch.selector, address(spUsdt.asset()), address(other)
            )
        );
        new spUSDT_CustomPriceFeed(address(spUsdt), address(nav), address(other));
    }
}
