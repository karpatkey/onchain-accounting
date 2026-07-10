// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {syrupUSDC_L2_CustomPriceFeed} from "src/prices/protocols/syrupUSDC_L2_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_PriceOracleChainlink} from "test/mocks/price_oracles.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title syrupUSDC_L2_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (USDC/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(syrupUsdc, syrupUsdcToUsdcFeed, heartbeat, nav, baseAsset)`. Price math is exercised in the fork test.
contract syrupUSDC_L2_CustomPriceFeedTest is Test {
    Mock_ERC20 syrupUsdc;
    Mock_PriceOracleChainlink syrupToUsdc;
    Mock_ERC20 usdc;
    Mock_NAVCalculator nav;
    uint256 constant HEARTBEAT = 86_400;

    function setUp() public {
        syrupUsdc = new Mock_ERC20("syrupUSDC", 6);
        syrupToUsdc = new Mock_PriceOracleChainlink("syrupUSDC/USDC", 1.05e8, 8);
        usdc = new Mock_ERC20("USDC", 6);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(usdc), 1e8, 8); // USDC/USD = $1
    }

    function test_constructor_valid() public {
        syrupUSDC_L2_CustomPriceFeed oracle = new syrupUSDC_L2_CustomPriceFeed(
            address(syrupUsdc), address(syrupToUsdc), HEARTBEAT, address(nav), address(usdc)
        );
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(syrupUsdc));
    }

    function test_invalidConstructorArgs() public {
        // zero underlying
        vm.expectRevert();
        new syrupUSDC_L2_CustomPriceFeed(address(0), address(syrupToUsdc), HEARTBEAT, address(nav), address(usdc));

        // zero rate feed
        vm.expectRevert();
        new syrupUSDC_L2_CustomPriceFeed(address(syrupUsdc), address(0), HEARTBEAT, address(nav), address(usdc));

        // rate feed not a Chainlink aggregator
        vm.expectRevert();
        new syrupUSDC_L2_CustomPriceFeed(address(syrupUsdc), address(syrupUsdc), HEARTBEAT, address(nav), address(usdc));

        // zero rate heartbeat
        vm.expectRevert();
        new syrupUSDC_L2_CustomPriceFeed(address(syrupUsdc), address(syrupToUsdc), 0, address(nav), address(usdc));

        // zero nav (not a contract)
        vm.expectRevert();
        new syrupUSDC_L2_CustomPriceFeed(address(syrupUsdc), address(syrupToUsdc), HEARTBEAT, address(0), address(usdc));

        // zero base asset
        vm.expectRevert();
        new syrupUSDC_L2_CustomPriceFeed(address(syrupUsdc), address(syrupToUsdc), HEARTBEAT, address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new syrupUSDC_L2_CustomPriceFeed(
            address(syrupUsdc), address(syrupToUsdc), HEARTBEAT, address(nav), address(nav)
        );
    }
}
