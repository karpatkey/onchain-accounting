// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {cbETH_L2_PriceOracle} from "src/prices/protocols/cbETH_L2_Price.sol";

/// @title cbETH_L2_PriceOracle unit tests (no fork)
contract cbETH_L2_PriceOracleTest is Test {
    address cbEthAddress;
    address cbEthToEthChainlink;
    address ethToUsdChainlink;
    uint256 cbEthToEthHeartbeat;
    uint256 ethToUsdHeartbeat;

    function setUp() public {
        cbEthAddress = address(0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22);
        cbEthToEthChainlink = address(0x806b4Ac04501c29769051e42783cF04dCE41440b);
        ethToUsdChainlink = address(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70);
        cbEthToEthHeartbeat = 86_400;
        ethToUsdHeartbeat = 1200;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new cbETH_L2_PriceOracle(
            address(0), cbEthToEthChainlink, ethToUsdChainlink, cbEthToEthHeartbeat, ethToUsdHeartbeat
        );

        vm.expectRevert();
        new cbETH_L2_PriceOracle(cbEthAddress, address(0), ethToUsdChainlink, cbEthToEthHeartbeat, ethToUsdHeartbeat);

        vm.expectRevert();
        new cbETH_L2_PriceOracle(cbEthAddress, cbEthToEthChainlink, address(0), cbEthToEthHeartbeat, ethToUsdHeartbeat);

        vm.expectRevert();
        new cbETH_L2_PriceOracle(cbEthAddress, cbEthToEthChainlink, ethToUsdChainlink, 0, ethToUsdHeartbeat);

        vm.expectRevert();
        new cbETH_L2_PriceOracle(cbEthAddress, cbEthToEthChainlink, ethToUsdChainlink, cbEthToEthHeartbeat, 0);
    }
}
