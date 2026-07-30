// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {lsETH_CustomPriceFeed} from "src/prices/protocols/lsETH_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";
import {RateFeedGuard} from "script/utils/RateFeedGuard.sol";
import {NAV_DECIMALS} from "src/constants.sol";

/// @notice Fork test for `lsETH_CustomPriceFeed` — Liquid Collective lsETH's **sole primary** feed on mainnet:
///         lsETH/USD = (lsETH/ETH exchange rate) x (ETH/USD from the NAV).
/// @dev **Why this file exists, and what it deliberately does NOT assert.** The instance had zero coverage — no unit
///      test, no fork test, no appearance in `test/integration/`. The parent {CrossRateCustomPriceFeed} /
///      {TwoFeedChainlinkPriceFeed} compose-and-staleness arithmetic is already tested, so **the arithmetic is the one
///      thing that does not need testing again here.** This file therefore does not recompute
///      `rate * base8 / 10**rateDecimals` and compare it to the contract's own output: that shape asserts the
///      arithmetic and never the sanity, passes against any feed address whatsoever, and would convert "untested"
///      into "falsely reassuring".
///
///      What was uncovered — and is what has actually been changing, three rate-feed addresses hand-swapped in a
///      single week during the 2026-07-22 / 07-27 RedStone sunsets — is this instance's **feed address, decimals and
///      pair**. So that is what is asserted, and the expected values are resolved from the deploy config
///      (`contracts-deployment-config/custom-price-feeds/1.json`) rather than from constants in this file. That
///      direction matters: hardcoding the address and then asserting `description()` against it only proves the
///      constant is self-consistent. Reading the address from the same config the deploy script reads means a config
///      swap propagates into this test and fails it.
///
///      Pair identity + rate plausibility are delegated to {RateFeedGuard}, which is also what gates the deploy — one
///      source of truth for "which pair should this address be", declared in config next to the address.
///
///      **Stakes.** lsETH is priced by this contract alone and has neither a `monitorFeed` nor a `pegToleranceBps`,
///      so `_hasDivergenceChecks` is false and lsETH can never appear in `nav.irregularPriceAssets` under any chain
///      state. A wrong price here is caught by nothing, anywhere — which is why the pair assertion is the point.
contract lsETH_CustomPriceFeedForkTest is TestEnvConfigurator {
    lsETH_CustomPriceFeed oracle;

    /// @dev Chain + config key under which this instance's constructor args and rate-feed guard live.
    uint256 constant CHAIN_ID = 1;
    string constant FEED_NAME = "lsETH";

    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    uint256 constant FORK_BLOCK = 25_491_000;

    /// @notice Absolute USD sanity band on the NAV's ETH/USD leg, in `NAV_DECIMALS` (8).
    /// @dev This is the one claim {RateFeedGuard} cannot make. The guard bands the **rate leg** (lsETH/ETH, in 1e18),
    ///      so it catches a rate feed of the wrong magnitude — but it never reads `baseAsset`, so a `baseAsset`
    ///      misconfigured to a USD-pegged token is invisible to it: the rate stays a perfectly plausible ~1.11 and
    ///      the composed price silently becomes ~$1.11 instead of ~$1,930. Bounds are deliberately wide rather than
    ///      pinned to the fork block, so bumping `FORK_BLOCK` does not require re-deriving them: ETH has not traded
    ///      below $500 since December 2020 and has never traded above $5,000. Anything outside this is a wiring
    ///      error by orders of magnitude, not a market move.
    uint256 constant MIN_BASE_USD = 500e8;
    uint256 constant MAX_BASE_USD = 10_000e8;

    // Config-resolved constructor arguments. Read once in setUp so every test asserts against the same source the
    // deploy script uses.
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

        oracle = new lsETH_CustomPriceFeed(
            configuredAsset, configuredRateFeed, configuredHeartbeat, NAV, configuredBase
        );
    }

    /// @notice The configured rate-feed address really is the lsETH/ETH pair, and its rate is plausible.
    /// @dev Delegated to the same guard that gates the deploy, so CI and the deploy check one declaration. Reverts
    ///      `RateFeedPairMismatch` if `description()` does not match config, `RateFeedOutOfBand` if the rate leaves
    ///      the configured band. Point the config at any other 18-decimal ETH-quoted feed and this fails.
    function test_configuredRateFeedIsTheDeclaredPair() public view {
        RateFeedGuard.check(vm, CHAIN_ID, FEED_NAME);
    }

    /// @notice The deployed instance pins exactly what config declares — the config→instance half of the chain that
    ///         `test_configuredRateFeedIsTheDeclaredPair` completes from config→chain.
    function test_instancePinsConfiguredWiring() public view {
        assertEq(address(oracle.RATE_FEED()), configuredRateFeed, "RATE_FEED is the configured lsETH/ETH feed");
        assertEq(oracle.UNDERLYING_ASSET(), configuredAsset, "UNDERLYING_ASSET is the configured lsETH token");
        assertEq(oracle.BASE_ASSET(), configuredBase, "BASE_ASSET is the configured base (WETH)");
        assertEq(oracle.RATE_HEARTBEAT(), configuredHeartbeat, "RATE_HEARTBEAT is the configured heartbeat");
    }

    /// @notice The feed reports `NAV_DECIMALS`, and the rate feed's own decimals cancel out of the composition.
    /// @dev The second half is the substantive one. `_rateUnit` is captured as `10**RATE_FEED.decimals()` in the
    ///      constructor, so a decimals slip does not surface as a wrong `decimals()` — it surfaces as a composed
    ///      price wrong by a power of ten. Bounding `price/base8` against the same band the guard applies to the
    ///      rate leg is what detects that, and it is not a restatement of the contract's arithmetic: it holds only
    ///      if `_rateUnit` matches the feed's actual decimals.
    function test_decimalsCancelIntoNavDecimals() public view {
        assertEq(oracle.decimals(), NAV_DECIMALS, "Feed reports NAV_DECIMALS (8)");

        uint256 base8 = _baseUsd();
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale, "lsETH price is fresh at the pinned block");
        assertGe(price, (base8 * 9) / 10, "lsETH/USD >= 0.9 x ETH/USD");
        assertLe(price, (base8 * 15) / 10, "lsETH/USD <= 1.5 x ETH/USD");
    }

    /// @notice The composed USD price is plausible in absolute terms — the axis the rate-leg guard cannot see.
    function test_composedPriceIsPlausibleInUsd() public view {
        uint256 base8 = _baseUsd();
        assertGe(base8, MIN_BASE_USD, "NAV ETH/USD above the absolute floor");
        assertLe(base8, MAX_BASE_USD, "NAV ETH/USD below the absolute ceiling");

        (uint256 price,) = oracle.getLatestPrice();
        assertGe(price, MIN_BASE_USD, "lsETH/USD above the absolute floor");
        assertLe(price, MAX_BASE_USD, "lsETH/USD below the absolute ceiling");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), configuredAsset, "Underlying asset is the configured lsETH token");
    }

    /// @notice The rate leg's own heartbeat gate fires, attributed to the rate leg alone.
    /// @dev Deliberately NOT done by warping past `RATE_HEARTBEAT`. lsETH's rate heartbeat is 86,400s while the NAV's
    ///      WETH leg is registered at 3,600s, so any warp large enough to stale the rate leg stales the base leg
    ///      first — the test would pass with the rate-leg gate deleted entirely and could not say which leg fired.
    ///      Mocking only the rate feed's `updatedAt` keeps the base leg fresh, so a `stale == true` here can only
    ///      have come from the rate gate. The two cases straddle the boundary (`>=` in `_compute`), which also pins
    ///      the comparison's strictness.
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
