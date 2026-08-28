// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @notice Read-only pass-through to an existing AggregatorV3 feed.
/// @dev The temporary second feed for the realignment swap. It reports the SAME round data as the feed
///      being realigned, so while it is briefly the asset's only registered feed the asset is priced from
///      exactly the source it was already priced from — not from a merely-correlated one.
///      Deliberately NOT an ICustomPriceFeed: registration rejects a Chainlink-typed feed that answers
///      `supportsInterface(ICustomPriceFeed)`, and forwarding `decimals()` is what satisfies the
///      decimals-match check against the incumbent feed.
contract AggregatorMirror {
    AggregatorV3Interface public immutable SOURCE;

    constructor(address source) {
        SOURCE = AggregatorV3Interface(source);
    }

    function decimals() external view returns (uint8) {
        return SOURCE.decimals();
    }

    function description() external view returns (string memory) {
        return SOURCE.description();
    }

    function version() external view returns (uint256) {
        return SOURCE.version();
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return SOURCE.latestRoundData();
    }
}

/// @title HeartbeatRealignViaMirrorForkTest
/// @author KPK
/// @notice Proves a registered price-feed heartbeat CAN be realigned with no contract upgrade, for assets
///         that have no second price source of their own.
/// @dev The heartbeat is immutable through the normal API (see RealignHeartbeats.fork.t.sol), and
///      NAVCalculator has ~101 bytes of EIP-170 margin, so adding a setter is not available. The way
///      through is to stop the asset being single-feed for the duration of the swap:
///
///        1. add    mirror(F)  at the target heartbeat   -> 2 feeds, primary still F
///        2. remove F                                    -> 1 feed, priced by the mirror == F's own data
///        3. add    F          at the target heartbeat   -> 2 feeds
///        4. remove mirror                               -> 1 feed: F, at the target heartbeat
///
///      Registration does not verify that a Chainlink-typed feed actually prices the asset it is
///      registered for, which is why the mirror must be pinned to the incumbent feed rather than being any
///      healthy aggregator: an arbitrary one would price the asset WRONGLY and report it FRESH.
contract HeartbeatRealignViaMirrorForkTest is Test, TestEnvConfigurator {
    uint256 constant FORK_BLOCK = 25_854_566;
    address constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    address constant MANAGER = 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72;
    address constant AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;

    function setUp() public {
        createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
    }

    function test_realignsHeartbeat_onAnAssetWithNoSecondSource() public {
        assertEq(NAVCalculator(NAV).getMonitorFeedCount(AAVE), 0, "AAVE is the no-second-source case");
        IPrices.PriceFeedConfig memory F = NAVCalculator(NAV).getPriceFeedAt(AAVE, 0);
        uint256 want = 3600;
        assertTrue(F.chainlinkHeartbeat != want, "nothing to realign");

        INAVCalculator.PriceFeedData memory before_ = INAVCalculator(NAV).getPriceData(AAVE);
        address mirror = address(new AggregatorMirror(F.priceFeed));

        vm.startPrank(MANAGER);
        NAVCalculator(NAV).addPriceFeed(AAVE, mirror, F.priceType, want);
        _assertPricedIdentically(before_, "after step 1 (mirror added)");

        NAVCalculator(NAV).removePriceFeed(AAVE, F.priceFeed);
        _assertPricedIdentically(before_, "MID-SEQUENCE (mirror is the only feed)");

        NAVCalculator(NAV).addPriceFeed(AAVE, F.priceFeed, F.priceType, want);
        _assertPricedIdentically(before_, "after step 3 (original re-added)");

        NAVCalculator(NAV).removePriceFeed(AAVE, mirror);
        vm.stopPrank();

        assertEq(NAVCalculator(NAV).getPriceFeedCount(AAVE), 1, "must end on exactly one feed");
        IPrices.PriceFeedConfig memory end = NAVCalculator(NAV).getPriceFeedAt(AAVE, 0);
        assertEq(end.priceFeed, F.priceFeed, "must end on the ORIGINAL feed, not the mirror");
        assertEq(uint256(end.priceType), uint256(F.priceType), "price type changed");
        assertEq(end.decimals, F.decimals, "decimals changed");
        assertEq(end.chainlinkHeartbeat, want, "heartbeat not applied");
        _assertPricedIdentically(before_, "final");
        console2.log("AAVE heartbeat %d -> %d, price unchanged throughout", F.chainlinkHeartbeat, want);
    }

    /// @dev The price must be bit-identical at every step, not merely close: the mirror forwards the same
    ///      round from the same aggregator, so any difference at all means the swap changed the price
    ///      source, which is the failure this sequence must not have.
    function _assertPricedIdentically(INAVCalculator.PriceFeedData memory before_, string memory at) internal view {
        INAVCalculator.PriceFeedData memory now_ = INAVCalculator(NAV).getPriceData(AAVE);
        assertEq(now_.price, before_.price, string.concat("price moved: ", at));
        assertEq(now_.stale, before_.stale, string.concat("staleness verdict moved: ", at));
        assertFalse(now_.stale, string.concat("asset went stale: ", at));
    }

    /// @notice A mirror of the WRONG feed is accepted by registration — the reason the mirror must be pinned.
    /// @dev Guards the one-line mistake that would turn this procedure into a silent mispricing: registration
    ///      validates that a Chainlink feed is live, never that it prices this asset. Asserted so the
    ///      constraint is enforced by a test rather than by the runbook prose.
    ///      The borrowed feed is registered at 86400, not at the realignment's target heartbeat: at a short
    ///      heartbeat this reads STALE, and the staleness — an accident of the number chosen, not a
    ///      protection — hides the mispricing and makes the test pass for the wrong reason.
    function test_registrationDoesNotCheckTheFeedPricesTheAsset() public {
        address usdcFeed = NAVCalculator(NAV).getPriceFeedAt(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0).priceFeed;
        uint256 aavePrice = uint256(INAVCalculator(NAV).getPriceData(AAVE).price);

        // Deploy BEFORE the prank: a `new` inside the argument list consumes it, and the addPriceFeed
        // call then arrives unpranked and reverts NotAuthorized.
        address wrongMirror = address(new AggregatorMirror(usdcFeed));
        vm.prank(MANAGER);
        NAVCalculator(NAV).addPriceFeed(AAVE, wrongMirror, IPrices.PriceType.Chainlink, 86_400);

        IPrices.PriceFeedConfig memory F = NAVCalculator(NAV).getPriceFeedAt(AAVE, 0);
        vm.prank(MANAGER);
        NAVCalculator(NAV).removePriceFeed(AAVE, F.priceFeed);

        INAVCalculator.PriceFeedData memory bad = INAVCalculator(NAV).getPriceData(AAVE);
        assertFalse(bad.stale, "the wrong price is reported as FRESH -- no flag protects against this");
        assertTrue(uint256(bad.price) != aavePrice, "expected AAVE to be mispriced by USDC's feed");
        console2.log("AAVE would read %d instead of %d, stale=false", uint256(bad.price), aavePrice);
    }
}
