// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {syrupUSDT_CustomPriceFeed} from "src/prices/protocols/syrupUSDT_CustomPriceFeed.sol";
import {Mock_ERC20, Mock_ERC4626} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title syrupUSDT_CustomPriceFeed unit tests (no fork)
/// @dev Third Maple feed, same shape as the syrupUSDC and syrupUSDG suites. What is pinned here is the
///      constructor surface plus the base-asset pairing — the one thing that can go wrong by copy-paste from
///      either sibling, since all three take `(vault, nav, baseAsset)` and differ only in two addresses.
contract syrupUSDT_CustomPriceFeedTest is Test {
    Mock_ERC4626 syrupUsdt;
    Mock_ERC20 usdt;
    Mock_ERC20 usdc;
    Mock_NAVCalculator nav;

    function setUp() public {
        usdt = new Mock_ERC20("USDT", 6);
        usdc = new Mock_ERC20("USDC", 6);
        syrupUsdt = new Mock_ERC4626("syrupUSDT", 6, address(usdt), 1e6);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(usdt), 1e8, 8); // USDT/USD = $1
        nav.setAssetPrice(address(usdc), 1e8, 8);
    }

    function test_constructor_valid() public {
        syrupUSDT_CustomPriceFeed oracle =
            new syrupUSDT_CustomPriceFeed(address(syrupUsdt), address(nav), address(usdt));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(syrupUsdt));
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new syrupUSDT_CustomPriceFeed(address(0), address(nav), address(usdt));

        vm.expectRevert();
        new syrupUSDT_CustomPriceFeed(address(syrupUsdt), address(0), address(usdt));

        vm.expectRevert();
        new syrupUSDT_CustomPriceFeed(address(syrupUsdt), address(nav), address(0));
    }

    /// @notice The copy-paste this feed is most exposed to: its two siblings name USDC and USDG as their base,
    ///         and every Maple vault here is 6-dp, so a wrong base is NOT caught by decimals.
    /// @dev The failure it prevents is silent and permanent — a syrupUSDT feed built against USDC would price
    ///      every share at USDC/USD and look entirely healthy: right decimals, plausible magnitude, not stale.
    ///      Only `BaseAssetMismatch` distinguishes them, so it is asserted rather than trusted.
    function test_baseAssetMustBeTheVaultsOwnAsset() public {
        vm.expectRevert();
        new syrupUSDT_CustomPriceFeed(address(syrupUsdt), address(nav), address(usdc));
    }

    /// @notice Price tracks the vault rate, not just the base price.
    /// @dev `Mock_ERC4626` fixes its rate at construction, so the two rates are two vaults. At a fixed $1 base,
    ///      1.5 assets-per-share must report exactly 1.5x par — what a decimals mis-scale would break.
    function test_priceTracksTheVaultRate() public {
        syrupUSDT_CustomPriceFeed atPar = new syrupUSDT_CustomPriceFeed(address(syrupUsdt), address(nav), address(usdt));
        Mock_ERC4626 appreciatedVault = new Mock_ERC4626("syrupUSDT", 6, address(usdt), 15e5);
        syrupUSDT_CustomPriceFeed appreciated =
            new syrupUSDT_CustomPriceFeed(address(appreciatedVault), address(nav), address(usdt));

        (uint256 parPrice,) = atPar.getLatestPrice();
        (uint256 upPrice,) = appreciated.getLatestPrice();

        assertEq(parPrice, 1e8, "1.0 assets/share at $1 base == $1.00");
        assertEq(upPrice, 15e7, "1.5 assets/share at $1 base == $1.50");
    }
}
