// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {sDAI_CustomPriceFeed} from "src/prices/protocols/sDAI_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface IDsrManagerPot {
    function pot() external view returns (address);
}

interface IPotChi {
    function chi() external view returns (uint256);
}

contract sDAI_CustomPriceFeedTest is TestEnvConfigurator {
    sDAI_CustomPriceFeed sDaiPriceOracle;

    address constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
    address constant DSR_MANAGER = 0x373238337Bfe1146fb49989fc222523f83081dDb;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        sDaiPriceOracle = new sDAI_CustomPriceFeed(SDAI, DSR_MANAGER, NAV, DAI);
    }

    /// @dev In-EVM ground truth: NAV base/USD (DAI/USD, 8 dec) * DSR pot chi (RAY, 27 dec) / 1e27.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(DAI);
        uint256 base8 = uint256(pd.price);
        uint256 chi = IPotChi(IDsrManagerPot(DSR_MANAGER).pot()).chi();
        uint256 expected = (base8 * chi) / 1e27;

        (uint256 price, bool stale) = sDaiPriceOracle.getLatestPrice();
        assertEq(price, expected, "price == NAV(DAI/USD) * pot.chi() / 1e27");
        assertEq(stale, false);
    }

    function test_decimals() public view {
        assertEq(sDaiPriceOracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(sDaiPriceOracle.underlyingAssetSupported(), SDAI, "Underlying asset should match sDAI token");
    }
}
