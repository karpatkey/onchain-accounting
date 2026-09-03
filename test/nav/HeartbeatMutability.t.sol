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

    /// @notice A no-op re-registration still reverts, preserving the double-registration guard.
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
}
