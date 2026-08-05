// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {console2} from "forge-std/Test.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {SuperTest} from "test/SuperTest.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_PriceOracleChainlink} from "test/mocks/price_oracles.sol";

import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {NotAuthorized} from "src/errors.sol";

/// @notice A Custom price feed whose `underlyingAssetSupported()` is MUTABLE. Every in-repo feed backs that getter
///         with an `immutable`; a third-party feed need not. Used to test whether the registration-time guard in
///         `PriceFeedLib._validateFeedSupportInternal` is a runtime invariant or only an admission check.
contract MutableUnderlyingFeed is ICustomPriceFeed {
    /// @notice Declared so registration's circularity gate can read it; see {INavSourcedPriceFeed}.
    /// @dev `address(0)` — no NAV dependency, so registration's circularity gate accepts it. A custom feed that
    ///      cannot answer this at all is rejected (`IPrices.CustomFeedBaseUnreadable`), which is why a mock that
    ///      gets registered has to declare it.
    address public constant BASE_ASSET = address(0);

    address private _underlying;
    uint256 private _price;
    uint8 private immutable _dec;

    constructor(address underlying_, uint256 price_, uint8 dec_) {
        _underlying = underlying_;
        _price = price_;
        _dec = dec_;
    }

    function setUnderlying(address underlying_) external {
        _underlying = underlying_;
    }

    function setPrice(uint256 price_) external {
        _price = price_;
    }

    function getLatestPrice() external view returns (uint256, bool) {
        return (_price, false);
    }

    function decimals() external view returns (uint8) {
        return _dec;
    }

    function underlyingAssetSupported() external view returns (address) {
        return _underlying;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, int256(_price), 0, block.timestamp, 0);
    }

    function governingFeedFreshness() external view returns (uint256, uint256) {
        return (block.timestamp, 3600);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICustomPriceFeed).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice A minimal UUPS implementation whose storage prefix mirrors `Prices` (slots 0..3), so it can push a
///         PriceFeedConfig straight into `_priceOracles` / `_monitorFeeds` without going through the validator.
///         The test asserts the slot assumption against the live proxy before relying on it.
contract StorageBypassImpl is UUPSUpgradeable {
    uint256 private _slot0GracePeriod;
    address private _slot1UptimeFeed;
    mapping(address => IPrices.PriceFeedConfig[]) private _slot2PriceOracles;
    mapping(address => IPrices.PriceFeedConfig[]) private _slot3MonitorFeeds;

    function forcePriceFeed(address asset, address feed, uint8 dec, uint256 heartbeat) external {
        _slot2PriceOracles[asset].push(
            IPrices.PriceFeedConfig({
                priceFeed: feed, priceType: IPrices.PriceType.Custom, decimals: dec, chainlinkHeartbeat: heartbeat
            })
        );
    }

    function forceMonitorFeed(address asset, address feed, uint8 dec, uint256 heartbeat) external {
        _slot3MonitorFeeds[asset].push(
            IPrices.PriceFeedConfig({
                priceFeed: feed, priceType: IPrices.PriceType.Custom, decimals: dec, chainlinkHeartbeat: heartbeat
            })
        );
    }

    function _authorizeUpgrade(address) internal override {}
}

/// @title PoC — registration-time `CustomFeedAssetMismatch` guard (commit 7b6298de)
/// @notice Executed proof of what the guard does and does not do, through a real NAVCalculator UUPS proxy.
contract PoC_CustomFeedAssetGuard is SuperTest {
    /// @dev ERC-1967 implementation slot.
    bytes32 private constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev Asserted against the live proxy before use, never assumed silently.
    uint256 private constant PRICE_ORACLES_SLOT = 2;
    uint256 private constant MONITOR_FEEDS_SLOT = 3;

    Mock_ERC20 internal tokenA;
    Mock_ERC20 internal tokenB;

    function setUp() public {
        setupAll();
        tokenA = new Mock_ERC20("TKA", 18);
        tokenB = new Mock_ERC20("TKB", 18);
        vm.label(address(tokenA), "TKA");
        vm.label(address(tokenB), "TKB");
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    function _mismatch(address asset, address feed, address feedAsset) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IPrices.CustomFeedAssetMismatch.selector, asset, feed, feedAsset);
    }

    function _decodeMismatch(bytes memory ret)
        internal
        pure
        returns (bytes4 sel, address asset, address feed, address feedAsset)
    {
        assembly {
            sel := mload(add(ret, 0x20))
            asset := mload(add(ret, 0x24))
            feed := mload(add(ret, 0x44))
            feedAsset := mload(add(ret, 0x64))
        }
    }

    // =========================================================================
    // PRIORITY 1 — end-to-end through the real proxy
    // =========================================================================

    /// @notice `registerAsset` (MANAGER, real proxy) rejects a Custom feed that prices a different asset, with the
    ///         exact selector AND all three revert arguments decoded from raw returndata.
    function test_P1_registerAsset_mismatch_revertsWithExactArgs() public {
        MutableUnderlyingFeed feedForB = new MutableUnderlyingFeed(address(tokenB), 2000e8, 8);

        vm.prank(navCalculatorManager);
        (bool ok, bytes memory ret) = address(nav)
            .call(
                abi.encodeCall(
                    NAVCalculator.registerAsset,
                    (address(tokenA), address(feedForB), IPrices.PriceType.Custom, type(uint256).max)
                )
            );

        assertFalse(ok, "registerAsset must revert");
        assertEq(ret.length, 4 + 96, "revert payload must be selector + 3 words");
        (bytes4 sel, address asset, address feed, address feedAsset) = _decodeMismatch(ret);
        assertEq(bytes32(sel), bytes32(IPrices.CustomFeedAssetMismatch.selector), "selector");
        assertEq(asset, address(tokenA), "arg0 asset");
        assertEq(feed, address(feedForB), "arg1 feed");
        assertEq(feedAsset, address(tokenB), "arg2 feedAsset");

        // And nothing partial was written: the asset stayed unregistered.
        assertFalse(nav.isAssetRegistered(address(tokenA)), "tokenA must not be registered");
        assertEq(nav.getPriceFeedCount(address(tokenA)), 0, "no feed written");

        console2.log("P1 registerAsset reverted CustomFeedAssetMismatch");
        console2.log("  arg0 asset    ", asset);
        console2.log("  arg1 feed     ", feed);
        console2.log("  arg2 feedAsset", feedAsset);
    }

    /// @notice `addPriceFeed` on an already-registered asset is gated by the same validator.
    function test_P1_addPriceFeed_mismatch_revertsWithExactArgs() public {
        MutableUnderlyingFeed feedForA = new MutableUnderlyingFeed(address(tokenA), 2000e8, 8);
        MutableUnderlyingFeed feedForB = new MutableUnderlyingFeed(address(tokenB), 3000e8, 8);

        vm.prank(navCalculatorManager);
        nav.registerAsset(address(tokenA), address(feedForA), IPrices.PriceType.Custom, type(uint256).max);

        vm.prank(navCalculatorManager);
        vm.expectRevert(_mismatch(address(tokenA), address(feedForB), address(tokenB)));
        nav.addPriceFeed(address(tokenA), address(feedForB), IPrices.PriceType.Custom, type(uint256).max);

        assertEq(nav.getPriceFeedCount(address(tokenA)), 1, "still exactly one feed");
    }

    /// @notice `addMonitorFeed` is gated too — and the mismatch fires with the divergence tolerance already set, so
    ///         the revert is unambiguously the new guard and not the tolerance precondition.
    function test_P1_addMonitorFeed_mismatch_revertsWithExactArgs() public {
        MutableUnderlyingFeed feedForA = new MutableUnderlyingFeed(address(tokenA), 2000e8, 8);
        MutableUnderlyingFeed monitorForB = new MutableUnderlyingFeed(address(tokenB), 2010e8, 8);

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(tokenA), address(feedForA), IPrices.PriceType.Custom, type(uint256).max);
        nav.setDivergenceTolerance(address(tokenA), 250);
        vm.stopPrank();

        vm.prank(navCalculatorManager);
        (bool ok, bytes memory ret) = address(nav)
            .call(
                abi.encodeCall(
                    NAVCalculator.addMonitorFeed,
                    (address(tokenA), address(monitorForB), IPrices.PriceType.Custom, uint256(86_400))
                )
            );

        assertFalse(ok, "addMonitorFeed must revert");
        assertEq(ret.length, 4 + 96, "revert payload must be selector + 3 words");
        (bytes4 sel, address asset, address feed, address feedAsset) = _decodeMismatch(ret);
        assertEq(bytes32(sel), bytes32(IPrices.CustomFeedAssetMismatch.selector), "selector");
        assertEq(asset, address(tokenA), "arg0 asset");
        assertEq(feed, address(monitorForB), "arg1 feed");
        assertEq(feedAsset, address(tokenB), "arg2 feedAsset");
        assertEq(nav.getMonitorFeedCount(address(tokenA)), 0, "no monitor written");

        console2.log("P1 addMonitorFeed reverted CustomFeedAssetMismatch");
        console2.log("  arg0 asset    ", asset);
        console2.log("  arg1 feed     ", feed);
        console2.log("  arg2 feedAsset", feedAsset);
    }

    /// @notice The transaction-free pre-flight view surfaces the same revert.
    function test_P1_checkPriceOracleSupport_mismatch_reverts() public {
        MutableUnderlyingFeed feedForB = new MutableUnderlyingFeed(address(tokenB), 2000e8, 8);
        vm.expectRevert(_mismatch(address(tokenA), address(feedForB), address(tokenB)));
        nav.checkPriceOracleSupport(address(tokenA), address(feedForB), IPrices.PriceType.Custom);
    }

    /// @notice Positive control: a correctly-bound Custom feed still registers and prices through the real proxy.
    function test_P1_matchingFeed_registersAndPrices() public {
        MutableUnderlyingFeed feedForA = new MutableUnderlyingFeed(address(tokenA), 2000e8, 8);

        vm.prank(navCalculatorManager);
        nav.registerAsset(address(tokenA), address(feedForA), IPrices.PriceType.Custom, type(uint256).max);

        assertTrue(nav.isAssetRegistered(address(tokenA)), "registered");
        assertEq(nav.getPriceFeedCount(address(tokenA)), 1, "one feed");
        (int256 price,, bool stale,) = nav.latestPrice(address(tokenA));
        assertEq(price, 2000e8, "price");
        assertFalse(stale, "not stale");
    }

    // =========================================================================
    // PRIORITY 2 — mutable-underlying attack
    // =========================================================================

    /// @notice Register a hostile feed correctly bound, then flip its underlying. The flip is INERT on every read
    ///         path: latestPrice, getPriceData and getAccountNav are identical before and after.
    function test_P2_mutableUnderlyingFlip_isInertOnReadPath() public {
        MutableUnderlyingFeed hostile = new MutableUnderlyingFeed(address(tokenA), 2000e8, 8);

        vm.prank(navCalculatorManager);
        nav.registerAsset(address(tokenA), address(hostile), IPrices.PriceType.Custom, type(uint256).max);
        tokenA.mint(safe, 3e18);

        (int256 priceBefore, uint8 decBefore, bool staleBefore, bool irregBefore) = nav.latestPrice(address(tokenA));
        INAVCalculator.PriceFeedData memory pdBefore = nav.getPriceData(address(tokenA));
        int256 navBefore = nav.getAccountNav(safe, address(0)).value;

        // FLIP: the feed now claims to price tokenB while still registered as tokenA's primary.
        hostile.setUnderlying(address(tokenB));

        // The flip is real — re-registration of the same feed for tokenA would now be rejected.
        vm.expectRevert(_mismatch(address(tokenA), address(hostile), address(tokenB)));
        nav.checkPriceOracleSupport(address(tokenA), address(hostile), IPrices.PriceType.Custom);

        (int256 priceAfter, uint8 decAfter, bool staleAfter, bool irregAfter) = nav.latestPrice(address(tokenA));
        INAVCalculator.PriceFeedData memory pdAfter = nav.getPriceData(address(tokenA));
        int256 navAfter = nav.getAccountNav(safe, address(0)).value;

        assertEq(priceAfter, priceBefore, "latestPrice unchanged by flip");
        assertEq(uint256(decAfter), uint256(decBefore), "decimals unchanged");
        assertEq(staleAfter, staleBefore, "stale unchanged");
        assertEq(irregAfter, irregBefore, "irregular unchanged");
        assertEq(keccak256(abi.encode(pdAfter)), keccak256(abi.encode(pdBefore)), "getPriceData byte-identical");
        assertEq(navAfter, navBefore, "getAccountNav unchanged by flip");

        console2.log("P2 NAV before flip", navBefore);
        console2.log("P2 NAV after  flip", navAfter);
    }

    /// @notice The lever a hostile feed actually has is the PRICE, which the guard never touched. Same feed, no flip
    ///         needed: moving the reported price moves the NAV by the full amount, binding intact throughout.
    function test_P2_hostileFeedPriceIsTheRealLever() public {
        MutableUnderlyingFeed hostile = new MutableUnderlyingFeed(address(tokenA), 2000e8, 8);

        vm.prank(navCalculatorManager);
        nav.registerAsset(address(tokenA), address(hostile), IPrices.PriceType.Custom, type(uint256).max);
        tokenA.mint(safe, 3e18);

        int256 navBefore = nav.getAccountNav(safe, address(0)).value;
        hostile.setPrice(2_000_000e8); // 1000x; underlying binding untouched and still correct
        int256 navAfter = nav.getAccountNav(safe, address(0)).value;

        // The guard passes for this feed at every moment; the NAV still moves by 3 * (2_000_000 - 2000) USD.
        nav.checkPriceOracleSupport(address(tokenA), address(hostile), IPrices.PriceType.Custom);
        assertEq(navBefore, int256(3) * int256(2000e8), "honest NAV = 3 x 2000 USD");
        assertEq(navAfter, int256(3) * int256(2_000_000e8), "lying NAV = 3 x 2_000_000 USD");
        assertGt(navAfter, navBefore, "price lie moves NAV with the binding intact");

        console2.log("P2 NAV with honest price", navBefore);
        console2.log("P2 NAV with lying price ", navAfter);
    }

    /// @notice The 1:1 contract-to-asset property the guard advertises is NOT enforced against a mutable feed: by
    ///         flipping between two registrations, one feed address becomes the primary for TWO assets.
    function test_P2_flipLetsOneFeedBackTwoAssets() public {
        MutableUnderlyingFeed hostile = new MutableUnderlyingFeed(address(tokenA), 2000e8, 8);

        vm.prank(navCalculatorManager);
        nav.registerAsset(address(tokenA), address(hostile), IPrices.PriceType.Custom, type(uint256).max);

        hostile.setUnderlying(address(tokenB));
        vm.prank(navCalculatorManager);
        nav.registerAsset(address(tokenB), address(hostile), IPrices.PriceType.Custom, type(uint256).max);

        assertEq(nav.getPriceFeedAt(address(tokenA), 0).priceFeed, address(hostile), "primary of A");
        assertEq(nav.getPriceFeedAt(address(tokenB), 0).priceFeed, address(hostile), "primary of B");
        (int256 pa,,,) = nav.latestPrice(address(tokenA));
        (int256 pb,,,) = nav.latestPrice(address(tokenB));
        assertEq(pa, pb, "both assets priced by the same feed");
    }

    // =========================================================================
    // PRIORITY 3 — removability of an already-registered mismatch
    // =========================================================================

    /// @notice A primary that has gone mismatched is still removable when a second feed exists.
    function test_P3_flippedPrimary_removableWhenSecondFeedExists() public {
        MutableUnderlyingFeed hostile = new MutableUnderlyingFeed(address(tokenA), 2000e8, 8);
        Mock_PriceOracleChainlink backup = new Mock_PriceOracleChainlink("TKA", 2000e8, 8);

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(tokenA), address(hostile), IPrices.PriceType.Custom, type(uint256).max);
        nav.addPriceFeed(address(tokenA), address(backup), IPrices.PriceType.Chainlink, 86_400);
        vm.stopPrank();

        hostile.setUnderlying(address(0xdead));
        vm.expectRevert(_mismatch(address(tokenA), address(hostile), address(0xdead)));
        nav.checkPriceOracleSupport(address(tokenA), address(hostile), IPrices.PriceType.Custom);

        vm.prank(navCalculatorManager);
        nav.removePriceFeed(address(tokenA), address(hostile));
        assertEq(nav.getPriceFeedCount(address(tokenA)), 1, "bad feed removed");
        assertEq(nav.getPriceFeedAt(address(tokenA), 0).priceFeed, address(backup), "backup survives");
    }

    /// @notice The operational recovery for a SOLE mismatched primary: add a good feed, then remove the bad one.
    ///         (`CannotRemoveLastFeed` is pre-existing behaviour, unrelated to the guard.)
    function test_P3_flippedSolePrimary_replaceThenRemove() public {
        MutableUnderlyingFeed hostile = new MutableUnderlyingFeed(address(tokenA), 2000e8, 8);

        vm.prank(navCalculatorManager);
        nav.registerAsset(address(tokenA), address(hostile), IPrices.PriceType.Custom, type(uint256).max);
        hostile.setUnderlying(address(0xdead));

        vm.prank(navCalculatorManager);
        vm.expectRevert(abi.encodeWithSelector(IPrices.CannotRemoveLastFeed.selector, address(tokenA)));
        nav.removePriceFeed(address(tokenA), address(hostile));

        // A correctly-bound replacement still passes the guard, so recovery is never blocked.
        Mock_PriceOracleChainlink good = new Mock_PriceOracleChainlink("TKA", 2000e8, 8);
        vm.startPrank(navCalculatorManager);
        nav.addPriceFeed(address(tokenA), address(good), IPrices.PriceType.Chainlink, 86_400);
        nav.removePriceFeed(address(tokenA), address(hostile));
        vm.stopPrank();

        assertEq(nav.getPriceFeedCount(address(tokenA)), 1, "one feed left");
        assertEq(nav.getPriceFeedAt(address(tokenA), 0).priceFeed, address(good), "good feed is primary");
    }

    /// @notice Index-based primary removal is likewise unguarded after a flip.
    function test_P3_flippedPrimary_removableByIndex() public {
        MutableUnderlyingFeed hostile = new MutableUnderlyingFeed(address(tokenA), 2000e8, 8);
        Mock_PriceOracleChainlink backup = new Mock_PriceOracleChainlink("TKA", 2000e8, 8);

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(tokenA), address(hostile), IPrices.PriceType.Custom, type(uint256).max);
        nav.addPriceFeed(address(tokenA), address(backup), IPrices.PriceType.Chainlink, 86_400);
        vm.stopPrank();

        hostile.setUnderlying(address(0xdead));

        vm.prank(navCalculatorManager);
        nav.removePriceFeedAt(address(tokenA), 0);
        assertEq(nav.getPriceFeedCount(address(tokenA)), 1, "removed by index");
        assertEq(nav.getPriceFeedAt(address(tokenA), 0).priceFeed, address(backup), "backup survives");
    }

    /// @notice A monitor feed that has gone mismatched is removable by address and by index.
    function test_P3_flippedMonitor_removable() public {
        MutableUnderlyingFeed primary = new MutableUnderlyingFeed(address(tokenA), 2000e8, 8);
        MutableUnderlyingFeed monitor1 = new MutableUnderlyingFeed(address(tokenA), 2001e8, 8);
        MutableUnderlyingFeed monitor2 = new MutableUnderlyingFeed(address(tokenA), 2002e8, 8);

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(tokenA), address(primary), IPrices.PriceType.Custom, type(uint256).max);
        nav.setDivergenceTolerance(address(tokenA), 250);
        nav.addMonitorFeed(address(tokenA), address(monitor1), IPrices.PriceType.Custom, 86_400);
        nav.addMonitorFeed(address(tokenA), address(monitor2), IPrices.PriceType.Custom, 86_400);
        vm.stopPrank();

        monitor1.setUnderlying(address(0xdead));
        monitor2.setUnderlying(address(0xdead));
        assertEq(nav.getMonitorFeedCount(address(tokenA)), 2, "two monitors");

        vm.startPrank(navCalculatorManager);
        nav.removeMonitorFeed(address(tokenA), address(monitor1));
        nav.removeMonitorFeedAt(address(tokenA), 0);
        vm.stopPrank();

        assertEq(nav.getMonitorFeedCount(address(tokenA)), 0, "all monitors removable after flip");
    }

    /// @notice Full teardown still works with every feed mismatched, and the asset re-registers cleanly.
    function test_P3_unregisterAsset_succeedsWithFlippedFeeds() public {
        MutableUnderlyingFeed primary = new MutableUnderlyingFeed(address(tokenA), 2000e8, 8);
        MutableUnderlyingFeed monitor = new MutableUnderlyingFeed(address(tokenA), 2001e8, 8);

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(tokenA), address(primary), IPrices.PriceType.Custom, type(uint256).max);
        nav.setDivergenceTolerance(address(tokenA), 250);
        nav.addMonitorFeed(address(tokenA), address(monitor), IPrices.PriceType.Custom, 86_400);
        vm.stopPrank();

        primary.setUnderlying(address(0xdead));
        monitor.setUnderlying(address(0xdead));

        vm.prank(navCalculatorManager);
        nav.unregisterAsset(address(tokenA));

        assertFalse(nav.isAssetRegistered(address(tokenA)), "unregistered");
        assertEq(nav.getPriceFeedCount(address(tokenA)), 0, "feeds cleared");
        assertEq(nav.getMonitorFeedCount(address(tokenA)), 0, "monitors cleared");

        MutableUnderlyingFeed clean = new MutableUnderlyingFeed(address(tokenA), 2000e8, 8);
        vm.prank(navCalculatorManager);
        nav.registerAsset(address(tokenA), address(clean), IPrices.PriceType.Custom, type(uint256).max);
        assertEq(nav.getPriceFeedCount(address(tokenA)), 1, "re-registered");
    }

    // =========================================================================
    // PRIORITY 4 — bypass hunt
    // =========================================================================

    /// @notice `initialize` pre-registers the native sentinel but writes NO price or monitor feed, so it is not a
    ///         validator bypass; and it cannot be re-run.
    function test_P4_initializeWritesNoFeedsAndCannotBeReRun() public {
        NAVCalculator fresh = setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        assertTrue(fresh.isAssetRegistered(fresh.NATIVE_ADDRESS()), "native pre-registered");
        assertEq(fresh.getPriceFeedCount(fresh.NATIVE_ADDRESS()), 0, "initialize writes no price feed");
        assertEq(fresh.getMonitorFeedCount(fresh.NATIVE_ADDRESS()), 0, "initialize writes no monitor feed");

        vm.expectRevert(); // InvalidInitialization
        fresh.initialize(admin, address(sequencerUptimeFeed), "ETH");
    }

    /// @notice Upgrade authority is DEFAULT_ADMIN only — strictly above the MANAGER role the guard gates.
    function test_P4_upgradeAuthorityIsAdminOnly() public {
        address newImpl = address(new NAVCalculator());

        vm.prank(navCalculatorManager);
        vm.expectRevert(NotAuthorized.selector);
        nav.upgradeToAndCall(newImpl, "");

        vm.prank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.upgradeToAndCall(newImpl, "");

        vm.prank(admin);
        nav.upgradeToAndCall(newImpl, "");
        assertEq(address(uint160(uint256(vm.load(address(nav), IMPL_SLOT)))), newImpl, "admin can upgrade");
    }

    /// @notice A UUPS upgrade DOES bypass the guard — an admin-chosen implementation writes `_priceOracles` and
    ///         `_monitorFeeds` directly. Executed end-to-end: the mismatched feed lands in storage and then prices
    ///         the asset once the honest primary is removed.
    function test_P4_uupsUpgradeBypassesTheGuard() public {
        MutableUnderlyingFeed feedForA = new MutableUnderlyingFeed(address(tokenA), 2000e8, 8);
        MutableUnderlyingFeed feedForB = new MutableUnderlyingFeed(address(tokenB), 3000e8, 8);

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(tokenA), address(feedForA), IPrices.PriceType.Custom, type(uint256).max);
        nav.registerAsset(address(tokenB), address(feedForB), IPrices.PriceType.Custom, type(uint256).max);
        nav.setDivergenceTolerance(address(tokenB), 250);
        vm.stopPrank();

        // Verify the storage-slot assumption against the LIVE proxy instead of trusting it.
        assertEq(
            uint256(vm.load(address(nav), keccak256(abi.encode(address(usdc), PRICE_ORACLES_SLOT)))),
            1,
            "slot 2 is _priceOracles (usdc)"
        );
        assertEq(
            uint256(vm.load(address(nav), keccak256(abi.encode(address(tokenB), PRICE_ORACLES_SLOT)))),
            1,
            "slot 2 is _priceOracles (tokenB)"
        );
        assertEq(
            uint256(vm.load(address(nav), keccak256(abi.encode(address(tokenB), MONITOR_FEEDS_SLOT)))),
            0,
            "slot 3 is _monitorFeeds"
        );

        address originalImpl = address(uint160(uint256(vm.load(address(nav), IMPL_SLOT))));
        address bypassImpl = address(new StorageBypassImpl());

        vm.prank(admin);
        nav.upgradeToAndCall(bypassImpl, "");

        // feedForA prices tokenA. Attach it to tokenB anyway — impossible via addPriceFeed / addMonitorFeed.
        StorageBypassImpl(address(nav)).forcePriceFeed(address(tokenB), address(feedForA), 8, type(uint256).max);
        StorageBypassImpl(address(nav)).forceMonitorFeed(address(tokenB), address(feedForA), 8, 86_400);

        StorageBypassImpl(address(nav)).upgradeToAndCall(originalImpl, "");

        assertEq(nav.getPriceFeedCount(address(tokenB)), 2, "mismatched feed landed in _priceOracles");
        assertEq(nav.getPriceFeedAt(address(tokenB), 1).priceFeed, address(feedForA), "the mismatched feed");
        assertEq(nav.getMonitorFeedCount(address(tokenB)), 1, "mismatched monitor landed in _monitorFeeds");
        assertEq(
            ICustomPriceFeed(address(feedForA)).underlyingAssetSupported(),
            address(tokenA),
            "feed prices tokenA, registered for tokenB"
        );

        // The validator would have rejected exactly this pairing.
        vm.expectRevert(_mismatch(address(tokenB), address(feedForA), address(tokenA)));
        nav.checkPriceOracleSupport(address(tokenB), address(feedForA), IPrices.PriceType.Custom);

        // Drop the honest primary (swap-and-pop) so the forced entry is unambiguously the one that prices tokenB.
        vm.prank(navCalculatorManager);
        nav.removePriceFeed(address(tokenB), address(feedForB));
        assertEq(nav.getPriceFeedCount(address(tokenB)), 1, "only the forced feed remains");

        INAVCalculator.PriceFeedData memory pd = nav.getPriceData(address(tokenB));
        assertEq(pd.priceFeed, address(feedForA), "forced feed is the primary");
        assertEq(pd.price, 2000e8, "tokenB priced at tokenA's price");

        console2.log("P4 tokenB priced by a feed bound to tokenA:", uint256(int256(pd.price)));
    }
}
