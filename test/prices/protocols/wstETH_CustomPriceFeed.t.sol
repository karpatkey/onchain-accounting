// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {wstETH_CustomPriceFeed} from "src/prices/protocols/wstETH_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_PriceOracleChainlink} from "test/mocks/price_oracles.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title wstETH_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (ETH/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(wstEth, stEthToEthFeed, stEthToEthHeartbeat, nav, baseAsset)`. A fully-valid construction succeeds and
///      each constructor guard is exercised individually. Price math is covered by the fork test.
contract wstETH_CustomPriceFeedTest is Test {
    Mock_ERC20 wstEth;
    Mock_PriceOracleChainlink stEthEthFeed; // stETH/ETH, 18 decimals
    Mock_ERC20 weth; // base asset priced by the NAV
    Mock_NAVCalculator nav;

    uint256 constant STETH_ETH_HB = 86_400;

    function setUp() public {
        wstEth = new Mock_ERC20("wstETH", 18);
        stEthEthFeed = new Mock_PriceOracleChainlink("STETH/ETH", 0.999e18, 18);
        weth = new Mock_ERC20("WETH", 18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(weth), 3000e8, 8); // ETH/USD = $3000
    }

    function test_constructor_valid() public {
        wstETH_CustomPriceFeed oracle = new wstETH_CustomPriceFeed(
            address(wstEth), address(stEthEthFeed), STETH_ETH_HB, address(nav), address(weth)
        );
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(wstEth));
        assertEq(address(oracle.STETH_TO_ETH_CHAINLINK_ORACLE()), address(stEthEthFeed));
        assertEq(address(oracle.NAV()), address(nav));
        assertEq(oracle.BASE_ASSET(), address(weth));
    }

    function test_constructor_revertsOnZeroWstEth() public {
        vm.expectRevert();
        new wstETH_CustomPriceFeed(address(0), address(stEthEthFeed), STETH_ETH_HB, address(nav), address(weth));
    }

    function test_constructor_revertsOnZeroStEthEthFeed() public {
        vm.expectRevert();
        new wstETH_CustomPriceFeed(address(wstEth), address(0), STETH_ETH_HB, address(nav), address(weth));
    }

    function test_constructor_revertsOnNonChainlinkFeed() public {
        // wstEth (an ERC20) is not a Chainlink aggregator → assertChainlinkOracle probe fails.
        vm.expectRevert();
        new wstETH_CustomPriceFeed(address(wstEth), address(wstEth), STETH_ETH_HB, address(nav), address(weth));
    }

    function test_constructor_revertsOnZeroStEthEthHeartbeat() public {
        vm.expectRevert();
        new wstETH_CustomPriceFeed(address(wstEth), address(stEthEthFeed), 0, address(nav), address(weth));
    }

    function test_constructor_revertsOnZeroNav() public {
        vm.expectRevert();
        new wstETH_CustomPriceFeed(address(wstEth), address(stEthEthFeed), STETH_ETH_HB, address(0), address(weth));
    }

    function test_constructor_revertsOnZeroBaseAsset() public {
        vm.expectRevert();
        new wstETH_CustomPriceFeed(address(wstEth), address(stEthEthFeed), STETH_ETH_HB, address(nav), address(0));
    }

    function test_constructor_revertsOnNonErc20BaseAsset() public {
        // nav has no totalSupply → assertERC20Address probe fails.
        vm.expectRevert();
        new wstETH_CustomPriceFeed(address(wstEth), address(stEthEthFeed), STETH_ETH_HB, address(nav), address(nav));
    }
}
