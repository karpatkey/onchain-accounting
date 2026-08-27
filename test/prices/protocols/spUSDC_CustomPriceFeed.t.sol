// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {spUSDC_CustomPriceFeed} from "src/prices/protocols/spUSDC_CustomPriceFeed.sol";
import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";
import {Mock_ERC20, Mock_ERC4626} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title spUSDC_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (USDC/USD) comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(spUsdc, nav, baseAsset)`. Vault-rate math is exercised once in
///      test/prices/ERC4626VaultRatePriceFeed.t.sol and against the live vault in the fork test.
contract spUSDC_CustomPriceFeedTest is Test {
    Mock_ERC4626 spUsdc;
    Mock_ERC20 usdc;
    Mock_NAVCalculator nav;

    function setUp() public {
        usdc = new Mock_ERC20("USDC", 6);
        spUsdc = new Mock_ERC4626("spUSDC", 6, address(usdc), 1e6);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(usdc), 1e8, 8); // USDC/USD = $1
    }

    function test_constructor_valid() public {
        spUSDC_CustomPriceFeed oracle = new spUSDC_CustomPriceFeed(address(spUsdc), address(nav), address(usdc));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(spUsdc));
    }

    function test_invalidConstructorArgs() public {
        // zero vault
        vm.expectRevert();
        new spUSDC_CustomPriceFeed(address(0), address(nav), address(usdc));

        // zero nav (not a contract)
        vm.expectRevert();
        new spUSDC_CustomPriceFeed(address(spUsdc), address(0), address(usdc));

        // zero base asset
        vm.expectRevert();
        new spUSDC_CustomPriceFeed(address(spUsdc), address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new spUSDC_CustomPriceFeed(address(spUsdc), address(nav), address(nav));
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
                ERC4626VaultRatePriceFeed.BaseAssetMismatch.selector, address(spUsdc.asset()), address(other)
            )
        );
        new spUSDC_CustomPriceFeed(address(spUsdc), address(nav), address(other));
    }
}
