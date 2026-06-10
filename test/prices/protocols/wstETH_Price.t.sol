// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {wstETH_PriceOracle} from "src/prices/protocols/wstETH_Price.sol";

/// @title wstETH_PriceOracle unit tests (no fork)
contract wstETH_PriceOracleTest is Test {
    address wstEthAddress;
    address stEthToEthChainlink;
    address ethToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        wstEthAddress = address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
        stEthToEthChainlink = address(0x86392dC19c0b719886221c78AB11eb8Cf5c52812);
        ethToUsdChainlink = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        heartbeat = 3600;
    }

    function test_invalidConstructorArgs() public {
        // zero wstETH
        vm.expectRevert();
        new wstETH_PriceOracle(address(0), stEthToEthChainlink, ethToUsdChainlink, heartbeat, heartbeat);

        // zero stETH/ETH feed
        vm.expectRevert();
        new wstETH_PriceOracle(wstEthAddress, address(0), ethToUsdChainlink, heartbeat, heartbeat);

        // zero ETH/USD feed
        vm.expectRevert();
        new wstETH_PriceOracle(wstEthAddress, stEthToEthChainlink, address(0), heartbeat, heartbeat);

        // zero stETH/ETH heartbeat
        vm.expectRevert();
        new wstETH_PriceOracle(wstEthAddress, stEthToEthChainlink, ethToUsdChainlink, 0, heartbeat);

        // zero ETH/USD heartbeat
        vm.expectRevert();
        new wstETH_PriceOracle(wstEthAddress, stEthToEthChainlink, ethToUsdChainlink, heartbeat, 0);
    }
}
