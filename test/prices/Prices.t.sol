// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;
import {LibraryPins} from "script/utils/LibraryPins.sol";

import {Test} from "forge-std/Test.sol";

import {Prices} from "src/prices/Prices.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {
    Mock_ChainlinkL2SequencerUptimeFeed,
    Mock_ChainlinkL2SequencerUptimeFeedAt,
    Mock_ChainlinkL2SequencerUptimeFeedUninitialized,
    Mock_CustomPriceFeed,
    Mock_PriceOracleChainlink,
    Mock_CustomPriceFeedStaled
} from "test/mocks/price_oracles.sol";

contract Mock_CustomPriceFeedZeroUpdatedAt is Mock_CustomPriceFeed {
    constructor() Mock_CustomPriceFeed("zero_upd", address(0x1234), 100_000_000, 8) {}

    function latestRoundData() external pure override returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 0, 0, 0, 0); // updatedAt = 0 → sentinel: treated as block.timestamp-1
    }

    function governingFeedFreshness() external pure override returns (uint256, uint256) {
        return (0, 0); // no trackable oracle → no governing pair
    }
}

contract PricesHarness is Prices {
    constructor(address chainlinkUptimeFeed) initializer {
        __Prices_init(chainlinkUptimeFeed);
    }

    function setPriceOracle(address token, address oracle, uint256 chainlinkHeartbeat, IPrices.PriceType oracleType)
        public
    {
        _addPriceFeed(token, oracle, chainlinkHeartbeat, oracleType);
    }

    function setPriceFeed(address token, address oracle, uint256 chainlinkHeartbeat, IPrices.PriceType oracleType)
        public
    {
        _addPriceFeed(token, oracle, chainlinkHeartbeat, oracleType);
    }

    function removePriceOracle(address token) public {
        _removeAllPriceFeeds(token);
    }

    function removePriceFeedAt(address token, uint256 index) public {
        _removePriceFeedAt(token, index);
    }

    function removePriceFeedByAddr(address token, address feed) public {
        _removePriceFeed(token, feed);
    }

    // --- monitor-feed surface, added so the registration guards in PriceFeedLib are reachable from a test ---

    function setDivergenceTolerance(address token, uint32 bps) public {
        _setDivergenceTolerance(token, bps);
    }

    function addMonitorFeed(address token, address feed, uint256 heartbeat, IPrices.PriceType feedType) public {
        _addMonitorFeed(token, feed, heartbeat, feedType);
    }

    function removeMonitorFeedAt(address token, uint256 index) public {
        _removeMonitorFeedAt(token, index);
    }

    function removeMonitorFeedByAddr(address token, address feed) public {
        _removeMonitorFeed(token, feed);
    }
}

contract PricesTest is Test {
    PricesHarness public manager;
    PricesHarness public managerL2;
    Mock_PriceOracleChainlink chainlinkUptimeFeed;
    Mock_CustomPriceFeed public oracleusdc;
    Mock_PriceOracleChainlink public oracleaBuidl;
    Mock_PriceOracleChainlink public disabledUptimeFeed;
    Mock_ChainlinkL2SequencerUptimeFeed public enabledUptimeFeed;
    Mock_ChainlinkL2SequencerUptimeFeedUninitialized public uninitializedUptimeFeed;
    Mock_CustomPriceFeedStaled public customStaled;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address usdc = makeAddr("usdc");
    address buidl = makeAddr("buidl");

    function setUp() public {
        // PriceFeedLib is pre-linked at this deterministic CREATE2 address (foundry.toml libraries config).
        // In tests there's no chain state, so etch the runtime code there so DELEGATECALL succeeds.
        address priceFeedLibImpl = vm.deployCode("PriceFeedLib.sol:PriceFeedLib");
        vm.etch(LibraryPins.PRICE_FEED_LIB, priceFeedLibImpl.code);
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, vm.deployCode("NAVRegistryLib.sol:NAVRegistryLib").code);

        oracleusdc = new Mock_CustomPriceFeed("usdc", address(usdc), 100_000_000, 8);
        oracleaBuidl = new Mock_PriceOracleChainlink("buidl", 1000, 8);
        disabledUptimeFeed = new Mock_PriceOracleChainlink("UptimeFeed", 1, 8);
        enabledUptimeFeed = new Mock_ChainlinkL2SequencerUptimeFeed();
        uninitializedUptimeFeed = new Mock_ChainlinkL2SequencerUptimeFeedUninitialized();
        manager = new PricesHarness(address(0));
        managerL2 = new PricesHarness(address(chainlinkUptimeFeed));
        customStaled = new Mock_CustomPriceFeedStaled("usdc", address(usdc), 100_000_000, 8);
    }

    function test_latestPrice_WithNonStalePrices() public {
        manager.setPriceFeed(usdc, address(oracleusdc), type(uint256).max, IPrices.PriceType.Custom);
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);

        vm.startPrank(alice);
        (int256 value, uint8 decimals, bool stale,) = manager.latestPrice(usdc);
        assertEq(value, 100_000_000);
        assertEq(decimals, 8);
        assertFalse(stale);

        (value, decimals, stale,) = manager.latestPrice(buidl);
        assertEq(value, 1000);
        assertEq(decimals, 8);
        assertFalse(stale);

        vm.stopPrank();
    }

    function test_latestPrice_BeforeGracePeriod() public {
        manager = new PricesHarness(address(disabledUptimeFeed));
        manager.setPriceFeed(usdc, address(oracleusdc), type(uint256).max, IPrices.PriceType.Custom);
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);

        vm.startPrank(alice);
        (int256 value, uint8 decimals, bool stale,) = manager.latestPrice(usdc);
        assertEq(value, 100_000_000);
        assertEq(decimals, 8);
        assertTrue(stale);

        (value, decimals, stale,) = manager.latestPrice(buidl);
        assertEq(value, 1000);
        assertEq(decimals, 8);
        assertTrue(stale);

        vm.stopPrank();
    }

    function test_latestPrice_AfterHearBeat() public {
        // Chainlink: stale when block.timestamp - latestRoundData().updatedAt > heartbeat.
        // Custom: stale is determined solely by getLatestPrice().stale (per-feed checks inside the adapter).
        manager.setPriceFeed(usdc, address(oracleusdc), type(uint256).max, IPrices.PriceType.Custom);
        manager.setPriceFeed(buidl, address(oracleaBuidl), 1, IPrices.PriceType.Chainlink);

        vm.warp(block.timestamp + 2);

        vm.startPrank(alice);
        // Custom feed: mock always returns stale=false from getLatestPrice() — not stale by heartbeat.
        (int256 value, uint8 decimals, bool stale,) = manager.latestPrice(usdc);
        assertEq(value, 100_000_000);
        assertEq(decimals, 8);
        assertFalse(stale);

        // Chainlink feed: updatedAt is stale after warp past heartbeat=1.
        // New multi-feed behaviour: all feeds stale → price=0 (not the stale value).
        (value, decimals, stale,) = manager.latestPrice(buidl);
        assertEq(value, 0);
        assertEq(decimals, 8);
        assertTrue(stale);

        vm.stopPrank();
    }

    function test_latestPrice_CustomOracleStaled() public {
        // Mock_CustomPriceFeedStaled.getLatestPrice() returns stale=true — always stale.
        manager.setPriceFeed(usdc, address(customStaled), 1, IPrices.PriceType.Custom);
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);

        vm.warp(2);

        vm.startPrank(alice);
        // New multi-feed behaviour: all feeds stale → price=0 (not the stale value).
        (int256 value, uint8 decimals, bool stale,) = manager.latestPrice(usdc);
        assertEq(value, 0);
        assertEq(decimals, 8);
        assertTrue(stale); // stale: getLatestPrice() returns stale=true

        (value, decimals, stale,) = manager.latestPrice(buidl);
        assertEq(value, 1000);
        assertEq(decimals, 8);
        assertFalse(stale);

        vm.stopPrank();
    }

    function test_RevertIf_OracleNotSet() public {
        vm.expectRevert();
        manager.latestPrice(usdc);
    }

    function test_setPriceFeed_Chainlink() public {
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);
    }

    function test_setPriceFeed_CustomOracle() public {
        manager.setPriceFeed(usdc, address(oracleusdc), type(uint256).max, IPrices.PriceType.Custom);
    }

    function test_unsetPriceFeed() public {
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);
        manager.removePriceOracle(buidl);

        assertEq(manager.getPriceFeedCount(buidl), 0);
    }

    function test_CheckCustomOracleSupport_ValidCustomOracle() public view {
        manager.checkPriceOracleSupport(address(usdc), address(oracleusdc), IPrices.PriceType.Custom);
        manager.checkPriceOracleSupport(address(usdc), address(oracleaBuidl), IPrices.PriceType.Chainlink);
    }

    function test_RevertIf_InvalidOracleTypeCL() public {
        vm.expectRevert();
        manager.checkPriceOracleSupport(address(usdc), address(oracleusdc), IPrices.PriceType.Chainlink);
    }

    function test_RevertIf_CheckCustomOracleSupport_InvalidOracleTypeCM() public {
        vm.expectRevert();
        manager.checkPriceOracleSupport(address(usdc), address(oracleaBuidl), IPrices.PriceType.Custom);
    }

    // ============================================
    // Price Feed Management Tests
    // ============================================

    function test_setPriceFeed_zeroAddress() public {
        vm.expectRevert();
        manager.setPriceFeed(usdc, address(0), type(uint256).max, IPrices.PriceType.Custom);
    }

    function test_setPriceFeed_invalidOracleType() public {
        vm.expectRevert();
        manager.setPriceFeed(usdc, address(oracleusdc), type(uint256).max, IPrices.PriceType.Chainlink);
    }

    function test_setPriceFeed_zeroHeartbeat_chainlink() public {
        vm.expectRevert();
        manager.setPriceFeed(buidl, address(oracleaBuidl), 0, IPrices.PriceType.Chainlink);
    }

    function test_setPriceFeed_zeroHeartbeat_custom() public {
        vm.expectRevert();
        manager.setPriceFeed(usdc, address(oracleusdc), 0, IPrices.PriceType.Custom);
    }

    function test_unsetPriceFeed_notSet() public {
        // Unsetting non-existent feed should not revert (delete on non-existent mapping is safe)
        manager.removePriceOracle(usdc);
        assertEq(manager.getPriceFeedCount(usdc), 0);
    }

    // ============================================
    // Getters Tests
    // ============================================

    function test_priceOracles() public {
        manager.setPriceFeed(usdc, address(oracleusdc), type(uint256).max, IPrices.PriceType.Custom);

        IPrices.PriceFeedConfig memory cfg = manager.getPriceFeedAt(usdc, 0);
        assertEq(cfg.priceFeed, address(oracleusdc));
        assertEq(cfg.decimals, 8);
        assertEq(cfg.chainlinkHeartbeat, type(uint256).max);
        assertEq(uint8(cfg.priceType), uint8(IPrices.PriceType.Custom));
    }

    function test_chainlinkL2SequencerUptimeFeed() public view {
        address uptimeFeed = address(manager.chainlinkL2SequencerUptimeFeed());
        // For manager (L1), should be address(0)
        assertEq(uptimeFeed, address(0));
    }

    function test_chainlinkL2SequencerGracePeriod() public view {
        uint256 gracePeriod = manager.chainlinkL2SequencerGracePeriod();
        assertEq(gracePeriod, 1 hours);
    }

    // ============================================
    // Edge Cases Tests
    // ============================================

    function test_setPriceFeed_zeroPrice_reverts() public {
        // A zero-price feed is rejected at registration time
        Mock_PriceOracleChainlink zeroPriceOracle = new Mock_PriceOracleChainlink("Zero", 0, 8);
        vm.expectRevert(IPrices.InvalidPriceOracle.selector);
        manager.setPriceFeed(buidl, address(zeroPriceOracle), type(uint256).max, IPrices.PriceType.Chainlink);
    }

    function test_checkL2SequencerUptime_noFeed() public view {
        // manager has no uptime feed (L1 scenario)
        bool stale = manager.checkL2SequencerUptime();
        assertFalse(stale); // Should return false when no feed is set
    }

    /// @dev Renamed from `test_checkL2SequencerUptime_withinGracePeriod`, which is not what it tests. The feed here
    ///      reports `answer = 1`, so `PriceFeedLib.checkSequencerUptime` returns at the `answer != 0` arm — two
    ///      branches ABOVE the grace-period arm the old name claimed. Its own comment already said so. The grace
    ///      period is now covered by the three `_gracePeriod_*` tests below.
    ///
    ///      This fixture does NOT pin the arm on its own: `Mock_PriceOracleChainlink` hard-codes `startedAt = 0`,
    ///      so it satisfies the NEXT arm too and whole-arm deletion goes unnoticed. See
    ///      `test_checkL2SequencerUptime_sequencerDown_withNonZeroStartedAt` below, which is what kills that
    ///      mutant.
    ///
    ///      **This test is strictly subsumed by that one.** An earlier revision of this comment claimed it was
    ///      kept because it uniquely pins the blanking mutation `if (answer != 0) { }`; that is wrong, and review
    ///      caught it. Under blanking the condition still MATCHES, so the `else if` chain is skipped entirely and
    ///      `stale` stays false for both fixtures — the sibling kills that mutant too. In general: for this test
    ///      to fail, arm 1 must not fire, and with arms 2-3 intact the sibling then reaches
    ///      `elapsed = 2h > 1h` and also reads not-stale. Kept as the plain `answer != 0` regression, not because
    ///      it adds mutation-kill strength.
    function test_checkL2SequencerUptime_sequencerDown_answerNonZero() public {
        managerL2 = new PricesHarness(address(disabledUptimeFeed));

        bool stale = managerL2.checkL2SequencerUptime();
        assertTrue(stale, "answer != 0 must read as down");
    }

    /// @notice A down sequencer with a REAL `startedAt` — the only shape that isolates the `answer != 0` arm.
    /// @dev    Every other `answer != 0` fixture in the repo also reports `startedAt == 0`, so all of them are
    ///         caught by the `startedAt == 0` arm one line below and none can tell the two apart. Deleting
    ///         `if (answer != 0) stale = true;` outright left the whole suite green before this test existed.
    ///
    ///         Not academic: a real Chainlink L2 uptime feed reports `answer = 1` with a non-zero `startedAt`, and
    ///         `startedAt` is when the CURRENT status began — so a sequencer that has been down longer than the
    ///         grace period has `elapsed > gracePeriod`. Without the first arm that falls through to the
    ///         grace-period branch and reads **not stale**: prices accepted while the sequencer is down, which is
    ///         the over-report direction. The `2 hours` here is deliberately past the 1-hour grace period so the
    ///         test fails if the arm is removed rather than being rescued by the grace window.
    function test_checkL2SequencerUptime_sequencerDown_withNonZeroStartedAt() public {
        vm.warp(block.timestamp + 3 hours); // headroom so `- 2 hours` cannot underflow
        Mock_ChainlinkL2SequencerUptimeFeedAt feed =
            new Mock_ChainlinkL2SequencerUptimeFeedAt(block.timestamp - 2 hours);
        feed.setAnswer(1); // sequencer DOWN, and down for longer than the grace period
        managerL2 = new PricesHarness(address(feed));
        assertEq(managerL2.chainlinkL2SequencerGracePeriod(), 1 hours, "fixture assumes a 1h grace period");

        assertTrue(managerL2.checkL2SequencerUptime(), "a down sequencer must read stale regardless of elapsed time");
    }

    /// @notice The far side of the boundary: elapsed is exactly `gracePeriod + 1`, so the sequencer reads healthy.
    /// @dev    **The `vm.warp` is load-bearing — do not remove it.** `Mock_ChainlinkL2SequencerUptimeFeed` returns
    ///         `block.timestamp > 1 hours ? block.timestamp - 1 hours - 1 : 1`, and forge starts the clock at
    ///         `block.timestamp == 1`. Without the warp the ternary takes its SECOND arm, `startedAt` is 1, elapsed
    ///         is 0, and this feed lands *inside* the grace window — the opposite of what the test asserts. The
    ///         warp is what pushes the clock past an hour so the first arm applies. (An earlier reading of this
    ///         file called the warp inert on the grounds that the mock is time-relative; that is true of the first
    ///         arm and false of the branch selection, and the test fails without it.)
    function test_checkL2SequencerUptime_gracePeriod_oneSecondPast_notStale() public {
        managerL2 = new PricesHarness(address(enabledUptimeFeed));
        assertEq(managerL2.chainlinkL2SequencerGracePeriod(), 1 hours, "fixture assumes a 1h grace period");

        vm.warp(block.timestamp + 2 hours + 1); // see @dev — selects the mock's `block.timestamp - 1h - 1` arm

        bool stale = managerL2.checkL2SequencerUptime();
        assertFalse(stale, "gracePeriod + 1 elapsed must NOT be stale");
    }

    /// @notice Deep inside the window: the sequencer came back this very block.
    /// @dev Together with the two tests below this pins `if (elapsed <= gracePeriod) stale = true`, the arm that
    ///      no test reached before — neutralising that line left the entire suite green.
    function test_checkL2SequencerUptime_gracePeriod_justRestarted_stale() public {
        Mock_ChainlinkL2SequencerUptimeFeedAt feed = new Mock_ChainlinkL2SequencerUptimeFeedAt(block.timestamp);
        managerL2 = new PricesHarness(address(feed));

        assertTrue(managerL2.checkL2SequencerUptime(), "0 elapsed must be stale");
    }

    /// @notice The boundary itself. The comparison is `<=`, so elapsed EXACTLY equal to the grace period is stale.
    /// @dev This is the point a `<=`-to-`<` mutation moves, and the only elapsed value that distinguishes them.
    function test_checkL2SequencerUptime_gracePeriod_exactlyAtBoundary_stale() public {
        uint256 grace = 1 hours;
        vm.warp(block.timestamp + grace + 1); // headroom so `block.timestamp - grace` cannot underflow
        Mock_ChainlinkL2SequencerUptimeFeedAt feed = new Mock_ChainlinkL2SequencerUptimeFeedAt(block.timestamp - grace);
        managerL2 = new PricesHarness(address(feed));
        assertEq(managerL2.chainlinkL2SequencerGracePeriod(), grace, "fixture assumes a 1h grace period");

        assertTrue(managerL2.checkL2SequencerUptime(), "elapsed == gracePeriod must be stale (comparison is <=)");
    }

    /// @notice A feed reporting a restart in the FUTURE is clamped to now, not allowed to underflow or to read as
    ///         long-elapsed.
    /// @dev Covers the `startedAt > block.timestamp ? block.timestamp : startedAt` clamp, which shares the arm.
    function test_checkL2SequencerUptime_gracePeriod_futureStartedAt_clampedAndStale() public {
        Mock_ChainlinkL2SequencerUptimeFeedAt feed =
            new Mock_ChainlinkL2SequencerUptimeFeedAt(block.timestamp + 30 days);
        managerL2 = new PricesHarness(address(feed));

        assertTrue(managerL2.checkL2SequencerUptime(), "future startedAt must clamp to now and read as stale");
    }

    function test_checkL2SequencerUptime_uninitializedStartedAtZero() public {
        managerL2 = new PricesHarness(address(uninitializedUptimeFeed));

        bool stale = managerL2.checkL2SequencerUptime();
        assertTrue(stale);
    }

    // =========================================================================
    // Feed-registry guard arms
    //
    // Every one of these reverts was asserted by nothing: neutralising the arm left the whole non-fork suite
    // green. They all sit on the registration path that `06_Configure` and `script/manage/RegisterAssets.s.sol`
    // drive on every chain, which is the reason they are worth having tests rather than deleting.
    //
    // Each test uses a SELECTOR-specific `expectRevert`, deliberately: several of these guards sit one line
    // above another guard that would also revert on the same input, so a bare `expectRevert()` would pass with
    // the arm removed and prove nothing. (`ETHPlus_CustomPriceFeed.t.sol` is the same lesson.)
    // =========================================================================

    /// @dev Second feed for an asset must agree with the first on decimals.
    function test_addFeed_revertsOnDecimalsMismatchWithFirstFeed() public {
        Mock_PriceOracleChainlink eightDec = new Mock_PriceOracleChainlink("eight", 100, 8);
        Mock_PriceOracleChainlink eighteenDec = new Mock_PriceOracleChainlink("eighteen", 100, 18);

        manager.setPriceFeed(buidl, address(eightDec), type(uint256).max, IPrices.PriceType.Chainlink);

        vm.expectRevert(abi.encodeWithSelector(IPrices.PriceFeedDecimalsMismatch.selector, buidl, uint8(8), uint8(18)));
        manager.setPriceFeed(buidl, address(eighteenDec), type(uint256).max, IPrices.PriceType.Chainlink);
    }

    /// @dev Two feeds are registered so that removing this guard reaches an array access rather than the
    ///      `CannotRemoveLastFeed` arm below it — the failure must be attributable to THIS check.
    function test_removeFeedAt_revertsOnIndexOutOfBounds() public {
        Mock_PriceOracleChainlink a = new Mock_PriceOracleChainlink("a", 100, 8);
        Mock_PriceOracleChainlink b = new Mock_PriceOracleChainlink("b", 200, 8);
        manager.setPriceFeed(buidl, address(a), type(uint256).max, IPrices.PriceType.Chainlink);
        manager.setPriceFeed(buidl, address(b), type(uint256).max, IPrices.PriceType.Chainlink);
        assertEq(manager.getPriceFeedCount(buidl), 2, "fixture");

        vm.expectRevert(abi.encodeWithSelector(IPrices.PriceFeedIndexOutOfBounds.selector, buidl, uint256(2)));
        manager.removePriceFeedAt(buidl, 2);
    }

    function test_getPriceFeedAt_revertsOnIndexOutOfBounds() public {
        Mock_PriceOracleChainlink a = new Mock_PriceOracleChainlink("a", 100, 8);
        manager.setPriceFeed(buidl, address(a), type(uint256).max, IPrices.PriceType.Chainlink);

        vm.expectRevert(abi.encodeWithSelector(IPrices.PriceFeedIndexOutOfBounds.selector, buidl, uint256(1)));
        manager.getPriceFeedAt(buidl, 1);
    }

    function test_removeMonitorFeedAt_revertsOnIndexOutOfBounds() public {
        _seedPrimaryAndTolerance();
        Mock_PriceOracleChainlink mon = new Mock_PriceOracleChainlink("mon", 100, 8);
        manager.addMonitorFeed(buidl, address(mon), 1 days, IPrices.PriceType.Chainlink);
        assertEq(manager.getMonitorFeedCount(buidl), 1, "fixture");

        vm.expectRevert(abi.encodeWithSelector(IPrices.PriceFeedIndexOutOfBounds.selector, buidl, uint256(1)));
        manager.removeMonitorFeedAt(buidl, 1);
    }

    /// @dev Monitors must be USD-comparable to the primary, so they must report NAV_DECIMALS (8).
    function test_addMonitorFeed_revertsOnDecimalsMismatch() public {
        _seedPrimaryAndTolerance();
        Mock_PriceOracleChainlink eighteenDec = new Mock_PriceOracleChainlink("eighteen", 100, 18);

        vm.expectRevert(
            abi.encodeWithSelector(IPrices.MonitorFeedDecimalsMismatch.selector, buidl, uint8(8), uint8(18))
        );
        manager.addMonitorFeed(buidl, address(eighteenDec), 1 days, IPrices.PriceType.Chainlink);
    }

    function test_addMonitorFeed_revertsOnDuplicate() public {
        _seedPrimaryAndTolerance();
        Mock_PriceOracleChainlink mon = new Mock_PriceOracleChainlink("mon", 100, 8);
        manager.addMonitorFeed(buidl, address(mon), 1 days, IPrices.PriceType.Chainlink);

        vm.expectRevert(abi.encodeWithSelector(IPrices.MonitorFeedAlreadyRegistered.selector, buidl, address(mon)));
        manager.addMonitorFeed(buidl, address(mon), 1 days, IPrices.PriceType.Chainlink);
    }

    /// @dev The fall-through at the end of `removeMonitorFeed`: the loop finds nothing and the function reverts.
    function test_removeMonitorFeed_revertsWhenNotRegistered() public {
        _seedPrimaryAndTolerance();
        Mock_PriceOracleChainlink registered = new Mock_PriceOracleChainlink("registered", 100, 8);
        Mock_PriceOracleChainlink stranger = new Mock_PriceOracleChainlink("stranger", 100, 8);
        manager.addMonitorFeed(buidl, address(registered), 1 days, IPrices.PriceType.Chainlink);

        vm.expectRevert(abi.encodeWithSelector(IPrices.MonitorFeedNotFound.selector, buidl, address(stranger)));
        manager.removeMonitorFeedByAddr(buidl, address(stranger));
    }

    /// @notice `InvalidPriceOracleType` is defensive code that no input can reach today — this pins WHY.
    /// @dev    `PriceType` has exactly four members and `_validateFeedSupportInternal` handles all four
    ///         (`Custom`, and `Chainlink`/`Redstone`/`API3` together), so the trailing `else` is unreachable from
    ///         Solidity. It is not reachable by hand-rolled calldata either: an out-of-range enum byte is
    ///         rejected by solc's bounds check during ABI decoding, in the entry frame, long before the library
    ///         is consulted. That is what this asserts. If a fifth `PriceType` is ever added without a branch,
    ///         this test keeps passing but the `else` stops being dead — so treat this as documentation of the
    ///         current shape, not as coverage of the arm.
    function test_invalidPriceOracleType_isUnreachable_enumBoundsCheckFiresFirst() public {
        Mock_PriceOracleChainlink feed = new Mock_PriceOracleChainlink("feed", 100, 8);

        // 4 is one past `PriceType.Custom` (3), the highest declared member.
        bytes memory callData = abi.encodeWithSignature(
            "setPriceFeed(address,address,uint256,uint8)", buidl, address(feed), type(uint256).max, uint8(4)
        );

        // Asserted on the raw return rather than with `vm.expectRevert`: a low-level `.call` catches the revert
        // and returns `false`, so the cheatcode would not see one. Reading the returndata is the point — it is
        // what distinguishes "rejected while decoding" from "reached the library".
        //
        // The expected payload is EMPTY, not `Panic(0x21)`. Solidity's ABI decoder validates an enum argument
        // with a bare `revert(0, 0)`; `Panic(0x21)` is what an explicit in-code conversion (`PriceType(x)`)
        // produces, which is a different path and not the one calldata takes. `InvalidPriceOracleType()` would
        // be 4 bytes of selector, so an empty payload is positive evidence the trailing `else` was never reached.
        (bool ok, bytes memory ret) = address(manager).call(callData);

        assertFalse(ok, "an out-of-range PriceType must be rejected");
        assertEq(ret.length, 0, "must fail in the ABI enum bounds check (empty revert), not with a named error");
    }

    /// @dev `addMonitorFeed` refuses to run at all until a divergence tolerance exists, so every monitor-feed
    ///      test needs a primary feed and a tolerance in place before it can reach the arm it is aiming at.
    function _seedPrimaryAndTolerance() internal {
        Mock_PriceOracleChainlink primary = new Mock_PriceOracleChainlink("primary", 100, 8);
        manager.setPriceFeed(buidl, address(primary), type(uint256).max, IPrices.PriceType.Chainlink);
        manager.setDivergenceTolerance(buidl, 500);
    }

    // ============================================
    // Multi-feed Tests
    // ============================================

    function test_multiFeed_registration() public {
        assertEq(manager.getPriceFeedCount(buidl), 0);
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);
        assertEq(manager.getPriceFeedCount(buidl), 1);

        Mock_PriceOracleChainlink oracle2 = new Mock_PriceOracleChainlink("b", 200, 8);
        Mock_PriceOracleChainlink oracle3 = new Mock_PriceOracleChainlink("c", 300, 8);
        manager.setPriceFeed(buidl, address(oracle2), type(uint256).max, IPrices.PriceType.Chainlink);
        manager.setPriceFeed(buidl, address(oracle3), type(uint256).max, IPrices.PriceType.Chainlink);

        assertEq(manager.getPriceFeedCount(buidl), 3);

        IPrices.PriceFeedConfig[] memory feeds = manager.getPriceFeeds(buidl);
        assertEq(feeds.length, 3);
        assertEq(feeds[0].priceFeed, address(oracleaBuidl));
        assertEq(feeds[1].priceFeed, address(oracle2));
        assertEq(feeds[2].priceFeed, address(oracle3));
    }

    function test_multiFeed_cannotRemoveLastFeed() public {
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);

        vm.expectRevert(abi.encodeWithSelector(IPrices.CannotRemoveLastFeed.selector, buidl));
        manager.removePriceFeedAt(buidl, 0);
    }

    function test_multiFeed_removePriceFeedAt_swapWithLast() public {
        Mock_PriceOracleChainlink oracle2 = new Mock_PriceOracleChainlink("b", 200, 8);
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink); // index 0
        manager.setPriceFeed(buidl, address(oracle2), type(uint256).max, IPrices.PriceType.Chainlink); // index 1

        // Remove index 0: oracle2 swapped to index 0 (swap-with-last).
        manager.removePriceFeedAt(buidl, 0);

        assertEq(manager.getPriceFeedCount(buidl), 1);
        assertEq(manager.getPriceFeedAt(buidl, 0).priceFeed, address(oracle2));
    }

    function test_multiFeed_removePriceFeed_byAddress() public {
        Mock_PriceOracleChainlink oracle2 = new Mock_PriceOracleChainlink("b", 200, 8);
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);
        manager.setPriceFeed(buidl, address(oracle2), type(uint256).max, IPrices.PriceType.Chainlink);

        manager.removePriceFeedByAddr(buidl, address(oracleaBuidl));

        assertEq(manager.getPriceFeedCount(buidl), 1);
        assertEq(manager.getPriceFeedAt(buidl, 0).priceFeed, address(oracle2));
    }

    function test_multiFeed_removePriceFeed_notFound() public {
        Mock_PriceOracleChainlink oracle2 = new Mock_PriceOracleChainlink("b", 200, 8);
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);
        manager.setPriceFeed(buidl, address(oracle2), type(uint256).max, IPrices.PriceType.Chainlink);

        address nonExistent = makeAddr("nonExistent");
        vm.expectRevert(abi.encodeWithSelector(IPrices.PriceFeedNotFound.selector, buidl, nonExistent));
        manager.removePriceFeedByAddr(buidl, nonExistent);
    }

    function test_multiFeed_duplicateFeed_reverts() public {
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);

        vm.expectRevert(
            abi.encodeWithSelector(IPrices.PriceFeedAlreadyRegistered.selector, buidl, address(oracleaBuidl))
        );
        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);
    }

    function test_multiFeed_freshestWins() public {
        // Three feeds at t=100, t=200, t=300; current block at t=400.
        vm.warp(100);
        Mock_PriceOracleChainlink oracle1 = new Mock_PriceOracleChainlink("a", 111, 8); // updatedAt=100
        vm.warp(200);
        Mock_PriceOracleChainlink oracle2 = new Mock_PriceOracleChainlink("b", 222, 8); // updatedAt=200
        vm.warp(300);
        Mock_PriceOracleChainlink oracle3 = new Mock_PriceOracleChainlink("c", 333, 8); // updatedAt=300

        vm.warp(400);
        PricesHarness h = new PricesHarness(address(0));
        h.setPriceFeed(buidl, address(oracle1), type(uint256).max, IPrices.PriceType.Chainlink);
        h.setPriceFeed(buidl, address(oracle2), type(uint256).max, IPrices.PriceType.Chainlink);
        h.setPriceFeed(buidl, address(oracle3), type(uint256).max, IPrices.PriceType.Chainlink);

        (int256 price,, bool stale,) = h.latestPrice(buidl);
        assertEq(price, 333); // oracle3 freshest (updatedAt=300)
        assertFalse(stale);
    }

    function test_multiFeed_oneStaleHeartbeat_secondWins() public {
        // oracle1 stale (heartbeat exceeded), oracle2 fresh — oracle2 wins.
        vm.warp(100);
        Mock_PriceOracleChainlink oracle1 = new Mock_PriceOracleChainlink("a", 111, 8); // updatedAt=100
        vm.warp(200);
        Mock_PriceOracleChainlink oracle2 = new Mock_PriceOracleChainlink("b", 222, 8); // updatedAt=200

        vm.warp(400);
        PricesHarness h = new PricesHarness(address(0));
        h.setPriceFeed(buidl, address(oracle1), 250, IPrices.PriceType.Chainlink); // 400-100=300 > 250 → stale
        h.setPriceFeed(buidl, address(oracle2), 250, IPrices.PriceType.Chainlink); // 400-200=200 < 250 → fresh

        (int256 price,, bool stale,) = h.latestPrice(buidl);
        assertEq(price, 222);
        assertFalse(stale);
    }

    function test_multiFeed_allStale_returnsZeroAndStale() public {
        vm.warp(100);
        Mock_PriceOracleChainlink oracle1 = new Mock_PriceOracleChainlink("a", 111, 8); // updatedAt=100
        vm.warp(200);
        Mock_PriceOracleChainlink oracle2 = new Mock_PriceOracleChainlink("b", 222, 8); // updatedAt=200

        vm.warp(400);
        PricesHarness h = new PricesHarness(address(0));
        h.setPriceFeed(buidl, address(oracle1), 50, IPrices.PriceType.Chainlink); // 400-100=300 > 50 → stale
        h.setPriceFeed(buidl, address(oracle2), 50, IPrices.PriceType.Chainlink); // 400-200=200 > 50 → stale

        (int256 price, uint8 decimals, bool stale,) = h.latestPrice(buidl);
        assertEq(price, 0); // all stale → zero
        assertEq(decimals, 8); // first feed's decimals for unit consistency
        assertTrue(stale);
    }

    function test_multiFeed_customFeed_zeroUpdatedAt_survivesAsSentinel() public {
        // Custom feed returning updatedAt=0 means "no trackable oracle".
        // Treated as block.timestamp-1 so it passes the staleness gate (survives) but
        // loses to any feed that reports a real on-chain update timestamp.
        vm.warp(1000);
        Mock_CustomPriceFeedZeroUpdatedAt customZero = new Mock_CustomPriceFeedZeroUpdatedAt();
        PricesHarness h = new PricesHarness(address(0));
        h.setPriceFeed(buidl, address(customZero), type(uint256).max, IPrices.PriceType.Custom);

        (int256 price,, bool stale,) = h.latestPrice(buidl);
        assertEq(price, 100_000_000); // survives — effective time = block.timestamp-1, not 0
        assertFalse(stale);
    }

    // ============================================
    // API3 Feed Tests
    // ============================================

    function test_registerAPI3_storesEightDecimals() public {
        // API3 proxy returns 18 decimals; PriceFeedLib must store 8 in the config.
        Mock_PriceOracleChainlink api3Feed = new Mock_PriceOracleChainlink("ETH/USD API3", 3000e18, 18);
        manager.setPriceFeed(buidl, address(api3Feed), type(uint256).max, IPrices.PriceType.API3);

        IPrices.PriceFeedConfig memory cfg = manager.getPriceFeedAt(buidl, 0);
        assertEq(cfg.decimals, 8, "API3 feed must be stored with 8 output decimals");
        assertEq(uint8(cfg.priceType), uint8(IPrices.PriceType.API3));
    }

    function test_registerAPI3_nonStandardDecimalsReverts() public {
        // Only 18-dec proxies are valid API3 feeds; 8-dec must revert.
        Mock_PriceOracleChainlink badFeed = new Mock_PriceOracleChainlink("bad API3", 3000e8, 8);
        vm.expectRevert(IPrices.InvalidPriceOracle.selector);
        manager.setPriceFeed(buidl, address(badFeed), type(uint256).max, IPrices.PriceType.API3);
    }

    function test_registerAPI3_thenChainlink_decimalConsistencyPasses() public {
        // API3 stored as 8-dec → adding an 8-dec Chainlink feed must succeed.
        Mock_PriceOracleChainlink api3Feed = new Mock_PriceOracleChainlink("ETH/USD API3", 3000e18, 18);
        manager.setPriceFeed(buidl, address(api3Feed), type(uint256).max, IPrices.PriceType.API3);

        manager.setPriceFeed(buidl, address(oracleaBuidl), type(uint256).max, IPrices.PriceType.Chainlink);

        assertEq(manager.getPriceFeedCount(buidl), 2);
        assertEq(manager.getPriceFeedAt(buidl, 0).decimals, 8);
        assertEq(manager.getPriceFeedAt(buidl, 1).decimals, 8);
    }

    function test_latestPrice_API3_scaledCorrectly() public {
        // Proxy returns 3000e18 (18-dec); latestPrice must return 3000e8 (8-dec).
        Mock_PriceOracleChainlink api3Feed = new Mock_PriceOracleChainlink("ETH/USD API3", 3000e18, 18);
        manager.setPriceFeed(buidl, address(api3Feed), type(uint256).max, IPrices.PriceType.API3);

        (int256 price, uint8 decimals, bool stale,) = manager.latestPrice(buidl);
        assertEq(price, 3000e8, "18-dec API3 price must be scaled to 8-dec");
        assertEq(decimals, 8);
        assertFalse(stale);
    }

    function test_multiFeed_clockSkewNormalization() public {
        // A feed whose updatedAt > block.timestamp (future-dated timestamp)
        // must be clamped to block.timestamp and NOT systematically beat a normally-timed feed.
        // Register both feeds at t=300 (no future-timestamp at registration), then adjust normalOracle
        // to t=100 via setter and warp back to test the read-path clamping.
        vm.warp(300);
        Mock_PriceOracleChainlink futureOracle = new Mock_PriceOracleChainlink("future", 999, 8); // _updatedAt=300
        Mock_PriceOracleChainlink normalOracle = new Mock_PriceOracleChainlink("normal", 111, 8); // _updatedAt=300
        PricesHarness h = new PricesHarness(address(0));
        h.setPriceFeed(buidl, address(normalOracle), type(uint256).max, IPrices.PriceType.Chainlink); // index 0
        h.setPriceFeed(buidl, address(futureOracle), type(uint256).max, IPrices.PriceType.Chainlink); // index 1

        // Rewind normalOracle to t=100; futureOracle stays at t=300.
        normalOracle.setUpdatedAt(100);
        vm.warp(100);

        // normalOracle: updatedAt=100 → effectiveTime=min(100,100)=100
        // futureOracle: updatedAt=300 > block.timestamp=100 → effectiveTime=min(300,100)=100 (clamped)
        // Both tie at 100; index 0 (normalOracle) wins the tie.
        (int256 price,, bool stale,) = h.latestPrice(buidl);
        assertFalse(stale);
        assertEq(price, 111); // normalOracle wins; futureOracle clamped, no longer beats it
    }
}
