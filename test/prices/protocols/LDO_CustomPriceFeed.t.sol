// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LDO_CustomPriceFeed} from "src/prices/protocols/LDO_CustomPriceFeed.sol";

/// @title LDO_CustomPriceFeed unit tests (no fork)
contract LDO_CustomPriceFeedTest is Test {
    address _ldoToken;
    address _ldoToEthOracle;
    address _ethToUsdOracle;

    function setUp() public {
        _ldoToken = address(0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32);
        _ldoToEthOracle = address(0x4e844125952D32AcdF339BE976c98E22F6F318dB);
        _ethToUsdOracle = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new LDO_CustomPriceFeed(address(0), _ldoToEthOracle, _ethToUsdOracle, 86_400, 3600);

        vm.expectRevert();
        new LDO_CustomPriceFeed(_ldoToken, address(0), _ethToUsdOracle, 86_400, 3600);

        vm.expectRevert();
        new LDO_CustomPriceFeed(_ldoToken, _ldoToEthOracle, address(0), 86_400, 3600);

        vm.expectRevert();
        new LDO_CustomPriceFeed(_ldoToken, _ldoToEthOracle, _ethToUsdOracle, 0, 3600);

        vm.expectRevert();
        new LDO_CustomPriceFeed(_ldoToken, _ldoToEthOracle, _ethToUsdOracle, 86_400, 0);

        vm.expectRevert();
        new LDO_CustomPriceFeed(_ldoToken, _ldoToken, _ethToUsdOracle, 86_400, 3600);

        vm.expectRevert();
        new LDO_CustomPriceFeed(_ldoToken, _ldoToEthOracle, _ldoToken, 86_400, 3600);
    }
}
