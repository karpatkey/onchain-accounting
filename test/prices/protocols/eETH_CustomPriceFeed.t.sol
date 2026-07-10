// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {eETH_CustomPriceFeed} from "src/prices/protocols/eETH_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_PriceOracleChainlink} from "test/mocks/price_oracles.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title eETH_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (ETH/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(eEth, weEth, weEthToEthFeed, heartbeat, nav, baseAsset)`. Price math is exercised in the fork test.
contract eETH_CustomPriceFeedTest is Test {
    Mock_ERC20 eEth;
    Mock_ERC20 weEth;
    Mock_PriceOracleChainlink weEthToEth;
    Mock_ERC20 weth; // base asset priced by the NAV
    Mock_NAVCalculator nav;
    uint256 constant HEARTBEAT = 86_400;

    function setUp() public {
        eEth = new Mock_ERC20("eETH", 18);
        weEth = new Mock_ERC20("weETH", 18);
        weEthToEth = new Mock_PriceOracleChainlink("weETH/ETH", 1.06e18, 18);
        weth = new Mock_ERC20("WETH", 18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(weth), 3000e8, 8); // ETH/USD = $3000
    }

    function test_constructor_valid() public {
        eETH_CustomPriceFeed oracle = new eETH_CustomPriceFeed(
            address(eEth), address(weEth), address(weEthToEth), HEARTBEAT, address(nav), address(weth)
        );
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(eEth));
    }

    function test_invalidConstructorArgs() public {
        // zero eETH
        vm.expectRevert();
        new eETH_CustomPriceFeed(
            address(0), address(weEth), address(weEthToEth), HEARTBEAT, address(nav), address(weth)
        );

        // zero weETH
        vm.expectRevert();
        new eETH_CustomPriceFeed(address(eEth), address(0), address(weEthToEth), HEARTBEAT, address(nav), address(weth));

        // zero weETH/ETH feed
        vm.expectRevert();
        new eETH_CustomPriceFeed(address(eEth), address(weEth), address(0), HEARTBEAT, address(nav), address(weth));

        // weETH/ETH feed not a Chainlink aggregator
        vm.expectRevert();
        new eETH_CustomPriceFeed(address(eEth), address(weEth), address(weEth), HEARTBEAT, address(nav), address(weth));

        // zero heartbeat
        vm.expectRevert();
        new eETH_CustomPriceFeed(address(eEth), address(weEth), address(weEthToEth), 0, address(nav), address(weth));

        // zero nav (not a contract)
        vm.expectRevert();
        new eETH_CustomPriceFeed(
            address(eEth), address(weEth), address(weEthToEth), HEARTBEAT, address(0), address(weth)
        );

        // zero base asset
        vm.expectRevert();
        new eETH_CustomPriceFeed(
            address(eEth), address(weEth), address(weEthToEth), HEARTBEAT, address(nav), address(0)
        );

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new eETH_CustomPriceFeed(
            address(eEth), address(weEth), address(weEthToEth), HEARTBEAT, address(nav), address(nav)
        );
    }
}
