// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {wstETH_CustomPriceFeed} from "src/prices/protocols/wstETH_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_PriceOracleChainlink} from "test/mocks/price_oracles.sol";

/// @title wstETH_CustomPriceFeed unit tests (no fork)
/// @dev Uses mock ERC20 + mock Chainlink aggregators so a fully-valid construction succeeds and each
///      constructor guard is exercised individually (the other args stay valid), rather than every call
///      reverting at the first probe on a codeless mainnet address. Price math is covered by the fork test.
contract wstETH_CustomPriceFeedTest is Test {
    Mock_ERC20 wstEth;
    Mock_PriceOracleChainlink stEthEthFeed; // stETH/ETH, 18 decimals
    Mock_PriceOracleChainlink ethUsdFeed; // ETH/USD, 8 decimals

    uint256 constant STETH_ETH_HB = 86_400;
    uint256 constant ETH_USD_HB = 3600;

    function setUp() public {
        wstEth = new Mock_ERC20("wstETH", 18);
        stEthEthFeed = new Mock_PriceOracleChainlink("STETH/ETH", 0.999e18, 18);
        ethUsdFeed = new Mock_PriceOracleChainlink("ETH/USD", 3000e8, 8);
    }

    function test_constructor_valid() public {
        wstETH_CustomPriceFeed oracle = new wstETH_CustomPriceFeed(
            address(wstEth), address(stEthEthFeed), address(ethUsdFeed), STETH_ETH_HB, ETH_USD_HB
        );
        assertEq(oracle.decimals(), 8, "decimals pinned from ETH/USD feed");
        assertEq(oracle.underlyingAssetSupported(), address(wstEth));
        assertEq(address(oracle.STETH_TO_ETH_CHAINLINK_ORACLE()), address(stEthEthFeed));
        assertEq(address(oracle.ETH_TO_USD_CHAINLINK_ORACLE()), address(ethUsdFeed));
    }

    function test_constructor_revertsOnZeroWstEth() public {
        vm.expectRevert();
        new wstETH_CustomPriceFeed(address(0), address(stEthEthFeed), address(ethUsdFeed), STETH_ETH_HB, ETH_USD_HB);
    }

    function test_constructor_revertsOnZeroStEthEthFeed() public {
        vm.expectRevert();
        new wstETH_CustomPriceFeed(address(wstEth), address(0), address(ethUsdFeed), STETH_ETH_HB, ETH_USD_HB);
    }

    function test_constructor_revertsOnZeroEthUsdFeed() public {
        vm.expectRevert();
        new wstETH_CustomPriceFeed(address(wstEth), address(stEthEthFeed), address(0), STETH_ETH_HB, ETH_USD_HB);
    }

    function test_constructor_revertsOnZeroStEthEthHeartbeat() public {
        vm.expectRevert();
        new wstETH_CustomPriceFeed(address(wstEth), address(stEthEthFeed), address(ethUsdFeed), 0, ETH_USD_HB);
    }

    function test_constructor_revertsOnZeroEthUsdHeartbeat() public {
        vm.expectRevert();
        new wstETH_CustomPriceFeed(address(wstEth), address(stEthEthFeed), address(ethUsdFeed), STETH_ETH_HB, 0);
    }

    function test_constructor_revertsOnNonChainlinkFeed() public {
        // wstEth (an ERC20) is not a Chainlink aggregator → assertChainlinkOracle probe fails.
        vm.expectRevert();
        new wstETH_CustomPriceFeed(address(wstEth), address(wstEth), address(ethUsdFeed), STETH_ETH_HB, ETH_USD_HB);
    }
}
