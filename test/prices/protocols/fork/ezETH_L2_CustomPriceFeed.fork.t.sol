// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ezETH_L2_CustomPriceFeed} from "src/prices/protocols/ezETH_L2_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface IXRenzoDepositRate {
    function getRate() external view returns (uint256);
}

contract ezETH_L2_CustomPriceFeedForkTest_Arbitrum is TestEnvConfigurator {
    ezETH_L2_CustomPriceFeed oracle;

    address constant EZETH = 0x2416092f143378750bb29b79eD961ab195CcEea5;
    address constant X_RENZO_DEPOSIT = 0x2EfA125B4fcD5B082a4233BA55b53FeB2Fb4Ff33;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // Arbitrum WETH
    uint256 constant FORK_BLOCK = 481_880_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("arb-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new ezETH_L2_CustomPriceFeed(EZETH, X_RENZO_DEPOSIT, NAV, WETH);
    }

    /// @dev In-EVM ground truth: xRenzoDeposit.getRate() (18 dec) * NAV base/USD (8 dec) / 1e18.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(WETH);
        uint256 base8 = uint256(pd.price);
        uint256 rate = IXRenzoDepositRate(X_RENZO_DEPOSIT).getRate();
        uint256 expected = (rate * base8) / 1e18;

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == getRate() * NAV(ETH/USD) / 1e18");
        assertEq(stale, false);
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), EZETH, "Underlying asset should match ezETH token");
    }
}
