// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {cbETH_L2_CustomPriceFeed} from "src/prices/protocols/cbETH_L2_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_PriceOracleChainlink} from "test/mocks/price_oracles.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title cbETH_L2_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (ETH/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(cbEth, cbEthToEthFeed, heartbeat, nav, baseAsset)`. Price math is exercised in the fork test.
contract cbETH_L2_CustomPriceFeedTest is Test {
    Mock_ERC20 cbEth;
    Mock_PriceOracleChainlink cbEthToEth;
    Mock_ERC20 weth;
    Mock_NAVCalculator nav;
    uint256 constant HEARTBEAT = 86_400;

    function setUp() public {
        cbEth = new Mock_ERC20("cbETH", 18);
        cbEthToEth = new Mock_PriceOracleChainlink("cbETH/ETH", 1.05e18, 18);
        weth = new Mock_ERC20("WETH", 18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(weth), 3000e8, 8); // ETH/USD = $3000
    }

    function test_constructor_valid() public {
        cbETH_L2_CustomPriceFeed oracle =
            new cbETH_L2_CustomPriceFeed(address(cbEth), address(cbEthToEth), HEARTBEAT, address(nav), address(weth));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(cbEth));
    }

    function test_invalidConstructorArgs() public {
        // zero underlying
        vm.expectRevert();
        new cbETH_L2_CustomPriceFeed(address(0), address(cbEthToEth), HEARTBEAT, address(nav), address(weth));

        // zero rate feed
        vm.expectRevert();
        new cbETH_L2_CustomPriceFeed(address(cbEth), address(0), HEARTBEAT, address(nav), address(weth));

        // rate feed not a Chainlink aggregator
        vm.expectRevert();
        new cbETH_L2_CustomPriceFeed(address(cbEth), address(cbEth), HEARTBEAT, address(nav), address(weth));

        // zero rate heartbeat
        vm.expectRevert();
        new cbETH_L2_CustomPriceFeed(address(cbEth), address(cbEthToEth), 0, address(nav), address(weth));

        // zero nav (not a contract)
        vm.expectRevert();
        new cbETH_L2_CustomPriceFeed(address(cbEth), address(cbEthToEth), HEARTBEAT, address(0), address(weth));

        // zero base asset
        vm.expectRevert();
        new cbETH_L2_CustomPriceFeed(address(cbEth), address(cbEthToEth), HEARTBEAT, address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new cbETH_L2_CustomPriceFeed(address(cbEth), address(cbEthToEth), HEARTBEAT, address(nav), address(nav));
    }
}
