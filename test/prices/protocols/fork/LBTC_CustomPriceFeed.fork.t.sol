// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {LBTC_CustomPriceFeed} from "src/prices/protocols/LBTC_CustomPriceFeed.sol";
import {CrossRateCustomPriceFeed} from "src/prices/protocols/CrossRateCustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface ILbtcRate {
    function getRate() external view returns (uint256);
}

/// @title LBTC primary price feed — fork tests
/// @notice LBTC/USD = LBTC.getRate() (BTC per LBTC, 18-dec) x WBTC/USD from the NAV. This is the PRIMARY, read
///         from the chain because LBTC is yield-bearing; the Chainlink market cross-rate is the monitor.
contract LBTC_CustomPriceFeedForkTest is TestEnvConfigurator {
    LBTC_CustomPriceFeed oracle;

    address constant LBTC = 0x8236a87084f8B84306f72007F36F2618A5634494;
    address constant LBTC_BTC_FEED = 0x5c29868C58b6e15e2b962943278969Ab6a7D3212;
    address constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    uint256 constant FORK_BLOCK = 25_992_700;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new LBTC_CustomPriceFeed(LBTC, NAV, WBTC);
    }

    /// @dev In-EVM ground truth: the live Lombard rate x the NAV's WBTC/USD, scaled by 1e18.
    function test_getLatestPrice() public view {
        uint256 rate = ILbtcRate(LBTC).getRate();
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(WBTC);
        uint256 expected = (rate * uint256(pd.price)) / 1e18;

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == getRate() * NAV(WBTC/USD) / 1e18");
        assertEq(stale, false);
    }

    /// @notice LBTC is BTC-backed, so its USD price must sit beside BTC's — an independent scale check that does
    ///         not mirror the implementation formula.
    function test_priceTracksBtcScale() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(WBTC);
        (uint256 price,) = oracle.getLatestPrice();

        assertGe(price, (uint256(pd.price) * 95) / 100, "LBTC >= 0.95x BTC");
        assertLe(price, (uint256(pd.price) * 105) / 100, "LBTC <= 1.05x BTC");
    }

    /// @notice LBTC is yield-bearing, so the rate must be ABOVE parity — this is the property that makes the
    ///         asset Appreciating and the reason the rate is read on-chain at all.
    /// @dev Asserted as a floor of 1.0 rather than an equality: the rate is stepwise and CAN fall (measured 3
    ///      decreases in 20 intervals over 60 days), so pinning a value would be flaky. What must hold is that
    ///      accrued yield has not vanished.
    function test_rateIsAboveParity() public view {
        assertGt(ILbtcRate(LBTC).getRate(), 1e18, "1 LBTC redeems for more than 1 BTC once yield has accrued");
    }

    /// @notice The primary and its market monitor must agree inside the configured divergence tolerance.
    /// @dev The pairing is the point: the primary does not observe market price, so a depeg cannot move it while
    ///      the monitor tracks it directly (the primary CAN still fall for protocol reasons). This pins that
    ///      the two agree TODAY within the 100 bps the config sets — measured max over 90 days was 19.63 bps.
    ///      Both read WBTC/USD from the same NAV, so the base cancels and this is a rate-vs-rate comparison.
    function test_primaryAndMarketMonitorAgreeWithinTolerance() public {
        CrossRateCustomPriceFeed monitor = new CrossRateCustomPriceFeed(LBTC, LBTC_BTC_FEED, 86_400, NAV, WBTC);

        (uint256 primary,) = oracle.getLatestPrice();
        (uint256 market,) = monitor.getLatestPrice();

        uint256 diff = primary > market ? primary - market : market - primary;
        assertLe((diff * 10_000) / primary, 100, "primary vs market monitor within divergenceToleranceBps 100");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), LBTC, "Underlying asset should be LBTC");
    }
}
