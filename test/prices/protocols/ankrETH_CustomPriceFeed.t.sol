// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ankrETH_CustomPriceFeed} from "src/prices/protocols/ankrETH_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title ankrETH_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (ETH/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(ankrEth, nav, baseAsset)`. Price math (ratio()) is exercised in the fork test.
contract ankrETH_CustomPriceFeedTest is Test {
    Mock_ERC20 ankrEth;
    Mock_ERC20 weth;
    Mock_NAVCalculator nav;

    function setUp() public {
        ankrEth = new Mock_ERC20("ankrETH", 18);
        weth = new Mock_ERC20("WETH", 18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(weth), 3000e8, 8); // ETH/USD = $3000
    }

    function test_constructor_valid() public {
        ankrETH_CustomPriceFeed oracle = new ankrETH_CustomPriceFeed(address(ankrEth), address(nav), address(weth));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(ankrEth));
    }

    function test_invalidConstructorArgs() public {
        // zero underlying
        vm.expectRevert();
        new ankrETH_CustomPriceFeed(address(0), address(nav), address(weth));

        // zero nav (not a contract)
        vm.expectRevert();
        new ankrETH_CustomPriceFeed(address(ankrEth), address(0), address(weth));

        // zero base asset
        vm.expectRevert();
        new ankrETH_CustomPriceFeed(address(ankrEth), address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new ankrETH_CustomPriceFeed(address(ankrEth), address(nav), address(nav));
    }

    // --- ADR 0029: a stale base carries its price, flagged stale ---

    /// @dev ratio() = 0.8 ankrETH per ETH -> 1.25 ETH per ankrETH -> $3750 at $3000/ETH.
    function _mockRatio(uint256 ratio) internal {
        vm.mockCall(address(ankrEth), abi.encodeWithSignature("ratio()"), abi.encode(ratio));
    }

    function test_getLatestPrice_fresh() public {
        _mockRatio(0.8e18);
        ankrETH_CustomPriceFeed oracle = new ankrETH_CustomPriceFeed(address(ankrEth), address(nav), address(weth));
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale);
        assertEq(price, 3750e8);
    }

    function test_getLatestPrice_staleBaseKeepsPrice() public {
        _mockRatio(0.8e18);
        ankrETH_CustomPriceFeed oracle = new ankrETH_CustomPriceFeed(address(ankrEth), address(nav), address(weth));
        nav.setAssetStale(address(weth), true);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale, "stale base => stale");
        assertEq(price, 3750e8, "priced off the last base price");
    }

    function test_getLatestPrice_structuralZeros() public {
        _mockRatio(0);
        ankrETH_CustomPriceFeed oracle = new ankrETH_CustomPriceFeed(address(ankrEth), address(nav), address(weth));
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale);
        assertEq(price, 0, "zero ratio => 0");

        _mockRatio(0.8e18);
        nav.setAssetPrice(address(weth), 0, 8, true);
        (price, stale) = oracle.getLatestPrice();
        assertTrue(stale);
        assertEq(price, 0, "no base price => 0");
    }
}
