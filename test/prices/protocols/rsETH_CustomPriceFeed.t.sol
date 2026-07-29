// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {rsETH_CustomPriceFeed} from "src/prices/protocols/rsETH_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title rsETH_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (ETH/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(rsEth, rateProvider, nav, baseAsset)`. Arithmetic is exercised in the fork test against real Kelp state.
contract rsETH_CustomPriceFeedTest is Test {
    Mock_ERC20 rsEth;
    Mock_ERC20 weth;
    Mock_NAVCalculator nav;
    address rateProvider;

    function setUp() public {
        rsEth = new Mock_ERC20("rsETH", 18);
        weth = new Mock_ERC20("WETH", 18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(weth), 3000e8, 8); // ETH/USD = $3000
        rateProvider = address(nav); // only checked non-zero at construction
    }

    function test_constructor_valid() public {
        rsETH_CustomPriceFeed oracle =
            new rsETH_CustomPriceFeed(address(rsEth), rateProvider, address(nav), address(weth));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(rsEth));
    }

    function test_invalidConstructorArgs() public {
        // zero rsETH
        vm.expectRevert();
        new rsETH_CustomPriceFeed(address(0), rateProvider, address(nav), address(weth));

        // zero rateProvider
        vm.expectRevert();
        new rsETH_CustomPriceFeed(address(rsEth), address(0), address(nav), address(weth));

        // zero nav (not a contract)
        vm.expectRevert();
        new rsETH_CustomPriceFeed(address(rsEth), rateProvider, address(0), address(weth));

        // zero base asset
        vm.expectRevert();
        new rsETH_CustomPriceFeed(address(rsEth), rateProvider, address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new rsETH_CustomPriceFeed(address(rsEth), rateProvider, address(nav), address(nav));
    }
}
