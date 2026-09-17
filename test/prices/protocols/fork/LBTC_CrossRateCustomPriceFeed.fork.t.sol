// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {CrossRateCustomPriceFeed} from "src/prices/protocols/CrossRateCustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface ILbtcRate {
    function getRate() external view returns (uint256);
}

/// @title LBTC market cross-rate — fork tests for the divergence MONITOR
/// @notice LBTC/USD = (LBTC/BTC Chainlink rate) x (WBTC/USD from the NAV). This is LBTC's **monitor**, not its
///         primary: LBTC is yield-bearing, so the primary reads Lombard's on-chain rate
///         ({LBTC_CustomPriceFeed}) and this market leg exists to diverge against it.
/// @dev Deployed by the GENERIC `_deployCrossRateMonitor("LBTCCrossRateMarket")` path in 03, so the contract
///      under test is the generic {CrossRateCustomPriceFeed} — what is LBTC-specific, and therefore what this
///      suite pins, is the wiring: which feed, which base, and that the product lands where an independent
///      BTC-scale check expects.
contract LBTC_CrossRateCustomPriceFeedForkTest is TestEnvConfigurator {
    CrossRateCustomPriceFeed oracle;

    address constant LBTC = 0x8236a87084f8B84306f72007F36F2618A5634494;
    address constant LBTC_BTC_FEED = 0x5c29868C58b6e15e2b962943278969Ab6a7D3212;
    address constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    uint256 constant RATE_HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 25_992_700;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        // See the sibling LBTC primary suite: without this the feed is exercised against the FROZEN deployed
        // NAV bytecode rather than the in-tree build, so an in-tree base-price change breaks it silently.
        _useNewNavImpl(NAV);

        oracle = new CrossRateCustomPriceFeed(LBTC, LBTC_BTC_FEED, RATE_HEARTBEAT, NAV, WBTC);
    }

    /// @dev In-EVM ground truth: rate x base8, scaled by the rate feed's own decimals.
    function test_getLatestPrice() public view {
        (, int256 rate,,,) = IAggregatorV3(LBTC_BTC_FEED).latestRoundData();
        uint256 rateDecimals = IAggregatorV3(LBTC_BTC_FEED).decimals();
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(WBTC);
        uint256 expected = (uint256(rate) * uint256(pd.price)) / (10 ** rateDecimals);

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == (LBTC/BTC) * NAV(WBTC/USD) / 10**rateDecimals");
        assertEq(stale, false);
    }

    /// @notice The identity the config's base-asset choice rests on: WBTC/USD IS BTC/USD, so no WBTC-specific
    ///         risk enters the LBTC price.
    /// @dev Asserted as a band rather than equality because the two are read through different paths. LBTC is
    ///         1:1 BTC-backed, so its USD price must sit within a few percent of WBTC's; anything else means the
    ///         wrong base or the wrong rate feed was wired.
    function test_priceTracksBtcScale() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(WBTC);
        (uint256 price,) = oracle.getLatestPrice();

        assertGe(price, (uint256(pd.price) * 95) / 100, "LBTC >= 0.95x BTC");
        assertLe(price, (uint256(pd.price) * 105) / 100, "LBTC <= 1.05x BTC");
    }

    /// @notice The rate feed is the pair the RateFeedGuard config block pins, checked here against the chain.
    /// @dev Guards against the config being edited to another BTC-shaped feed later: `description()` is the only
    ///      check that catches within-class confusion.
    function test_rateFeedIsTheRightPair() public view {
        assertEq(IAggregatorV3(LBTC_BTC_FEED).description(), "LBTC / BTC", "rate feed pair");
        assertEq(IAggregatorV3(LBTC_BTC_FEED).decimals(), 8, "rate feed decimals");
    }

    /// @notice Why this MARKET leg is the monitor rather than the primary.
    /// @dev The primary reads the token's own `getRate()`, which does not observe market price at all, so a
    ///      market discount on LBTC cannot move it. (It CAN fall for protocol reasons — measured, 3 decreases in
    ///      20 intervals over 60 days — so "cannot fall" would be wrong; what it cannot do is fall BECAUSE the
    ///      wrapper is trading below par.) This leg observes exactly that, which is why it is paired against the
    ///      primary rather than replacing it. The two are close but NOT
    ///      equal — over 90 days the spread was min 0.01 / median 5.07 / max 19.63 bps, market below fundamental
    ///      in 35 of 46 samples — and 100 bps is the configured tolerance. Pinned at 100 bps here rather than at
    ///      the observed max, so ordinary drift does not redden the suite.
    function test_marketRateTracksTheFundamentalRate() public view {
        (, int256 marketRate,,,) = IAggregatorV3(LBTC_BTC_FEED).latestRoundData();
        uint256 market1e18 = uint256(marketRate) * 1e10; // 8 -> 18 decimals
        uint256 fundamental1e18 = ILbtcRate(LBTC).getRate();

        uint256 diff = market1e18 > fundamental1e18 ? market1e18 - fundamental1e18 : fundamental1e18 - market1e18;
        assertLe(diff * 10_000 / fundamental1e18, 100, "market vs fundamental within 100 bps");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), LBTC, "Underlying asset should be LBTC");
    }
}
