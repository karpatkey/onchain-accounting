// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LDO_CustomPriceFeed} from "src/prices/protocols/LDO_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_PriceOracleChainlink} from "test/mocks/price_oracles.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title LDO_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (ETH/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(ldo, ldoToEthFeed, heartbeat, nav, baseAsset)`. Price math is exercised in the fork test.
contract LDO_CustomPriceFeedTest is Test {
    Mock_ERC20 ldo;
    Mock_PriceOracleChainlink ldoToEth;
    Mock_ERC20 weth;
    Mock_NAVCalculator nav;
    uint256 constant HEARTBEAT = 86_400;

    function setUp() public {
        ldo = new Mock_ERC20("LDO", 18);
        ldoToEth = new Mock_PriceOracleChainlink("LDO/ETH", 0.0005e18, 18);
        weth = new Mock_ERC20("WETH", 18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(weth), 3000e8, 8); // ETH/USD = $3000
    }

    function test_constructor_valid() public {
        LDO_CustomPriceFeed oracle =
            new LDO_CustomPriceFeed(address(ldo), address(ldoToEth), HEARTBEAT, address(nav), address(weth));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(ldo));
    }

    function test_invalidConstructorArgs() public {
        // zero underlying
        vm.expectRevert();
        new LDO_CustomPriceFeed(address(0), address(ldoToEth), HEARTBEAT, address(nav), address(weth));

        // zero rate feed
        vm.expectRevert();
        new LDO_CustomPriceFeed(address(ldo), address(0), HEARTBEAT, address(nav), address(weth));

        // rate feed not a Chainlink aggregator
        vm.expectRevert();
        new LDO_CustomPriceFeed(address(ldo), address(ldo), HEARTBEAT, address(nav), address(weth));

        // zero rate heartbeat
        vm.expectRevert();
        new LDO_CustomPriceFeed(address(ldo), address(ldoToEth), 0, address(nav), address(weth));

        // zero nav (not a contract)
        vm.expectRevert();
        new LDO_CustomPriceFeed(address(ldo), address(ldoToEth), HEARTBEAT, address(0), address(weth));

        // zero base asset
        vm.expectRevert();
        new LDO_CustomPriceFeed(address(ldo), address(ldoToEth), HEARTBEAT, address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new LDO_CustomPriceFeed(address(ldo), address(ldoToEth), HEARTBEAT, address(nav), address(nav));
    }
}
