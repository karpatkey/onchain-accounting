// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {InvertedChainlinkCustomPriceFeed} from "src/prices/protocols/InvertedChainlinkCustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {INavSourcedPriceFeed} from "src/prices/INavSourcedPriceFeed.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {LibraryPins} from "script/utils/LibraryPins.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title InvertedChainlinkCustomPriceFeed fork test — mainnet wARS via the `USD / ARS` feed
/// @dev Exercises the real reason this contract exists: the ARS feed KPK uses is quoted `USD / ARS`
///      (ARS per USD), the reciprocal of what {Prices} registers. NOTE it is NOT mainnet's only ARS feed —
///      a direct `ARS / USD` feed exists at `0xE41cD2DcC63EB63A9D9e62f2a3D9b49e6d0C0A1d`, ~6.4% away; see
///      the contract docstring and the config `$directFeedComment` for why `USD / ARS` is the deliberate
///      choice. An earlier version of this header asserted the "only feed" claim the PR retracts. The assertions below are
///      written against the LIVE feed at a pinned block, so they prove the inversion against real
///      oracle data rather than against a mock that could encode the same mistake twice.
contract InvertedChainlinkCustomPriceFeedForkTest is TestEnvConfigurator {
    InvertedChainlinkCustomPriceFeed feed;

    /// @dev wARS ("Peso Argentino"), 18 decimals.
    address constant WARS = 0x0DC4F92879B7670e5f4e4e6e3c801D229129D90D;
    /// @dev Chainlink `USD / ARS` proxy — `description() == "USD / ARS"`, 8 decimals.
    address constant USD_ARS_FEED = 0xBb65fa58BDb7d33e4a3D1A40a7A9BD99E746367b;
    /// @dev 90000s, matching the config entry. NOT a declared value — the pair is absent from
    ///      `chainlink_declared_heartbeats.json`. MEASURED on-chain 2026-08-15 over 13.2 days of
    ///      `AnswerUpdated` on aggregator 0xc30fB86c2559E4B757C037976e3244901c10FAf8: 30 updates,
    ///      min gap 84s, median 23928s, MAX 86436s (24.01h) — **8 gaps exceed 86400 and 0 exceed
    ///      90000**. A registered 86400 would therefore have gone stale 8 times in 13 days.
    uint256 constant HEARTBEAT = 90_000;
    uint256 constant FORK_BLOCK = 25_760_274;
    /// @dev Runtime direction band, feed decimals — mirrors the config and rateFeedGuard values.
    uint256 constant MIN_A = 100e8;
    uint256 constant MAX_A = 100000e8;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        feed = new InvertedChainlinkCustomPriceFeed(WARS, USD_ARS_FEED, HEARTBEAT, MIN_A, MAX_A);
    }

    /// @dev The feed really is quoted the wrong way round — this is the premise the contract rests on.
    ///      If Chainlink ever re-quotes it as `ARS / USD`, this assertion fails loudly and the inversion
    ///      must be reconsidered, rather than silently squaring the error.
    function test_underlyingFeedIsQuotedUsdPerArs() public view {
        assertEq(AggregatorV3Interface(USD_ARS_FEED).description(), "USD / ARS", "premise: feed is USD/ARS");
        assertEq(AggregatorV3Interface(USD_ARS_FEED).decimals(), 8, "premise: 8 decimals");
        (, int256 answer,,,) = AggregatorV3Interface(USD_ARS_FEED).latestRoundData();
        assertGt(answer, 100e8, "ARS per USD is in the hundreds-plus, confirming the direction");
    }

    /// @dev In-EVM ground truth: price == 1e8 * 10^feedDecimals / answer.
    function test_getLatestPrice_matchesInEvmGroundTruth() public view {
        (, int256 answer,,,) = AggregatorV3Interface(USD_ARS_FEED).latestRoundData();
        uint256 expected = (1e8 * 1e8) / uint256(answer);

        (uint256 price, bool stale) = feed.getLatestPrice();
        assertFalse(stale, "live feed within heartbeat at the pinned block");
        assertEq(price, expected, "price == 1e8 * 1e8 / USD_ARS answer");
    }

    /// @dev The whole point, stated as a bound rather than a constant: one wARS is worth a tiny
    ///      fraction of a dollar, NOT ~1583 dollars. A regression that dropped the inversion would
    ///      return ~158309760000 here and blow both bounds.
    function test_priceIsSubCentNotThousandsOfDollars() public view {
        (uint256 price, bool stale) = feed.getLatestPrice();
        assertFalse(stale);
        assertGt(price, 0, "must not floor to zero at ARS magnitudes");
        assertLt(price, 1e6, "well under $0.01; an un-inverted answer would be ~1.58e11");
    }

    /// @dev **THE REGRESSION THIS EXISTS FOR.** `PriceFeedLib._validateFeedNotCircular` probes `BASE_ASSET()`
    ///      by raw staticcall and FAILS CLOSED — `if (!ok || ret.length != 32) revert CustomFeedBaseUnreadable`.
    ///      An earlier draft of this feed did not implement {INavSourcedPriceFeed} at all, on the reasoning that a
    ///      `USD / X` pair has no NAV dependency. That reasoning was right and the conclusion was wrong: omitting
    ///      the function does not mean "no dependency", it means the feed CANNOT BE REGISTERED. Every other test
    ///      here passed against that draft, because none of them registered the feed on a real NAVCalculator.
    ///      So this test registers it for real.
    function test_registersOnARealNavCalculator() public {
        assertEq(feed.BASE_ASSET(), address(0), "asserts no NAV dependency, rather than failing to answer");

        vm.etch(LibraryPins.PRICE_FEED_LIB, vm.deployCode("PriceFeedLib.sol:PriceFeedLib").code);
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, vm.deployCode("NAVRegistryLib.sol:NAVRegistryLib").code);

        address admin = makeAddr("admin");
        address manager = makeAddr("manager");
        vm.startPrank(admin);
        address navImpl = address(new NAVCalculator());
        NAVCalculator nav = NAVCalculator(
            UnsafeUpgrades.deployUUPSProxy(
                navImpl, abi.encodeCall(NAVCalculator.initialize, (admin, address(0), "ETH"))
            )
        );
        nav.grantRole(MANAGER, manager);
        vm.stopPrank();

        // The call that reverted before BASE_ASSET() existed.
        vm.prank(manager);
        nav.registerAsset(WARS, address(feed), IPrices.PriceType.Custom, HEARTBEAT);

        // And the registered feed prices the asset through the NAV, inverted.
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(address(nav)).getPriceData(WARS);
        assertGt(uint256(pd.price), 0, "priced");
        assertLt(uint256(pd.price), 1e6, "sub-cent: the inversion survives registration");
    }

    function test_decimalsAndUnderlying() public view {
        assertEq(feed.decimals(), 8, "NAV_DECIMALS");
        assertEq(feed.underlyingAssetSupported(), WARS);
    }

    /// @dev `latestRoundData` must carry the underlying leg's real timestamp through, since the read
    ///      path uses it for feed selection.
    function test_latestRoundData_carriesTheLegTimestamp() public view {
        (,,, uint256 legUpdatedAt,) = AggregatorV3Interface(USD_ARS_FEED).latestRoundData();
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, legUpdatedAt, "timestamp passes through");
        assertGt(answer, 0, "fresh at the pinned block");
    }

    function test_governingFeedFreshness_isTheArsLeg() public view {
        (,,, uint256 legUpdatedAt,) = AggregatorV3Interface(USD_ARS_FEED).latestRoundData();
        (uint256 updatedAt, uint256 heartbeat) = feed.governingFeedFreshness();
        assertEq(updatedAt, legUpdatedAt);
        assertEq(heartbeat, HEARTBEAT);
    }

    /// @dev Past the heartbeat the feed must report stale rather than a frozen price.
    function test_goesStalePastHeartbeat() public {
        (,,, uint256 legUpdatedAt,) = AggregatorV3Interface(USD_ARS_FEED).latestRoundData();
        vm.warp(legUpdatedAt + HEARTBEAT);
        (uint256 price, bool stale) = feed.getLatestPrice();
        assertTrue(stale, "age == heartbeat => stale");
        assertEq(price, 0);
    }
}
