// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {wstETH_L2_CustomPriceFeed} from "src/prices/protocols/wstETH_L2_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_PriceOracleChainlink} from "test/mocks/price_oracles.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title wstETH_L2_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (ETH/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(wstEth, wstEthToEthFeed, heartbeat, nav, baseAsset)`. Price math is exercised in the fork test.
contract wstETH_L2_CustomPriceFeedTest is Test {
    Mock_ERC20 wstEth;
    Mock_PriceOracleChainlink wstEthToEth;
    Mock_ERC20 weth;
    Mock_NAVCalculator nav;
    uint256 constant HEARTBEAT = 86_400;

    function setUp() public {
        wstEth = new Mock_ERC20("wstETH", 18);
        wstEthToEth = new Mock_PriceOracleChainlink("wstETH/ETH", 1.18e18, 18);
        weth = new Mock_ERC20("WETH", 18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(weth), 3000e8, 8); // ETH/USD = $3000
    }

    function test_constructor_valid() public {
        wstETH_L2_CustomPriceFeed oracle = new wstETH_L2_CustomPriceFeed(
            address(wstEth), address(wstEthToEth), HEARTBEAT, address(nav), address(weth)
        );
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(wstEth));
    }

    function test_invalidConstructorArgs() public {
        // zero underlying
        vm.expectRevert();
        new wstETH_L2_CustomPriceFeed(address(0), address(wstEthToEth), HEARTBEAT, address(nav), address(weth));

        // zero rate feed
        vm.expectRevert();
        new wstETH_L2_CustomPriceFeed(address(wstEth), address(0), HEARTBEAT, address(nav), address(weth));

        // rate feed not a Chainlink aggregator
        vm.expectRevert();
        new wstETH_L2_CustomPriceFeed(address(wstEth), address(wstEth), HEARTBEAT, address(nav), address(weth));

        // zero rate heartbeat
        vm.expectRevert();
        new wstETH_L2_CustomPriceFeed(address(wstEth), address(wstEthToEth), 0, address(nav), address(weth));

        // zero nav (not a contract)
        vm.expectRevert();
        new wstETH_L2_CustomPriceFeed(address(wstEth), address(wstEthToEth), HEARTBEAT, address(0), address(weth));

        // zero base asset
        vm.expectRevert();
        new wstETH_L2_CustomPriceFeed(address(wstEth), address(wstEthToEth), HEARTBEAT, address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new wstETH_L2_CustomPriceFeed(address(wstEth), address(wstEthToEth), HEARTBEAT, address(nav), address(nav));
    }
}
