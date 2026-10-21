// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {NXM_CustomPriceFeed} from "src/prices/protocols/NXM_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @notice Minimal Nexus Mutual RAMM mock exposing a settable internal ETH-per-NXM price.
contract Mock_Ramm {
    uint256 public price;

    constructor(uint256 price_) {
        price = price_;
    }

    function getInternalPrice() external view returns (uint256) {
        return price;
    }
}

/// @title NXM_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (ETH/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(nxm, ramm, nav, baseAsset)` and fails fast if the RAMM's internal price is 0. Arithmetic is exercised
///      in the fork test against real Nexus state.
contract NXM_CustomPriceFeedTest is Test {
    Mock_ERC20 nxm;
    Mock_ERC20 weth;
    Mock_NAVCalculator nav;
    Mock_Ramm ramm;

    function setUp() public {
        nxm = new Mock_ERC20("NXM", 18);
        weth = new Mock_ERC20("WETH", 18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(weth), 3000e8, 8); // ETH/USD = $3000
        ramm = new Mock_Ramm(0.03e18); // ~0.03 ETH per NXM
    }

    function test_constructor_valid() public {
        NXM_CustomPriceFeed oracle = new NXM_CustomPriceFeed(address(nxm), address(ramm), address(nav), address(weth));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(nxm));
    }

    function test_invalidConstructorArgs() public {
        // zero NXM
        vm.expectRevert();
        new NXM_CustomPriceFeed(address(0), address(ramm), address(nav), address(weth));

        // zero RAMM
        vm.expectRevert();
        new NXM_CustomPriceFeed(address(nxm), address(0), address(nav), address(weth));

        // RAMM not a live Nexus RAMM (getInternalPrice reverts)
        vm.expectRevert();
        new NXM_CustomPriceFeed(address(nxm), address(nav), address(nav), address(weth));

        // RAMM internal price is 0
        Mock_Ramm zeroRamm = new Mock_Ramm(0);
        vm.expectRevert();
        new NXM_CustomPriceFeed(address(nxm), address(zeroRamm), address(nav), address(weth));

        // zero nav (not a contract)
        vm.expectRevert();
        new NXM_CustomPriceFeed(address(nxm), address(ramm), address(0), address(weth));

        // zero base asset
        vm.expectRevert();
        new NXM_CustomPriceFeed(address(nxm), address(ramm), address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new NXM_CustomPriceFeed(address(nxm), address(ramm), address(nav), address(nav));
    }

    /// @dev price = internalPrice (ETH/NXM, 18) * NAV(ETH/USD, 8) / 1e18. 0.03 * $3000 = $90.
    function test_getLatestPrice() public {
        NXM_CustomPriceFeed oracle = new NXM_CustomPriceFeed(address(nxm), address(ramm), address(nav), address(weth));
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale, "not stale");
        assertEq(price, 90e8, "0.03 ETH/NXM * $3000 = $90 at 8 decimals");
    }

    /// @dev NAV-sourced base staleness is the primary staleness source: base stale -> feed stale, still priced off the
    ///      last base price (ADR 0029).
    function test_stale_whenBaseStale() public {
        NXM_CustomPriceFeed oracle = new NXM_CustomPriceFeed(address(nxm), address(ramm), address(nav), address(weth));
        nav.setAssetStale(address(weth), true);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale, "stale when base stale");
        assertEq(price, 90e8, "priced off the last base price when the base is stale");
    }
}
