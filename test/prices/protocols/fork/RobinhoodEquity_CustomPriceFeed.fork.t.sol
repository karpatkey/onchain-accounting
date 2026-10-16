// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {RobinhoodEquity_CustomPriceFeed} from "src/prices/protocols/RobinhoodEquity_CustomPriceFeed.sol";
import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {LibraryPins} from "script/utils/LibraryPins.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title RobinhoodEquity_CustomPriceFeed fork test — chain 4663, SPY across a closed US tape
/// @notice Pinned at block 85,956,175, whose timestamp is 1,791,734,400 = **Sunday 2026-10-11, 12:00:00 America/
///         New_York**. That is the WEEKEND session: the US tape closed at Friday's 16:00 ET bell and does not reopen
///         until Monday 09:30 ET, so the `us_equities_24/5` aggregator is legitimately silent. This is deliberate —
///         the holdover path this contract exists for is only reachable off-hours, and a block inside the regular
///         session would exercise nothing but a passthrough.
/// @dev MEASURED at that block: the `RHSPY / USD` aggregator's last round was pushed at 1,791,570,259 = Friday
///      2026-10-09 14:24:19 ET (inside that day's regular session), so the mark is **164,141 s old — 45 h 35 m**.
///      That is 1.9x the aggregator's declared 86,400 s cadence and 38 % of the 432,000 s holdover: a raw
///      `PriceType.Chainlink` registration would already have dropped SPY, and the wrapper still prices it. The whole
///      contract is that one sentence, so the suite asserts both halves of it against the live chain.
/// @dev MEASURED at the same block: SPY's token reads `uiMultiplier() == 1001717991187472003`, i.e. **+17.18 bp**.
///      That is the number the first build of this wrapper overvalued SPY by when it applied the multiplier a second
///      time on top of an answer that already carried it (MEASURED, 2026-09-25: SPY 17.2 bp, SGOV 51 bp, NVDA
///      7.8 bp). Testing on a ticker whose multiplier is non-unit is what makes "price == answer" a real assertion
///      rather than a tautology, which is why SPY is the ground truth here and not a unit-multiplier ticker.
contract RobinhoodEquity_CustomPriceFeedForkTest is TestEnvConfigurator {
    /// @dev Sunday 2026-10-11 12:00:00 ET. Chain head was 90,186,157 on 2026-10-16 (MEASURED), so this is history.
    uint256 internal constant FORK_BLOCK = 85_956_175;

    /// @dev Chainlink PRIMARY proxy for RHSPY/USD on 4663 (never the SVR secondary: it shares the aggregator but
    ///      returns phase-2 round ids, so the two are not interchangeable for round bookkeeping).
    address internal constant SPY_FEED = 0x319724394D3A0e3669269846abE664Cd621f9f6A;
    /// @dev Robinhood's tokenised SPY ERC20 on 4663, 18 decimals.
    address internal constant SPY_TOKEN = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;

    /// @dev A plain ERC20 carrying NONE of the Robinhood getters, priced by a 24/7 `ETH / USD` feed: the control
    ///      that shows the wrapper degenerates to a passthrough and that the off-hours behaviour above is a property
    ///      of the EQUITY calendar, not of the wrapper.
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;

    /// @dev The aggregator's declared publication cadence. DOCUMENTATION ONLY — these contracts expose no
    ///      `heartbeat()`/`timeout()` getter — corroborated by a MEASURED 86,417 s longest intra-week gap.
    uint256 internal constant HEARTBEAT = 86_400;
    /// @dev ADR 0028's policy number: a Friday close plus a Monday US holiday plus margin over the MEASURED 290,892 s
    ///      worst-case legitimate weekend gap on this very feed.
    uint256 internal constant MAX_HOLDOVER = 432_000;

    RobinhoodEquity_CustomPriceFeed internal feed;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("robinhood-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        assertEq(block.chainid, 4663, "not forked onto Robinhood Chain");

        feed = new RobinhoodEquity_CustomPriceFeed(SPY_FEED, SPY_TOKEN, HEARTBEAT, MAX_HOLDOVER);
    }

    // -----------------------------------------------------------------------------------------------------------
    // The premises the rest of the suite rests on
    // -----------------------------------------------------------------------------------------------------------

    /// @dev If any of these stops holding, every assertion below is about something else and must fail loudly.
    function test_premises_sessionBlockFeedAndMultiplier() public view {
        assertEq(block.timestamp, 1_791_734_400, "pinned block is Sunday 2026-10-11 12:00:00 ET");

        assertEq(AggregatorV3Interface(SPY_FEED).description(), "RHSPY / USD", "the SPY equity feed");
        assertEq(AggregatorV3Interface(SPY_FEED).decimals(), 8, "4663 equity aggregators publish at 8 decimals");

        (,,, uint256 legUpdatedAt,) = AggregatorV3Interface(SPY_FEED).latestRoundData();
        assertEq(legUpdatedAt, 1_791_570_259, "last push: Friday 2026-10-09 14:24:19 ET");

        uint256 age = block.timestamp - legUpdatedAt;
        assertEq(age, 164_141, "45 h 35 m of closed tape");
        assertGt(age, HEARTBEAT, "PREMISE: the holdover path is genuinely exercised at this block");
        assertLt(age, MAX_HOLDOVER, "PREMISE: and the mark is still inside the policy limit");

        assertEq(feed.effectiveMultiplier(), 1_001_717_991_187_472_003, "PREMISE: SPY's multiplier is NON-unit");
        assertFalse(feed.oraclePaused(), "no corporate action in progress on the token");
    }

    /// @dev `oraclePaused()` is probed on the TOKEN and not on the feed, and the reason is mechanical: it does not
    ///      exist on the aggregator side. Asserted rather than asserted-in-prose, so a future chain that adds it
    ///      cannot silently change where the flag is read from.
    function test_premise_oraclePausedLivesOnTheTokenNotTheAggregator() public view {
        (bool okFeed,) = SPY_FEED.staticcall(abi.encodeWithSignature("oraclePaused()"));
        assertFalse(okFeed, "the aggregator proxy reverts on oraclePaused()");

        (bool okToken, bytes memory ret) = SPY_TOKEN.staticcall(abi.encodeWithSignature("oraclePaused()"));
        assertTrue(okToken, "the token answers it");
        assertEq(abi.decode(ret, (uint256)), 0, "and reads false at this block");
    }

    // -----------------------------------------------------------------------------------------------------------
    // The price is the aggregator's answer, unmultiplied
    // -----------------------------------------------------------------------------------------------------------

    /// @dev THE 2026-09-25 CORRECTION, pinned against live state. The aggregator already publishes
    ///      `equity price x uiMultiplier`; applying the multiplier again is what cost 17.2 bp on SPY.
    function test_price_isTheAggregatorAnswerAndNotTheMultipliedOne() public view {
        (, int256 answer,,,) = AggregatorV3Interface(SPY_FEED).latestRoundData();
        (uint256 price, bool stale) = feed.getLatestPrice();

        assertEq(price, uint256(answer), "price == answer; the multiplier is already in it");
        assertEq(price, 78_005_783_409, "$780.05783409 at 8 decimals, MEASURED at this block");
        assertFalse(stale, "a weekend mark inside the holdover is not stale");

        // What the first build returned here, and what a regression would return again.
        uint256 doubleMultiplied = (uint256(answer) * feed.effectiveMultiplier()) / 1e18;
        assertGt(doubleMultiplied, price, "the multiplier is non-unit, so the two differ");
        uint256 errorBps = ((doubleMultiplied - price) * 10_000) / price;
        assertEq(errorBps, 17, "the double-multiply is worth 17 bp on SPY, as MEASURED on 2026-09-25");
    }

    function test_decimalsAndUnderlying() public view {
        assertEq(feed.decimals(), AggregatorV3Interface(SPY_FEED).decimals(), "pinned from the aggregator");
        assertEq(feed.decimals(), 8);
        assertEq(feed.underlyingAssetSupported(), SPY_TOKEN);
        assertEq(feed.BASE_ASSET(), address(0), "no NAV-sourced base leg");
    }

    function test_supportsInterface() public view {
        assertTrue(feed.supportsInterface(type(ICustomPriceFeed).interfaceId));
        assertTrue(feed.supportsInterface(type(IERC165).interfaceId));
        assertFalse(feed.supportsInterface(0xffffffff));
    }

    // -----------------------------------------------------------------------------------------------------------
    // The holdover, against the real weekend gap
    // -----------------------------------------------------------------------------------------------------------

    /// @dev The policy boundary walked on live state: the Friday print stands all weekend, and stops standing on the
    ///      exact second ADR 0028 says it should.
    function test_holdover_carriesTheFridayPrintAndExpiresOnTheDocumentedSecond() public {
        (, int256 answer,, uint256 legUpdatedAt,) = AggregatorV3Interface(SPY_FEED).latestRoundData();
        uint256 expected = uint256(answer);

        // Already past the declared cadence at the pinned block, and accepted.
        (uint256 price, bool stale) = feed.getLatestPrice();
        assertEq(price, expected);
        assertFalse(stale, "45 h of closed tape is the ordinary weekend, not a fault");

        // Monday 09:30 ET would be ~1,791,984,600 — still inside the policy. Walk to the edge instead.
        vm.warp(legUpdatedAt + MAX_HOLDOVER - 1);
        (price, stale) = feed.getLatestPrice();
        assertEq(price, expected, "the last accepted second still reports the Friday print");
        assertFalse(stale);

        vm.warp(legUpdatedAt + MAX_HOLDOVER);
        (price, stale) = feed.getLatestPrice();
        assertTrue(stale, "age == MAX_HOLDOVER is refused: the bound is inclusive");
        assertEq(price, expected, "and the refused mark is still visible to an operator");

        vm.warp(legUpdatedAt + 7 days);
        (, stale) = feed.getLatestPrice();
        assertTrue(stale, "never silently recovers");
    }

    /// @dev The control: a 24/7 `ETH / USD` feed on the same chain, at the same Sunday block, on a token that
    ///      implements none of the Robinhood getters. Fresh, unit multiplier, pure passthrough — so the SPY result
    ///      above is a property of the equity calendar and not of this wrapper.
    function test_plainErc20OnACryptoFeed_isFreshAndPassesThrough() public {
        RobinhoodEquity_CustomPriceFeed ethFeed =
            new RobinhoodEquity_CustomPriceFeed(ETH_USD_FEED, WETH, HEARTBEAT, MAX_HOLDOVER);

        assertEq(AggregatorV3Interface(ETH_USD_FEED).description(), "ETH / USD");
        assertEq(ethFeed.effectiveMultiplier(), 1e18, "a plain ERC20 yields a unit multiplier");
        assertFalse(ethFeed.oraclePaused(), "and never reads as paused");

        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();
        (uint256 price, bool stale) = ethFeed.getLatestPrice();
        assertEq(price, uint256(answer), "straight through");
        assertFalse(stale, "a crypto feed does not observe the US calendar");
        assertLt(block.timestamp - updatedAt, HEARTBEAT, "and was pushed minutes ago, not days");
    }

    // -----------------------------------------------------------------------------------------------------------
    // latestRoundData / governingFeedFreshness
    // -----------------------------------------------------------------------------------------------------------

    function test_latestRoundData_isTheAggregatorTupleVerbatim() public view {
        (uint80 aRound, int256 aAnswer, uint256 aStarted, uint256 aUpdated, uint80 aAnsweredIn) =
            AggregatorV3Interface(SPY_FEED).latestRoundData();
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();

        assertEq(roundId, aRound, "roundId");
        assertEq(answer, aAnswer, "answer");
        assertEq(startedAt, aStarted, "startedAt");
        assertEq(updatedAt, aUpdated, "updatedAt: the NAV's selection input must be the real one");
        assertEq(answeredInRound, aAnsweredIn, "answeredInRound");
    }

    /// @dev ADR 0020 for a single-leg feed, plus the direction that ADR does not enumerate: across the weekend the
    ///      advisory pair reads PAST ITS DEADLINE while the authoritative `stale` flag is false. That divergence is
    ///      the operator signal — "running on a holdover mark" — and is why the ADR tells consumers to gate on
    ///      `stale` rather than recompute from the pair.
    function test_governingFeedFreshness_showsTheRealCadenceAndTheRealAge() public view {
        (,,, uint256 legUpdatedAt,) = AggregatorV3Interface(SPY_FEED).latestRoundData();
        (uint256 updatedAt, uint256 heartbeat) = feed.governingFeedFreshness();

        assertEq(updatedAt, legUpdatedAt, "the leg's own timestamp");
        assertEq(heartbeat, HEARTBEAT, "the DECLARED cadence, not the holdover and not the registration value");
        assertGt(block.timestamp - updatedAt, heartbeat, "the advisory pair is past its deadline");

        (, bool stale) = feed.getLatestPrice();
        assertFalse(stale, "while the authoritative verdict prices the book");
    }

    // -----------------------------------------------------------------------------------------------------------
    // Registration on a real NAVCalculator — the ADR 0025 / ADR 0028 coupling, end to end
    // -----------------------------------------------------------------------------------------------------------

    /// @dev The reason the registered heartbeat cannot be the declared 86,400 s, demonstrated rather than argued.
    ///      Both registrations use the same wrapper, the same asset, the same block; only the NAV-side heartbeat
    ///      differs. At the declared cadence `_selectFeedCore`'s `block.timestamp - updatedAt >= heartbeat` discards
    ///      the feed and SPY is unpriceable all weekend; at `requiredRegistrationHeartbeat()` the wrapper's own
    ///      policy is the binding gate and the book prices.
    function test_registration_declaredCadenceKillsItAndThePolicyValueDoesNot() public {
        NAVCalculator nav = _deployNav();
        address manager = makeAddr("manager");

        // (1) ADR 0025's literal rule: register the provider's declared cadence.
        vm.prank(manager);
        nav.registerAsset(SPY_TOKEN, address(feed), IPrices.PriceType.Custom, HEARTBEAT);

        INAVCalculator.PriceFeedData memory pd = INAVCalculator(address(nav)).getPriceData(SPY_TOKEN);
        assertTrue(pd.stale, "at the declared cadence the NAV drops SPY every weekend");
        assertEq(pd.healthyFeedCount, 0, "no feed survives the outer gate");

        // (2) ADR 0028's rule: register the holdover the wrapper declares, read off the wrapper itself.
        uint256 required = feed.requiredRegistrationHeartbeat();
        assertEq(required, MAX_HOLDOVER);
        assertTrue(feed.registrationHeartbeatSatisfiesPolicy(required));
        assertFalse(feed.registrationHeartbeatSatisfiesPolicy(HEARTBEAT));

        vm.prank(manager);
        nav.addOrModifyPriceFeed(SPY_TOKEN, address(feed), IPrices.PriceType.Custom, required);

        pd = INAVCalculator(address(nav)).getPriceData(SPY_TOKEN);
        assertFalse(pd.stale, "the holdover policy now reaches the NAV");
        assertEq(pd.healthyFeedCount, 1);
        assertEq(uint256(pd.price), 78_005_783_409, "SPY prices at Friday's close, as the policy intends");
        assertEq(pd.decimals, 8);

        // ADR 0020: the pair the UI shows is the aggregator's real cadence, NOT the registered value.
        assertEq(pd.chainlinkHeartbeat, HEARTBEAT, "governingFeedFreshness overrides the config heartbeat");
        assertEq(pd.updatedAt, 1_791_570_259, "and the real Friday push timestamp");
    }

    /// @dev The registration gate itself: `supportsInterface`, the asset binding, and the `BASE_ASSET()` circularity
    ///      probe that fails CLOSED on a feed which cannot answer.
    function test_registration_enforcesTheAssetBinding() public {
        NAVCalculator nav = _deployNav();
        address manager = makeAddr("manager");

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(IPrices.CustomFeedAssetMismatch.selector, WETH, address(feed), SPY_TOKEN)
        );
        nav.registerAsset(WETH, address(feed), IPrices.PriceType.Custom, MAX_HOLDOVER);
    }

    function _deployNav() internal returns (NAVCalculator nav) {
        vm.etch(LibraryPins.PRICE_FEED_LIB, vm.deployCode("PriceFeedLib.sol:PriceFeedLib").code);
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, vm.deployCode("NAVRegistryLib.sol:NAVRegistryLib").code);

        address admin = makeAddr("admin");
        vm.startPrank(admin);
        address navImpl = address(new NAVCalculator());
        nav = NAVCalculator(
            UnsafeUpgrades.deployUUPSProxy(
                // 4663 has no Chainlink L2 sequencer uptime feed, so the uptime feed is address(0) by design.
                navImpl,
                abi.encodeCall(NAVCalculator.initialize, (admin, address(0), "USDG"))
            )
        );
        nav.grantRole(MANAGER, makeAddr("manager"));
        vm.stopPrank();
    }
}
