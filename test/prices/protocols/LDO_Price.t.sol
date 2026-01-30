// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LDO_PriceOracle} from "src/prices/protocols/LDO_Price.sol";

/// @title LDO_PriceOracle unit tests (no fork)
contract LDO_PriceOracleTest is Test {
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
        new LDO_PriceOracle(address(0), _ldoToEthOracle, _ethToUsdOracle, 86_400, 3600);

        vm.expectRevert();
        new LDO_PriceOracle(_ldoToken, address(0), _ethToUsdOracle, 86_400, 3600);

        vm.expectRevert();
        new LDO_PriceOracle(_ldoToken, _ldoToEthOracle, address(0), 86_400, 3600);

        vm.expectRevert();
        new LDO_PriceOracle(_ldoToken, _ldoToEthOracle, _ethToUsdOracle, 0, 3600);

        vm.expectRevert();
        new LDO_PriceOracle(_ldoToken, _ldoToEthOracle, _ethToUsdOracle, 86_400, 0);

        vm.expectRevert();
        new LDO_PriceOracle(_ldoToken, _ldoToken, _ethToUsdOracle, 86_400, 3600);

        vm.expectRevert();
        new LDO_PriceOracle(_ldoToken, _ldoToEthOracle, _ldoToken, 86_400, 3600);
    }
}
