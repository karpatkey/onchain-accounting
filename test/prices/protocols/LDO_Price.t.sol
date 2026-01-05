// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {LDO_PriceOracle} from "src/prices/protocols/LDO_Price.sol";

contract LDO_PriceOracleTest is TestEnvConfigurator {
    LDO_PriceOracle LDO_priceOracle;
    address _ldoToken;
    address _ldoToEthOracle;
    address _ethToUsdOracle;

    function setUp() public {
        uint256 fork = vm.createFork(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(22_575_288);

        _ldoToken = address(0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32);
        _ldoToEthOracle = address(0x4e844125952D32AcdF339BE976c98E22F6F318dB);
        _ethToUsdOracle = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

        LDO_priceOracle = new LDO_PriceOracle(_ldoToken, _ldoToEthOracle, _ethToUsdOracle, 86_400, 3600);
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

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = LDO_priceOracle.getLatestPrice();
        assertEq(price, 91_378_889);
        assertEq(stale, false, "Price should not be stale");
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + 3601);
        (uint256 price, bool stale) = LDO_priceOracle.getLatestPrice();
        assertEq(price, 91_378_889);
        assertEq(stale, true, "Price should be stale");
    }

    function test_decimals() public view {
        assertEq(LDO_priceOracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(LDO_priceOracle.underlyingAssetSupported(), _ldoToken, "Underlying asset should match LDO token");
    }
}
