// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {rsETH_L2_PriceOracle} from "src/prices/protocols/rsETH_L2_Price.sol";

/// @title rsETH_L2_PriceOracle unit tests (no fork)
contract rsETH_L2_PriceOracleTest is Test {
    address rsEthAddress;
    address rsEthToEthChainlink;
    address ethToUsdChainlink;
    uint256 rsEthToEthHeartbeat;
    uint256 ethToUsdHeartbeat;

    function setUp() public {
        rsEthAddress = address(0x4186BFC76E2E237523CBC30FD220FE055156b41F);
        rsEthToEthChainlink = address(0x3A917e6B5732dFCc4A45257e3930979fAE6a3737);
        ethToUsdChainlink = address(0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612);
        rsEthToEthHeartbeat = 86_400;
        ethToUsdHeartbeat = 86_400;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new rsETH_L2_PriceOracle(address(0), rsEthToEthChainlink, ethToUsdChainlink, rsEthToEthHeartbeat, ethToUsdHeartbeat);

        vm.expectRevert();
        new rsETH_L2_PriceOracle(rsEthAddress, address(0), ethToUsdChainlink, rsEthToEthHeartbeat, ethToUsdHeartbeat);

        vm.expectRevert();
        new rsETH_L2_PriceOracle(rsEthAddress, rsEthToEthChainlink, address(0), rsEthToEthHeartbeat, ethToUsdHeartbeat);

        vm.expectRevert();
        new rsETH_L2_PriceOracle(rsEthAddress, rsEthToEthChainlink, ethToUsdChainlink, 0, ethToUsdHeartbeat);

        vm.expectRevert();
        new rsETH_L2_PriceOracle(rsEthAddress, rsEthToEthChainlink, ethToUsdChainlink, rsEthToEthHeartbeat, 0);
    }
}
