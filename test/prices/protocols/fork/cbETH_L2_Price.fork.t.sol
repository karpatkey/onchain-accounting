// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {cbETH_L2_PriceOracle} from "src/prices/protocols/cbETH_L2_Price.sol";

contract cbETH_L2_PriceOracleForkTest_Base is TestEnvConfigurator {
    cbETH_L2_PriceOracle oracle;

    address constant CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address constant CBETH_TO_ETH_CHAINLINK = 0x806b4Ac04501c29769051e42783cF04dCE41440b;
    address constant ETH_TO_USD_CHAINLINK = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    uint256 constant CBETH_TO_ETH_HEARTBEAT = 86_400;
    uint256 constant ETH_TO_USD_HEARTBEAT = 1200;
    uint256 constant FORK_BLOCK = 41_682_714;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("base-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new cbETH_L2_PriceOracle(
            CBETH, CBETH_TO_ETH_CHAINLINK, ETH_TO_USD_CHAINLINK, CBETH_TO_ETH_HEARTBEAT, ETH_TO_USD_HEARTBEAT
        );
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = oracle.getLatestPrice();
        // 1121196008371684000 * 229023000000 / 1e18 = 256779673425
        assertEq(price, 256_779_673_425, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + ETH_TO_USD_HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), CBETH, "Underlying asset should match cbETH token");
    }
}
