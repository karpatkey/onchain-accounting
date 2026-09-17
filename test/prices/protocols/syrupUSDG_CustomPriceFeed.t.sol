// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {syrupUSDG_CustomPriceFeed} from "src/prices/protocols/syrupUSDG_CustomPriceFeed.sol";
import {Mock_ERC20, Mock_ERC4626} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title syrupUSDG_CustomPriceFeed unit tests (no fork)
/// @dev Sibling of the syrupUSDC suite: base/USD (USDG/USD) comes from the NAV via a Mock_NAVCalculator and the
///      constructor takes `(syrupUsdg, nav, baseAsset)`. Vault-rate math against the real pool is exercised in the
///      fork test; what is pinned here is the constructor surface plus the base-asset pairing, which is the one
///      thing that can go wrong by copy-paste from the syrupUSDC config.
contract syrupUSDG_CustomPriceFeedTest is Test {
    Mock_ERC4626 syrupUsdg;
    Mock_ERC20 usdg;
    Mock_ERC20 usdc;
    Mock_NAVCalculator nav;

    function setUp() public {
        usdg = new Mock_ERC20("USDG", 6);
        usdc = new Mock_ERC20("USDC", 6);
        syrupUsdg = new Mock_ERC4626("syrupUSDG", 6, address(usdg), 1e6);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(usdg), 1e8, 8); // USDG/USD = $1
        nav.setAssetPrice(address(usdc), 1e8, 8);
    }

    function test_constructor_valid() public {
        syrupUSDG_CustomPriceFeed oracle =
            new syrupUSDG_CustomPriceFeed(address(syrupUsdg), address(nav), address(usdg));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(syrupUsdg));
    }

    function test_invalidConstructorArgs() public {
        // zero vault
        vm.expectRevert();
        new syrupUSDG_CustomPriceFeed(address(0), address(nav), address(usdg));

        // zero nav (not a contract)
        vm.expectRevert();
        new syrupUSDG_CustomPriceFeed(address(syrupUsdg), address(0), address(usdg));

        // zero base asset
        vm.expectRevert();
        new syrupUSDG_CustomPriceFeed(address(syrupUsdg), address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new syrupUSDG_CustomPriceFeed(address(syrupUsdg), address(nav), address(nav));
    }

    /// @notice The copy-paste this feed is most exposed to: the syrupUSDC config block names USDC as its base, and
    ///         this vault's asset is USDG. The base's `BaseAssetMismatch` must reject that at CONSTRUCTION.
    /// @dev Worth its own test rather than trusting the base, because the failure it prevents is silent and
    ///      permanent: a syrupUSDG feed built against USDC would price every share at USDC/USD and look entirely
    ///      healthy — right decimals, plausible magnitude, `stale == false` — while tracking the wrong asset.
    function test_baseAssetMustBeTheVaultsOwnAsset() public {
        vm.expectRevert();
        new syrupUSDG_CustomPriceFeed(address(syrupUsdg), address(nav), address(usdc));
    }

    /// @notice Price scales with the vault rate, not just with the base price.
    /// @dev `Mock_ERC4626` fixes its rate at construction, so the two rates are two vaults rather than one mutated
    ///      one. At a fixed $1 base, 1.5 assets-per-share must report exactly 1.5x the par price — which is what
    ///      distinguishes this feed from a plain base passthrough, and what a decimals mis-scale would break.
    function test_priceTracksTheVaultRate() public {
        syrupUSDG_CustomPriceFeed atPar = new syrupUSDG_CustomPriceFeed(address(syrupUsdg), address(nav), address(usdg));
        Mock_ERC4626 appreciatedVault = new Mock_ERC4626("syrupUSDG", 6, address(usdg), 15e5);
        syrupUSDG_CustomPriceFeed appreciated =
            new syrupUSDG_CustomPriceFeed(address(appreciatedVault), address(nav), address(usdg));

        (uint256 parPrice,) = atPar.getLatestPrice();
        (uint256 upPrice,) = appreciated.getLatestPrice();

        assertEq(parPrice, 1e8, "1.0 assets/share at $1 base == $1.00");
        assertEq(upPrice, 15e7, "1.5 assets/share at $1 base == $1.50");
    }
}
