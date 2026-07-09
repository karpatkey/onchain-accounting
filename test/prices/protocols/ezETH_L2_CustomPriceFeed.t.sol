// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ezETH_L2_CustomPriceFeed} from "src/prices/protocols/ezETH_L2_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title ezETH_L2_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (ETH/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(ezEth, xRenzoDeposit, nav, baseAsset)`. Arithmetic is exercised in the fork test.
contract ezETH_L2_CustomPriceFeedTest is Test {
    Mock_ERC20 ezEth;
    Mock_ERC20 weth;
    Mock_NAVCalculator nav;
    address xRenzoDeposit;

    function setUp() public {
        ezEth = new Mock_ERC20("ezETH", 18);
        weth = new Mock_ERC20("WETH", 18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(weth), 3000e8, 8); // ETH/USD = $3000
        xRenzoDeposit = address(nav); // only checked non-zero at construction
    }

    function test_constructor_valid() public {
        ezETH_L2_CustomPriceFeed oracle =
            new ezETH_L2_CustomPriceFeed(address(ezEth), xRenzoDeposit, address(nav), address(weth));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(ezEth));
    }

    function test_invalidConstructorArgs() public {
        // zero ezETH
        vm.expectRevert();
        new ezETH_L2_CustomPriceFeed(address(0), xRenzoDeposit, address(nav), address(weth));

        // zero xRenzoDeposit
        vm.expectRevert();
        new ezETH_L2_CustomPriceFeed(address(ezEth), address(0), address(nav), address(weth));

        // zero nav (not a contract)
        vm.expectRevert();
        new ezETH_L2_CustomPriceFeed(address(ezEth), xRenzoDeposit, address(0), address(weth));

        // zero base asset
        vm.expectRevert();
        new ezETH_L2_CustomPriceFeed(address(ezEth), xRenzoDeposit, address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new ezETH_L2_CustomPriceFeed(address(ezEth), xRenzoDeposit, address(nav), address(nav));
    }
}
