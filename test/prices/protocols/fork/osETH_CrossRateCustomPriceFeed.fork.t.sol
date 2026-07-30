// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {osETH_CrossRateCustomPriceFeed} from "src/prices/protocols/osETH_CrossRateCustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";
import {RateFeedGuard} from "script/utils/RateFeedGuard.sol";
import {NAV_DECIMALS} from "src/constants.sol";

/// @notice Fork test for `osETH_CrossRateCustomPriceFeed` — osETH's **sole `monitorFeed`** on mainnet:
///         osETH/USD = (osETH/ETH market rate) x (ETH/USD from the NAV). Never prices the NAV; it exists only so
///         `_divergenceFor` has a second source to compare the StakeWise `osTokenVaultController` primary against.
/// @dev **Why this file exists, and what it deliberately does NOT assert.** The instance had zero coverage. The
///      parent {CrossRateCustomPriceFeed} / {TwoFeedChainlinkPriceFeed} compose-and-staleness arithmetic is already
///      tested, so the arithmetic is the one thing that does not need testing again here. This file therefore does
///      not recompute `rate * base8 / 10**rateDecimals` from the same `latestRoundData()` the contract reads and
///      compare it to the contract's output — that shape asserts the arithmetic, never the sanity, and passes
///      against any feed address whatsoever.
///
///      What was uncovered is this instance's **feed address, decimals and pair**. Expected values are resolved from
///      the deploy config (`contracts-deployment-config/custom-price-feeds/1.json`), not from constants in this file,
///      so a config change propagates here and fails. That matters for this instance in particular because its rate
///      leg is a RedStone Classic-Push feed, and RedStone sunset two of its siblings' feeds in a single week
///      (ezETH's on 2026-07-22, ETHx's on 2026-07-27) — this is the remaining Classic-Push rate leg of the three,
///      so it is the one most likely to need the next hand-swap.
///
///      This file also does not assert anything about how well the monitor tracks the primary. That relationship is
///      `_monitorDivergence`'s business and is governed by osETH's configured `divergenceToleranceBps`; asserting a
///      particular spread here would pin a market condition rather than the contract.
contract osETH_CrossRateCustomPriceFeedForkTest is TestEnvConfigurator {
    osETH_CrossRateCustomPriceFeed oracle;

    /// @dev Chain + config key under which this instance's constructor args and rate-feed guard live.
    uint256 constant CHAIN_ID = 1;
    string constant FEED_NAME = "osETHCrossRate";

    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    uint256 constant FORK_BLOCK = 25_491_000;

    /// @notice Absolute USD sanity band on the NAV's ETH/USD leg, in `NAV_DECIMALS` (8).
    /// @dev The one claim {RateFeedGuard} cannot make. The guard bands the **rate leg** (osETH/ETH, normalised to
    ///      1e18), so it catches a rate feed of the wrong magnitude — but it never reads `baseAsset`, so a
    ///      `baseAsset` misconfigured to a USD-pegged token is invisible to it: the rate stays a plausible ~1.07 and
    ///      the composed price silently becomes ~$1.07 instead of ~$1,850. Bounds are deliberately wide rather than
    ///      pinned to the fork block, so bumping `FORK_BLOCK` does not require re-deriving them: ETH has not traded
    ///      below $500 since December 2020 and has never traded above $5,000.
    uint256 constant MIN_BASE_USD = 500e8;
    uint256 constant MAX_BASE_USD = 10_000e8;

    // Config-resolved constructor arguments, read once so every test asserts against the source the deploy uses.
    address configuredAsset;
    address configuredRateFeed;
    address configuredBase;
    uint256 configuredHeartbeat;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        _useNewNavImpl(NAV);

        configuredAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, CHAIN_ID, FEED_NAME, "underlyingAsset"));
        configuredRateFeed = RateFeedGuard.configuredRateFeed(vm, CHAIN_ID, FEED_NAME);
        configuredBase = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, CHAIN_ID, FEED_NAME, "baseAsset"));
        configuredHeartbeat = vm.parseUint(ConfigReader.readPriceFeedParam(vm, CHAIN_ID, FEED_NAME, "yToXHeartbeat"));

        oracle = new osETH_CrossRateCustomPriceFeed(
            configuredAsset, configuredRateFeed, configuredHeartbeat, NAV, configuredBase
        );
    }

    /// @notice The configured rate-feed address really is the declared osETH/ETH pair, and its rate is plausible.
    /// @dev Delegated to the same guard that gates the deploy, so CI and the deploy check one declaration. Reverts
    ///      `RateFeedPairMismatch` if `description()` does not match config, `RateFeedOutOfBand` if the rate leaves
    ///      the configured band.
    function test_configuredRateFeedIsTheDeclaredPair() public view {
        RateFeedGuard.check(vm, CHAIN_ID, FEED_NAME);
    }

    /// @notice The deployed instance pins exactly what config declares — the config→instance half of the chain that
    ///         `test_configuredRateFeedIsTheDeclaredPair` completes from config→chain.
    function test_instancePinsConfiguredWiring() public view {
        assertEq(address(oracle.RATE_FEED()), configuredRateFeed, "RATE_FEED is the configured osETH/ETH feed");
        assertEq(oracle.UNDERLYING_ASSET(), configuredAsset, "UNDERLYING_ASSET is the configured osETH token");
        assertEq(oracle.BASE_ASSET(), configuredBase, "BASE_ASSET is the configured base (WETH)");
        assertEq(oracle.RATE_HEARTBEAT(), configuredHeartbeat, "RATE_HEARTBEAT is the configured heartbeat");
    }

    /// @notice The feed reports `NAV_DECIMALS`, and the rate feed's own decimals cancel out of the composition.
    /// @dev The first assertion is load-bearing for this instance's ROLE, not decoration: `addMonitorFeed` reverts
    ///      `MonitorFeedDecimalsMismatch` unless a monitor reports `NAV_DECIMALS`, so a feed that failed it could
    ///      never be registered as osETH's monitor at all.
    ///
    ///      The second is the substantive half. This rate leg is 8-decimal where ETHx's is 18 — `_rateUnit` is
    ///      captured as `10**RATE_FEED.decimals()` in the constructor, so a decimals slip does not surface as a
    ///      wrong `decimals()`; it surfaces as a composed price wrong by a power of ten. Bounding `price/base8`
    ///      against the same band the guard applies to the rate leg detects that, and is not a restatement of the
    ///      contract's arithmetic: it holds only if `_rateUnit` matches the feed's actual decimals.
    function test_decimalsCancelIntoNavDecimals() public view {
        assertEq(oracle.decimals(), NAV_DECIMALS, "Monitor reports NAV_DECIMALS (8) as registration requires");

        uint256 base8 = _baseUsd();
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale, "osETH monitor price is fresh at the pinned block");
        assertGe(price, (base8 * 9) / 10, "osETH/USD >= 0.9 x ETH/USD");
        assertLe(price, (base8 * 15) / 10, "osETH/USD <= 1.5 x ETH/USD");
    }

    /// @notice The composed USD price is plausible in absolute terms — the axis the rate-leg guard cannot see.
    function test_composedPriceIsPlausibleInUsd() public view {
        uint256 base8 = _baseUsd();
        assertGe(base8, MIN_BASE_USD, "NAV ETH/USD above the absolute floor");
        assertLe(base8, MAX_BASE_USD, "NAV ETH/USD below the absolute ceiling");

        (uint256 price,) = oracle.getLatestPrice();
        assertGe(price, MIN_BASE_USD, "osETH/USD above the absolute floor");
        assertLe(price, MAX_BASE_USD, "osETH/USD below the absolute ceiling");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), configuredAsset, "Underlying asset is the configured osETH token");
    }

    /// @notice The rate leg's own heartbeat gate fires, attributed to the rate leg alone.
    /// @dev Deliberately NOT done by warping past `RATE_HEARTBEAT`. This rate heartbeat is 86,400s while the NAV's
    ///      WETH leg is registered at 3,600s, so any warp large enough to stale the rate leg stales the base leg
    ///      first — the test would pass with the rate-leg gate deleted entirely and could not say which leg fired.
    ///      Mocking only the rate feed's `updatedAt` keeps the base leg fresh, so `stale == true` here can only have
    ///      come from the rate gate. The two cases straddle the boundary (`>=` in `_compute`).
    function test_staleRateLegAloneMarksPriceStale() public {
        _mockRateUpdatedAt(block.timestamp - configuredHeartbeat);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0, "Stale rate leg returns 0");
        assertTrue(stale, "Rate leg exactly at its heartbeat is stale (>= comparison)");
    }

    /// @notice Control for the above: one second inside the heartbeat is fresh, with the base leg untouched.
    function test_freshRateLegJustInsideHeartbeat() public {
        _mockRateUpdatedAt(block.timestamp - configuredHeartbeat + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale, "One second inside the heartbeat is fresh");
        assertGt(price, 0, "Fresh rate leg prices");
    }

    /// @dev The NAV's own base/USD price, which the feed composes against.
    function _baseUsd() private view returns (uint256) {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(configuredBase);
        return uint256(pd.price);
    }

    /// @dev Replays the live round with only `updatedAt` moved, so the rate VALUE stays plausible and the staleness
    ///      verdict is attributable to the timestamp rather than to a rejected answer.
    function _mockRateUpdatedAt(uint256 updatedAt) private {
        (uint80 roundId, int256 answer, uint256 startedAt,, uint80 answeredInRound) =
            oracle.RATE_FEED().latestRoundData();
        vm.mockCall(
            configuredRateFeed,
            abi.encodeWithSelector(oracle.RATE_FEED().latestRoundData.selector),
            abi.encode(roundId, answer, startedAt, updatedAt, answeredInRound)
        );
    }
}
