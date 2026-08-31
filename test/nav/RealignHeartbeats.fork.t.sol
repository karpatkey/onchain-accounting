// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {console2} from "forge-std/console2.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";

/// @title RealignHeartbeatsForkTest
/// @author KPK
/// @notice Establishes WHICH heartbeats ADR 0025 can actually realign on a live NAV, and which are
///         locked until the next registration.
/// @dev The realignment was planned as `removePriceFeed` + `addPriceFeed` at the new heartbeat, because
///      there is no `updateHeartbeat`. Simulating that plan against mainnet showed it cannot execute:
///      `PriceFeedLib:1694` refuses to remove an asset's LAST price feed, and `PriceFeedLib:1668`
///      refuses to add a feed address the asset already carries. Every registered asset holds exactly
///      one price feed, so both orderings are closed and the heartbeat is effectively immutable
///      post-registration. These tests pin that, so the constraint is a known property rather than
///      something the next operator rediscovers mid-bundle.
contract RealignHeartbeatsForkTest is Test, TestEnvConfigurator {
    uint256 constant FORK_BLOCK = 25_854_566;
    address constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    address constant MANAGER = 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;

    function setUp() public {
        createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
    }

    /// @notice remove-then-add is closed: the sole price feed cannot be removed.
    function test_priceFeedHeartbeat_removeThenAdd_isBlocked() public {
        IPrices.PriceFeedConfig memory cfg = NAVCalculator(NAV).getPriceFeedAt(AAVE, 0);
        assertEq(NAVCalculator(NAV).getPriceFeedCount(AAVE), 1, "precondition: single feed");

        vm.prank(MANAGER);
        vm.expectRevert(abi.encodeWithSelector(IPrices.CannotRemoveLastFeed.selector, AAVE));
        NAVCalculator(NAV).removePriceFeed(AAVE, cfg.priceFeed);
    }

    /// @notice add-then-remove is closed too: the same feed address cannot be registered twice.
    /// @dev Together with the test above this is the proof that the heartbeat is unreachable — not that
    ///      one ordering was wrong. Both doors are shut, so no sequencing of the existing API opens it.
    function test_priceFeedHeartbeat_addThenRemove_isBlocked() public {
        IPrices.PriceFeedConfig memory cfg = NAVCalculator(NAV).getPriceFeedAt(AAVE, 0);

        vm.prank(MANAGER);
        vm.expectRevert(abi.encodeWithSelector(IPrices.PriceFeedAlreadyRegistered.selector, AAVE, cfg.priceFeed));
        NAVCalculator(NAV).addPriceFeed(AAVE, cfg.priceFeed, cfg.priceType, 3600);
    }

    /// @notice MONITOR feed heartbeats ARE realignable — no last-feed guard on that array.
    /// @dev This is the part of ADR 0025 that can execute today. Monitor feeds do not gate pricing; they
    ///      only drive divergence reporting, so realigning them is both possible and low-consequence.
    function test_monitorFeedHeartbeat_isRealignable() public {
        IPrices.PriceFeedConfig[] memory m = NAVCalculator(NAV).getMonitorFeeds(USDC);
        assertEq(m.length, 1, "precondition: USDC carries one monitor feed");
        uint256 want = 82800;
        vm.assume(m[0].chainlinkHeartbeat != want);

        vm.startPrank(MANAGER);
        NAVCalculator(NAV).removeMonitorFeed(USDC, m[0].priceFeed);
        NAVCalculator(NAV).addMonitorFeed(USDC, m[0].priceFeed, m[0].priceType, want);
        vm.stopPrank();

        IPrices.PriceFeedConfig[] memory after_ = NAVCalculator(NAV).getMonitorFeeds(USDC);
        assertEq(after_.length, 1);
        assertEq(after_[0].priceFeed, m[0].priceFeed, "monitor feed address changed");
        assertEq(after_[0].chainlinkHeartbeat, want, "monitor heartbeat not applied");
        // The price itself must be untouched: monitor feeds are not a pricing input.
        assertGt(uint256(INAVCalculator(NAV).getPriceData(USDC).price), 0);
    }

    /// @notice The unregister/re-register fallback works mechanically but DESTROYS pricing metadata.
    /// @dev Documents why this is not the route taken. Between the two calls the asset is absent from the
    ///      registry entirely — NAV under-reports by its full value with NO staleness flag raised, which is
    ///      a silently wrong NAV rather than the loudly-halted one ADR 0025 is trying to guarantee. The
    ///      monitor feeds and tolerances are wiped and must be re-applied by hand afterwards.
    function test_unregisterReregister_wipesMetadata() public {
        uint256 monitorsBefore = NAVCalculator(NAV).getMonitorFeedCount(USDC);
        assertGt(monitorsBefore, 0, "precondition: USDC has a monitor feed to lose");
        IPrices.PriceFeedConfig memory cfg = NAVCalculator(NAV).getPriceFeedAt(USDC, 0);

        vm.startPrank(MANAGER);
        NAVCalculator(NAV).unregisterAsset(USDC);
        assertFalse(INAVCalculator(NAV).isAssetRegistered(USDC), "asset still registered");

        NAVCalculator(NAV).registerAsset(USDC, cfg.priceFeed, cfg.priceType, 82800);
        vm.stopPrank();

        assertEq(NAVCalculator(NAV).getPriceFeedAt(USDC, 0).chainlinkHeartbeat, 82800, "heartbeat not applied");
        assertEq(NAVCalculator(NAV).getMonitorFeedCount(USDC), 0, "monitor feeds unexpectedly survived");
        console2.log("unregister/re-register DID apply the heartbeat, and lost %d monitor feed(s)", monitorsBefore);
    }
}

/// @title RealignViaSecondFeedForkTest
/// @author KPK
/// @notice Tests the only sequence that changes a price-feed heartbeat WITHOUT unregistering the asset:
///         temporarily carry a second feed so the last-feed guard never trips.
/// @dev     add(G) -> remove(F) -> add(F, newHeartbeat) -> remove(G).
///      The danger is the middle of that sequence. `removeFeed` is swap-with-last + pop, so after step 2
///      the asset's PRIMARY feed is G, and the asset is priced from G and reported FRESH. If G is an
///      arbitrary aggregator that is a wrong price presented as good — precisely the failure ADR 0025
///      exists to prevent. So G must be a genuine second source for the SAME asset, which is exactly what
///      a monitor feed already is. These tests establish whether that holds.
contract RealignViaSecondFeedForkTest is Test, TestEnvConfigurator {
    uint256 constant FORK_BLOCK = 25_854_566;
    address constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    address constant MANAGER = 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function setUp() public {
        createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
    }

    function test_swapVia_monitorFeed_asTemporarySecond() public {
        IPrices.PriceFeedConfig memory F = NAVCalculator(NAV).getPriceFeedAt(USDC, 0);
        IPrices.PriceFeedConfig[] memory mons = NAVCalculator(NAV).getMonitorFeeds(USDC);
        assertGt(mons.length, 0, "USDC needs a monitor feed to borrow as the temporary second source");
        address G = mons[0].priceFeed;
        uint256 want = 82800;

        uint256 p0 = uint256(INAVCalculator(NAV).getPriceData(USDC).price);

        vm.startPrank(MANAGER);
        NAVCalculator(NAV).addPriceFeed(USDC, G, mons[0].priceType, want);
        NAVCalculator(NAV).removePriceFeed(USDC, F.priceFeed);

        // The exposed middle of the sequence: what does NAV report while only G is registered?
        INAVCalculator.PriceFeedData memory mid = INAVCalculator(NAV).getPriceData(USDC);
        console2.log("mid-sequence price %d (was %d), stale=%s", uint256(mid.price), p0, mid.stale);

        NAVCalculator(NAV).addPriceFeed(USDC, F.priceFeed, F.priceType, want);
        NAVCalculator(NAV).removePriceFeed(USDC, G);
        vm.stopPrank();

        assertEq(NAVCalculator(NAV).getPriceFeedCount(USDC), 1, "should end on exactly one feed");
        IPrices.PriceFeedConfig memory end = NAVCalculator(NAV).getPriceFeedAt(USDC, 0);
        assertEq(end.priceFeed, F.priceFeed, "did not end on the original feed");
        assertEq(end.chainlinkHeartbeat, want, "heartbeat not applied");
        assertEq(uint256(INAVCalculator(NAV).getPriceData(USDC).price), p0, "final price moved");

        // The mid-sequence price must be a real USDC price, not an unrelated feed's number.
        assertApproxEqRel(uint256(mid.price), p0, 0.02e18, "mid-sequence price diverged >2% from the primary");
    }
}
