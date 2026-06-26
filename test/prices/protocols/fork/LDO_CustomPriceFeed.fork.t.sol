// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {LDO_CustomPriceFeed} from "src/prices/protocols/LDO_CustomPriceFeed.sol";

contract LDO_CustomPriceFeedTest is TestEnvConfigurator {
    LDO_CustomPriceFeed ldoPriceOracle;
    address _ldoToken;
    address _ldoToEthOracle;
    address _ethToUsdOracle;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(22_575_288);

        _ldoToken = address(0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32);
        _ldoToEthOracle = address(0x4e844125952D32AcdF339BE976c98E22F6F318dB);
        _ethToUsdOracle = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

        ldoPriceOracle = new LDO_CustomPriceFeed(_ldoToken, _ldoToEthOracle, _ethToUsdOracle, 86_400, 3600);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = ldoPriceOracle.getLatestPrice();
        assertEq(price, 91_378_889);
        assertEq(stale, false, "Price should not be stale");
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + 3601);
        (uint256 price, bool stale) = ldoPriceOracle.getLatestPrice();
        assertEq(price, 0);
        assertEq(stale, true, "Price should be stale");
    }

    function test_decimals() public view {
        assertEq(ldoPriceOracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(ldoPriceOracle.underlyingAssetSupported(), _ldoToken, "Underlying asset should match LDO token");
    }
}
