// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {SuperTest} from "test/SuperTest.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {Mock_PriceOracleChainlink} from "test/mocks/price_oracles.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";

/// @title HeartbeatMutabilityTest
/// @author KPK
/// @notice A registered heartbeat must be CHANGEABLE, and changing it must move nothing else.
/// @dev Before `addOrModifyPriceFeed` upserted, a registered heartbeat was effectively immutable:
///      `removePriceFeed` refuses an asset's LAST feed and the old `addPriceFeed` refused a feed address the
///      asset already carried — and every registered asset holds exactly one feed, so both orderings were
///      closed. Changing one number meant registering a mirror of the incumbent feed to escape the last-feed
///      guard, swapping through it, then removing it: four transactions per asset, with an unaudited
///      pass-through contract transiently in the pricing path.
contract HeartbeatMutabilityTest is SuperTest {
    Mock_PriceOracleChainlink internal feed;
    Mock_ERC20 internal token;

    function setUp() public {
        setupAll();
        // A FRESH asset, not `weth`: setupAll() already registers weth, and `registerAsset` reverts
        // InvalidArguments on an already-registered asset. Registering our own keeps this fixture
        // independent of what the shared setup happens to have wired up.
        token = new Mock_ERC20("HBT", 18);
        feed = new Mock_PriceOracleChainlink("HB", 1, 8);
        vm.prank(navCalculatorManager);
        nav.registerAsset(address(token), address(feed), IPrices.PriceType.Chainlink, 3600);
    }

    /// @notice The heartbeat changes, and the feed identity does NOT.
    /// @dev The second half is the point. An upsert that also re-applied priceType/decimals could silently
    ///      change WHICH oracle prices an asset while looking like a config tweak — a worse failure than the
    ///      immutability it replaces.
    function test_upsert_changesOnlyTheHeartbeat() public {
        IPrices.PriceFeedConfig memory before_ = nav.getPriceFeedAt(address(token), 0);
        assertEq(before_.chainlinkHeartbeat, 3600);

        vm.prank(navCalculatorManager);
        nav.addOrModifyPriceFeed(address(token), address(feed), IPrices.PriceType.Chainlink, 4242);

        IPrices.PriceFeedConfig memory after_ = nav.getPriceFeedAt(address(token), 0);
        assertEq(after_.chainlinkHeartbeat, 4242, "heartbeat did not change");
        assertEq(after_.priceFeed, before_.priceFeed, "FEED ADDRESS CHANGED");
        assertEq(uint256(after_.priceType), uint256(before_.priceType), "priceType changed");
        assertEq(after_.decimals, before_.decimals, "decimals changed");
        assertEq(nav.getPriceFeedCount(address(token)), 1, "must UPDATE in place, not append");
    }

    /// @notice A changed `priceType` is REJECTED, not silently ignored.
    /// @dev `_validateFeedSupportInternal` groups Chainlink/Redstone/API3 into one branch, so this mismatch
    ///      passes validation. Without the guard the call SUCCEEDS, moves the heartbeat, and leaves the type
    ///      as Chainlink — reporting success for a change it did not make. Two gates disagreed about whether
    ///      this was reachable; it is.
    function test_upsert_rejectsChangedPriceType() public {
        vm.prank(navCalculatorManager);
        vm.expectRevert(abi.encodeWithSelector(IPrices.PriceFeedTypeImmutable.selector, address(token), address(feed)));
        nav.addOrModifyPriceFeed(address(token), address(feed), IPrices.PriceType.Redstone, 4242);
    }

    /// @notice A no-op re-registration still reverts, preserving the double-registration guard.
    /// @dev The upsert must fire only when something actually changes; accepting an identical re-register
    ///      would swallow the operator error the original guard existed to catch.
    function test_upsert_noOpStillReverts() public {
        vm.prank(navCalculatorManager);
        vm.expectRevert(
            abi.encodeWithSelector(IPrices.PriceFeedAlreadyRegistered.selector, address(token), address(feed))
        );
        nav.addOrModifyPriceFeed(address(token), address(feed), IPrices.PriceType.Chainlink, 3600);
    }

    /// @notice Zero is refused on the UPDATE path too, not just first registration.
    /// @dev Guard changes get both directions: 0 disables the staleness gate outright, turning a fat-finger
    ///      into an unbounded window in which a dead feed still reads fresh.
    function test_upsert_rejectsZeroHeartbeat() public {
        vm.prank(navCalculatorManager);
        vm.expectRevert(IPrices.InvalidPriceOracle.selector);
        nav.addOrModifyPriceFeed(address(token), address(feed), IPrices.PriceType.Chainlink, 0);
    }

    /// @notice Still MANAGER-gated — the upsert must not widen who can change a heartbeat.
    function test_upsert_isManagerGated() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        nav.addOrModifyPriceFeed(address(token), address(feed), IPrices.PriceType.Chainlink, 4242);
    }

    /// @notice A DIFFERENT feed address still appends, so multi-feed registration is unaffected.
    /// @dev The nearest legitimate input to the changed guard: the upsert must not turn a genuine
    ///      second-feed registration into an accidental overwrite of the first.
    function test_differentFeedStillAppends() public {
        Mock_PriceOracleChainlink second = new Mock_PriceOracleChainlink("HB2", 1, 8);
        vm.prank(navCalculatorManager);
        nav.addOrModifyPriceFeed(address(token), address(second), IPrices.PriceType.Chainlink, 7200);
        assertEq(nav.getPriceFeedCount(address(token)), 2, "a new feed address must APPEND");
        assertEq(nav.getPriceFeedAt(address(token), 0).chainlinkHeartbeat, 3600, "existing feed disturbed");
    }

    // --- monitor feeds: same upsert, so the realign script needs no remove/add pair ------------------

    /// @notice A monitor feed's heartbeat is changeable in place, in ONE transaction.
    /// @dev Before this, changing a monitor heartbeat meant `removeMonitorFeed` then `addMonitorFeed` —
    ///      two independent broadcasts with no atomicity, so an interrupted run left the monitor removed and
    ///      divergence detection silently degraded. Unlike the primary-feed case there was no last-feed guard
    ///      making it impossible; it was merely unsafe, which is why it survived longer.
    function test_monitorUpsert_changesHeartbeatInPlace() public {
        Mock_PriceOracleChainlink mon = new Mock_PriceOracleChainlink("MON", 1, 8);
        vm.startPrank(navCalculatorManager);
        nav.setDivergenceTolerance(address(token), 500);
        nav.addMonitorFeed(address(token), address(mon), IPrices.PriceType.Chainlink, 3600);
        nav.addMonitorFeed(address(token), address(mon), IPrices.PriceType.Chainlink, 7200);
        vm.stopPrank();

        IPrices.PriceFeedConfig[] memory m = nav.getMonitorFeeds(address(token));
        assertEq(m.length, 1, "must UPDATE in place, not append a second monitor");
        assertEq(m[0].chainlinkHeartbeat, 7200, "monitor heartbeat did not change");
        assertEq(m[0].priceFeed, address(mon), "monitor feed address changed");
    }

    /// @notice An identical monitor re-register still reverts, keeping the duplicate guard.
    function test_monitorUpsert_noOpStillReverts() public {
        Mock_PriceOracleChainlink mon = new Mock_PriceOracleChainlink("MON", 1, 8);
        vm.startPrank(navCalculatorManager);
        nav.setDivergenceTolerance(address(token), 500);
        nav.addMonitorFeed(address(token), address(mon), IPrices.PriceType.Chainlink, 3600);
        vm.expectRevert(
            abi.encodeWithSelector(IPrices.MonitorFeedAlreadyRegistered.selector, address(token), address(mon))
        );
        nav.addMonitorFeed(address(token), address(mon), IPrices.PriceType.Chainlink, 3600);
        vm.stopPrank();
    }

    /// @notice A changed `priceType` on the monitor upsert is rejected, as on the primary path.
    function test_monitorUpsert_rejectsChangedPriceType() public {
        Mock_PriceOracleChainlink mon = new Mock_PriceOracleChainlink("MON", 1, 8);
        vm.startPrank(navCalculatorManager);
        nav.setDivergenceTolerance(address(token), 500);
        nav.addMonitorFeed(address(token), address(mon), IPrices.PriceType.Chainlink, 3600);
        vm.expectRevert(abi.encodeWithSelector(IPrices.PriceFeedTypeImmutable.selector, address(token), address(mon)));
        nav.addMonitorFeed(address(token), address(mon), IPrices.PriceType.Redstone, 7200);
        vm.stopPrank();
    }

    /// @notice The upsert REVALIDATES the feed's decimals; drift reverts instead of silently persisting.
    /// @dev Vigilo, on 53a106a6. The read path scales by the STORED `cfg.decimals` and never re-reads
    ///      `decimals()`, so a feed whose decimals drift make every price for that asset wrong by 10**delta —
    ///      and a positive delta OVER-reports, the one direction this repo never licenses. Chainlink's
    ///      `AggregatorProxy.decimals()` forwards to the swappable current aggregator, so it is not
    ///      structurally impossible. `addMonitorFeed` already resolved decimals above its dedup loop; `addFeed`
    ///      resolved them below, so the upsert path returned first and skipped the check entirely.
    function test_upsert_revalidatesDecimals() public {
        vm.mockCall(address(feed), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));

        vm.prank(navCalculatorManager);
        vm.expectRevert(abi.encodeWithSelector(IPrices.PriceFeedDecimalsMismatch.selector, address(token), 8, 18));
        nav.addOrModifyPriceFeed(address(token), address(feed), IPrices.PriceType.Chainlink, 7200);

        vm.clearMockedCalls();
        assertEq(nav.getPriceFeedAt(address(token), 0).chainlinkHeartbeat, 3600, "heartbeat must not have moved");
    }

    /// @notice Both upserts emit their heartbeat event with the right asset, feed and argument ORDER.
    /// @dev Nothing asserted these before. They are the whole monitoring story of this PR — `PriceFeedLib`
    ///      states in bold that the PriceFeedAdded/PriceFeedRemoved pair no longer fires for a heartbeat
    ///      change and tells alerting to subscribe to these instead. A swapped (old, new) order, a wrong
    ///      `indexed` choice or the wrong asset would have shipped green, and the first signal would be an
    ///      alerting pipeline reporting every widening as a narrowing.
    function test_upsert_emitsHeartbeatEvents() public {
        vm.expectEmit(true, true, false, true, address(nav));
        emit IPrices.PriceFeedHeartbeatUpdated(address(token), address(feed), 3600, 4242);
        vm.prank(navCalculatorManager);
        nav.addOrModifyPriceFeed(address(token), address(feed), IPrices.PriceType.Chainlink, 4242);

        Mock_PriceOracleChainlink mon = new Mock_PriceOracleChainlink("MON", 1, 8);
        vm.startPrank(navCalculatorManager);
        nav.setDivergenceTolerance(address(token), 500);
        nav.addMonitorFeed(address(token), address(mon), IPrices.PriceType.Chainlink, 3600);

        vm.expectEmit(true, true, false, true, address(nav));
        emit IPrices.MonitorFeedHeartbeatUpdated(address(token), address(mon), 3600, 7200);
        nav.addMonitorFeed(address(token), address(mon), IPrices.PriceType.Chainlink, 7200);
        vm.stopPrank();
    }

    /// @notice The divergence tolerance CANNOT be zeroed, which refutes a review finding rather than fixing it.
    /// @dev A review argued that running `DivergenceToleranceRequired` above the monitor upsert loop would lock
    ///      out a heartbeat update on an asset whose tolerance had been "zeroed operationally". The lockout is
    ///      real in the abstract and unreachable in this codebase: the setter rejects zero, and admitting a
    ///      monitor requires a non-zero tolerance, so every monitored asset has one. Pinned so the refutation
    ///      survives — if the setter ever accepts zero, the finding becomes live and this test says so.
    function test_divergenceToleranceCannotBeZeroed() public {
        vm.startPrank(navCalculatorManager);
        nav.setDivergenceTolerance(address(token), 500);
        vm.expectRevert(abi.encodeWithSelector(IPrices.InvalidTolerance.selector, uint32(0)));
        nav.setDivergenceTolerance(address(token), 0);
        vm.stopPrank();
    }
}
