// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ETHx_CustomPriceFeed} from "src/prices/protocols/ETHx_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title ETHx_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (ETH/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(ethx, stakePoolsManager, nav, baseAsset)`. Arithmetic is exercised in the fork test against real
///      Stader state. The stakePoolsManager only needs to be a contract at construction (any deployed address).
contract ETHx_CustomPriceFeedTest is Test {
    Mock_ERC20 ethx;
    Mock_ERC20 weth;
    Mock_NAVCalculator nav;
    address stakePoolsManager; // just needs code at construction time

    function setUp() public {
        ethx = new Mock_ERC20("ETHx", 18);
        weth = new Mock_ERC20("WETH", 18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(weth), 3000e8, 8); // ETH/USD = $3000
        stakePoolsManager = address(nav); // a deployed contract (code.length > 0)
    }

    function test_constructor_valid() public {
        ETHx_CustomPriceFeed oracle =
            new ETHx_CustomPriceFeed(address(ethx), stakePoolsManager, address(nav), address(weth));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(ethx));
    }

    function test_invalidConstructorArgs() public {
        // zero ETHx
        vm.expectRevert();
        new ETHx_CustomPriceFeed(address(0), stakePoolsManager, address(nav), address(weth));

        // zero stakePoolsManager
        vm.expectRevert();
        new ETHx_CustomPriceFeed(address(ethx), address(0), address(nav), address(weth));

        // stakePoolsManager not a contract
        vm.expectRevert();
        new ETHx_CustomPriceFeed(address(ethx), address(0xdead), address(nav), address(weth));

        // zero nav (not a contract)
        vm.expectRevert();
        new ETHx_CustomPriceFeed(address(ethx), stakePoolsManager, address(0), address(weth));

        // zero base asset
        vm.expectRevert();
        new ETHx_CustomPriceFeed(address(ethx), stakePoolsManager, address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new ETHx_CustomPriceFeed(address(ethx), stakePoolsManager, address(nav), address(nav));
    }
}
