// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {console2} from "forge-std/Test.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {SuperTest} from "test/SuperTest.sol";
import {Mock_ERC20, Mock_ERC4626} from "test/mocks/tokens.sol";
import {Mock_PriceOracleChainlink} from "test/mocks/price_oracles.sol";

import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {INavSourcedPriceFeed} from "src/prices/INavSourcedPriceFeed.sol";

// The REAL feed types. Every `Custom` feed in this repo roots in one of four places — `BaseCustomPriceFeed`,
// `ERC4626VaultRatePriceFeed`, `TwoFeedChainlinkPriceFeed`, or a standalone — and three of those are `abstract`, so
// each root is represented here by a concrete in-repo subclass. These are imported so
// {CustomFeedBaseCircularityTest-test_realFeedTypesAnswerBaseAsset} probes the shipped contracts rather than a mock.
import {wstETH_CustomPriceFeed} from "src/prices/protocols/wstETH_CustomPriceFeed.sol";
import {sUSDe_CustomPriceFeed} from "src/prices/protocols/sUSDe_CustomPriceFeed.sol";
import {stETH_CustomPriceFeed} from "src/prices/protocols/stETH_CustomPriceFeed.sol";
import {ankrETH_CustomPriceFeed} from "src/prices/protocols/ankrETH_CustomPriceFeed.sol";
import {ETHPlus_CustomPriceFeed} from "src/prices/protocols/ETHPlus_CustomPriceFeed.sol";

// =============================================================================
// Feed fixtures
// =============================================================================

/// @notice A genuinely NAV-sourced custom feed — the shape every `rate × base/USD` feed in `src/prices/` has. It
///         reads `base/USD` back out of the NAV it is registered on, exactly as {NavBaseUsdLib} does, so pointing
///         `BASE_ASSET` at its own underlying makes it re-enter the NAV's selector for the same asset.
/// @dev Reads via `getPriceDataNoDivergence`, the selector {NavBaseUsdLib} actually calls.
contract NavSourcedFeed is ICustomPriceFeed {
    address public immutable UNDERLYING;
    address public immutable BASE_ASSET;
    INAVCalculator public immutable NAV;
    uint256 private immutable _rate18;

    constructor(address underlying_, address nav_, address baseAsset_, uint256 rate18_) {
        UNDERLYING = underlying_;
        NAV = INAVCalculator(nav_);
        BASE_ASSET = baseAsset_;
        _rate18 = rate18_;
    }

    /// @dev `rate × base/USD`, with base/USD read from the NAV — the recursion carrier.
    function _compute() private view returns (uint256 price, bool stale) {
        try NAV.getPriceDataNoDivergence(BASE_ASSET) returns (INAVCalculator.PriceFeedData memory pd) {
            if (pd.stale || pd.price <= 0) return (0, true);
            return ((uint256(pd.price) * _rate18) / 1e18, false);
        } catch {
            return (0, true);
        }
    }

    function getLatestPrice() external view returns (uint256, bool) {
        return _compute();
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function underlyingAssetSupported() external view returns (address) {
        return UNDERLYING;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        (uint256 p, bool s) = _compute();
        return (0, s ? int256(0) : int256(p), 0, block.timestamp, 0);
    }

    function governingFeedFreshness() external view returns (uint256, uint256) {
        return (block.timestamp, 3600);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICustomPriceFeed).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice A custom feed that passes `supportsInterface(ICustomPriceFeed)` but has NO `BASE_ASSET()` at all — the
///         shape of every third-party feed written against {ICustomPriceFeed} alone, and of every in-repo feed
///         before this change. Registration must REJECT it rather than assume its base is harmless.
contract NoBaseAssetFeed is ICustomPriceFeed {
    address private immutable _underlying;

    constructor(address underlying_) {
        _underlying = underlying_;
    }

    function getLatestPrice() external pure returns (uint256, bool) {
        return (2000e8, false);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function underlyingAssetSupported() external view returns (address) {
        return _underlying;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 2000e8, 0, block.timestamp, 0);
    }

    function governingFeedFreshness() external view returns (uint256, uint256) {
        return (block.timestamp, 3600);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICustomPriceFeed).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice A feed whose `BASE_ASSET()` answers with a malformed word — either a short return or a full word with
///         dirty upper bits (not a valid address). `abi.decode(ret, (address))` would revert anonymously on the
///         latter; the guard range-checks by hand so the MANAGER gets a named error instead.
contract MalformedBaseAssetFeed is NoBaseAssetFeed {
    /// @dev 0 = short return (8 bytes), 1 = 32-byte word with dirty upper 96 bits.
    uint256 private immutable _mode;

    constructor(address underlying_, uint256 mode_) NoBaseAssetFeed(underlying_) {
        _mode = mode_;
    }

    /// @dev Hand-rolled so the return data can be malformed; a typed Solidity return could not express either shape.
    fallback() external {
        require(msg.sig == INavSourcedPriceFeed.BASE_ASSET.selector, "unexpected selector");
        uint256 mode = _mode;
        assembly {
            switch mode
            case 0 {
                mstore(0, 0)
                return(0, 8) // 8 bytes — not a whole ABI word
            }
            default {
                // upper 96 bits set → not a clean address
                mstore(0, not(0))
                return(0, 32)
            }
        }
    }
}

/// @notice Minimal UUPS implementation whose storage prefix mirrors `Prices` (slots 0..3), used to push a
///         PriceFeedConfig straight into `_priceOracles` WITHOUT going through the validator — the only way to
///         observe what the guard prevents, since the guard itself blocks the normal path. The slot assumption is
///         asserted against the live proxy before it is relied on.
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

    function _authorizeUpgrade(address) internal override {}
}

// =============================================================================
// Tests
// =============================================================================

/// @title Registration-time circularity gate for NAV-sourced Custom price feeds
/// @notice A NAV-sourced custom feed prices its asset as `rate × base/USD` and reads that `base/USD` back out of the
///         same NAV (ADR 0019). The invariant that keeps this safe — `BASE_ASSET` must be priced by DIRECT feeds,
///         never by a feed that calls back — was documented in {NavBaseUsdLib} and held by CONVENTION only.
///         `PriceFeedLib._validateFeedNotCircular` now enforces it where registration happens.
/// @dev The first test is the vulnerability proof and does not exercise the guard at all: it forces a circular feed
///      into storage past the validator and measures what reading that asset then costs. The rest exercise the gate.
contract CustomFeedBaseCircularityTest is SuperTest {
    /// @dev ERC-1967 implementation slot.
    bytes32 private constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev Asserted against the live proxy in {test_vulnerability_...} before the bypass relies on it.
    uint256 private constant PRICE_ORACLES_SLOT = 2;

    /// @dev The derived asset. `dai` (from {SuperTest}, priced $1.00 by a DIRECT Chainlink feed) plays the base
    ///      asset — the configuration the circularity invariant requires of a base.
    Mock_ERC20 internal lst;

    function setUp() public {
        setupAll();
        lst = new Mock_ERC20("LST", 18);
        vm.label(address(lst), "LST");
    }

    function _circular(address asset, address feed) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IPrices.CustomFeedBaseCircular.selector, asset, feed);
    }

    function _unreadable(address asset, address feed) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IPrices.CustomFeedBaseUnreadable.selector, asset, feed);
    }

    // -------------------------------------------------------------------------
    // The vulnerability, demonstrated
    // -------------------------------------------------------------------------

    /// @notice Proves the failure the gate exists to prevent is REAL, by forcing a circular feed past the validator
    ///         through raw storage and then reading the asset it poisons.
    /// @dev WETH keeps its healthy Chainlink feed throughout, so this is the issue's exact scenario: a redundant
    ///      NAV-sourced Custom feed added for DAI whose own `BASE_ASSET` is DAI. Reading DAI then re-enters the
    ///      selector for WETH through that feed, over and over. `_selectFeedCore` wraps each custom-feed call in a
    ///      bare `try`/`catch` with NO gas cap, so the recursion consumes 63/64 of whatever gas the caller supplied
    ///      before the depth/gas failure is swallowed and the healthy Chainlink price is returned anyway. The damage
    ///      is therefore invisible in the RESULT and visible only in the COST — which is what this measures.
    function test_vulnerability_circularFeedForcedIntoStorage_burnsCallerGas() public {
        // Baseline: WETH priced by the direct feed alone.
        (bool okBefore, uint256 gasBefore) = _measureGetPriceData(address(dai), 8_000_000);
        assertTrue(okBefore, "control read must succeed");

        NavSourcedFeed circular = new NavSourcedFeed(address(dai), address(nav), address(dai), 1e18);

        // The normal path refuses it — that IS the fix, so go around it to observe the pre-fix behaviour.
        vm.prank(navCalculatorManager);
        vm.expectRevert(_circular(address(dai), address(circular)));
        nav.addOrModifyPriceFeed(address(dai), address(circular), IPrices.PriceType.Custom, type(uint256).max);

        // Confirm the slot assumption against the live proxy rather than trusting it.
        assertEq(
            uint256(vm.load(address(nav), keccak256(abi.encode(address(dai), PRICE_ORACLES_SLOT)))),
            1,
            "slot 2 must be _priceOracles (DAI has exactly one feed)"
        );

        address originalImpl = address(uint160(uint256(vm.load(address(nav), IMPL_SLOT))));
        address bypassImpl = address(new StorageBypassImpl());
        vm.startPrank(admin);
        nav.upgradeToAndCall(bypassImpl, "");
        StorageBypassImpl(address(nav)).forcePriceFeed(address(dai), address(circular), 8, type(uint256).max);
        StorageBypassImpl(address(nav)).upgradeToAndCall(originalImpl, "");
        vm.stopPrank();
        assertEq(nav.getPriceFeedCount(address(dai)), 2, "circular feed is now registered alongside the healthy one");

        (bool okAfter, uint256 gasAfter) = _measureGetPriceData(address(dai), 8_000_000);

        console2.log("control read  gas:", gasBefore, "ok:", okBefore);
        console2.log("poisoned read gas:", gasAfter, "ok:", okAfter);

        // The read is now catastrophically more expensive at the same gas budget — either it consumed an order of
        // magnitude more gas, or it ran out entirely where the control comfortably succeeded.
        assertTrue(
            !okAfter || gasAfter > 10 * gasBefore,
            "circular feed must either exhaust the budget or cost >10x the control read"
        );
    }

    /// @dev Calls `getPriceData` with a bounded gas budget and reports whether it succeeded and what it consumed.
    function _measureGetPriceData(address asset, uint256 gasBudget) internal view returns (bool ok, uint256 used) {
        bytes memory cd = abi.encodeCall(INAVCalculator.getPriceData, (asset));
        uint256 start = gasleft();
        (ok,) = address(nav).staticcall{gas: gasBudget}(cd);
        used = start - gasleft();
    }

    // -------------------------------------------------------------------------
    // The gate — every registration path
    // -------------------------------------------------------------------------

    /// @notice `addPriceFeed` rejects a NAV-sourced Custom feed whose base is the asset being registered.
    function test_RevertIf_addPriceFeed_feedBasedOnTheAssetItPrices() public {
        NavSourcedFeed circular = new NavSourcedFeed(address(dai), address(nav), address(dai), 1e18);
        vm.prank(navCalculatorManager);
        vm.expectRevert(_circular(address(dai), address(circular)));
        nav.addOrModifyPriceFeed(address(dai), address(circular), IPrices.PriceType.Custom, type(uint256).max);
        assertEq(nav.getPriceFeedCount(address(dai)), 1, "nothing written");
    }

    /// @notice `registerAsset` — the path `06_Configure.s.sol` drives from an EOA — rejects it too.
    function test_RevertIf_registerAsset_feedBasedOnTheAssetItPrices() public {
        NavSourcedFeed circular = new NavSourcedFeed(address(lst), address(nav), address(lst), 1e18);
        vm.prank(navCalculatorManager);
        vm.expectRevert(_circular(address(lst), address(circular)));
        nav.registerAsset(address(lst), address(circular), IPrices.PriceType.Custom, type(uint256).max);
        assertFalse(nav.isAssetRegistered(address(lst)), "asset must not be registered");
    }

    /// @notice `addMonitorFeed` shares the validator, so a circular monitor is rejected as well. The divergence
    ///         tolerance is set first so the revert is unambiguously the circularity gate, not the tolerance gate.
    function test_RevertIf_addMonitorFeed_feedBasedOnTheAssetItPrices() public {
        NavSourcedFeed circular = new NavSourcedFeed(address(dai), address(nav), address(dai), 1e18);
        vm.startPrank(navCalculatorManager);
        nav.setDivergenceTolerance(address(dai), 250);
        vm.expectRevert(_circular(address(dai), address(circular)));
        nav.addMonitorFeed(address(dai), address(circular), IPrices.PriceType.Custom, 86_400);
        vm.stopPrank();
        assertEq(nav.getMonitorFeedCount(address(dai)), 0, "no monitor written");
    }

    /// @notice The transaction-free pre-flight view surfaces the same rejection, so a config can be checked before
    ///         it is broadcast.
    function test_RevertIf_checkPriceOracleSupport_feedBasedOnTheAssetItPrices() public {
        NavSourcedFeed circular = new NavSourcedFeed(address(dai), address(nav), address(dai), 1e18);
        vm.expectRevert(_circular(address(dai), address(circular)));
        nav.checkPriceOracleSupport(address(dai), address(circular), IPrices.PriceType.Custom);
    }

    // -------------------------------------------------------------------------
    // Unreadable means reject
    // -------------------------------------------------------------------------

    /// @notice A Custom feed that does not implement `BASE_ASSET()` is rejected. "Could not read the base" must not
    ///         become "the base is fine" when the failure being closed is unbounded recursion.
    function test_RevertIf_registerAsset_feedCannotAnswerBaseAsset() public {
        NoBaseAssetFeed silent = new NoBaseAssetFeed(address(lst));
        vm.prank(navCalculatorManager);
        vm.expectRevert(_unreadable(address(lst), address(silent)));
        nav.registerAsset(address(lst), address(silent), IPrices.PriceType.Custom, type(uint256).max);
    }

    /// @notice A `BASE_ASSET()` that returns less than one ABI word is unreadable, not empty-and-therefore-fine.
    function test_RevertIf_registerAsset_baseAssetReturnsShortWord() public {
        MalformedBaseAssetFeed short = new MalformedBaseAssetFeed(address(lst), 0);
        vm.prank(navCalculatorManager);
        vm.expectRevert(_unreadable(address(lst), address(short)));
        nav.registerAsset(address(lst), address(short), IPrices.PriceType.Custom, type(uint256).max);
    }

    /// @notice A full word whose upper 96 bits are dirty is not a valid address. The guard range-checks by hand, so
    ///         this surfaces as the NAMED error rather than the ABI decoder's anonymous revert.
    function test_RevertIf_registerAsset_baseAssetReturnsDirtyWord() public {
        MalformedBaseAssetFeed dirty = new MalformedBaseAssetFeed(address(lst), 1);
        vm.prank(navCalculatorManager);
        vm.expectRevert(_unreadable(address(lst), address(dirty)));
        nav.registerAsset(address(lst), address(dirty), IPrices.PriceType.Custom, type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Positive controls — the gate is not merely rejecting everything
    // -------------------------------------------------------------------------

    /// @notice The correct configuration still registers: an LST feed based on DAI, where DAI is priced directly.
    function test_registerAsset_navSourcedFeedWithDistinctBaseSucceeds() public {
        NavSourcedFeed good = new NavSourcedFeed(address(lst), address(nav), address(dai), 1.1e18);
        vm.prank(navCalculatorManager);
        nav.registerAsset(address(lst), address(good), IPrices.PriceType.Custom, type(uint256).max);

        assertTrue(nav.isAssetRegistered(address(lst)), "asset registered");
        assertEq(nav.getPriceFeedCount(address(lst)), 1, "feed registered");
        // And it prices: 1.1 × $1.00 = $1.10, proving the base leg still resolves through the NAV.
        (int256 price,,,) = nav.latestPrice(address(lst));
        assertEq(price, 1.1e8, "rate x base/USD");
    }

    /// @notice A feed that declares NO NAV dependency (`BASE_ASSET == address(0)`) registers cleanly. This is the
    ///         `ETHPlus_CustomPriceFeed` shape — it prices from the Reserve Protocol basket and never calls back —
    ///         and it is why the guard reads a value rather than merely testing for the function's presence.
    function test_registerAsset_feedDeclaringNoNavDependencySucceeds() public {
        NavSourcedFeed standalone = new NavSourcedFeed(address(lst), address(nav), address(0), 1e18);
        vm.prank(navCalculatorManager);
        nav.registerAsset(address(lst), address(standalone), IPrices.PriceType.Custom, type(uint256).max);
        assertEq(nav.getPriceFeedCount(address(lst)), 1, "no-NAV-dependency feed registers");
    }

    /// @dev Probes `feed` exactly as `PriceFeedLib._validateFeedNotCircular` does — a RAW `staticcall` on the
    ///      `BASE_ASSET()` selector, not a typed call — and returns the address it reports. Fails the test with
    ///      `what` if the feed does not answer with one clean ABI word, which is the shape registration rejects as
    ///      {IPrices-CustomFeedBaseUnreadable}.
    ///
    ///      Raw rather than `INavSourcedPriceFeed(feed).BASE_ASSET()` deliberately: a typed call would compile only
    ///      against types that already declare the interface, so it could not observe a type that stopped declaring
    ///      it. The raw selector is what production uses and is indifferent to the declaration.
    function _probeBaseAsset(address feed, string memory what) internal view returns (address) {
        (bool ok, bytes memory ret) = feed.staticcall(abi.encodeWithSelector(INavSourcedPriceFeed.BASE_ASSET.selector));
        assertTrue(ok, string.concat(what, ": BASE_ASSET() must answer"));
        assertEq(ret.length, 32, string.concat(what, ": must return exactly one ABI word"));
        return abi.decode(ret, (address));
    }

    /// @notice Each of the four real feed roots, instantiated as a shipped concrete type, answers `BASE_ASSET()` with
    ///         the value it was configured with — so registration admits them.
    /// @dev **This replaces a test that asserted the same thing about a MOCK** (`NavSourcedFeed`, declared in this
    ///      file), which could not fail for anything a real feed did — see issue #271. A mock proving the mock works
    ///      is the failure mode; these are `new`-ed from `src/`.
    ///
    ///      **What this actually covers, stated narrowly.** A *rename* of `BASE_ASSET` is already a COMPILE error:
    ///      all four roots declare `INavSourcedPriceFeed`, and a public state variable carrying `override` is what
    ///      satisfies it, so dropping or renaming the member fails the build long before any test runs. The
    ///      superseded docstring claimed to guard that hazard and did not; this one does not claim it either.
    ///
    ///      What is left, and is genuinely only reachable at runtime, is the residual case: **a root that DROPS
    ///      `INavSourcedPriceFeed` from its inheritance list while keeping a differently-named variable.** That
    ///      compiles cleanly and takes the compile-time protection with it, and every feed rooted in it silently
    ///      becomes unregisterable. The raw-selector probe above is indifferent to the declaration, so it still sees
    ///      the member's absence.
    ///
    ///      Three abstract roots are represented by concrete subclasses because the roots cannot be instantiated:
    ///      `wstETH` (`BaseCustomPriceFeed`), `sUSDe` (`ERC4626VaultRatePriceFeed`), `stETH`
    ///      (`CrossRateCustomPriceFeed` -> `TwoFeedChainlinkPriceFeed`). `ankrETH` is its own standalone root.
    function test_realFeedTypesAnswerBaseAsset() public {
        // BaseCustomPriceFeed, via wstETH.
        assertEq(
            _probeBaseAsset(address(new wstETH_CustomPriceFeed(address(lst), address(nav), address(dai))), "wstETH"),
            address(dai),
            "wstETH reports its configured base"
        );

        // ERC4626VaultRatePriceFeed, via sUSDe. The base MUST be the vault's own `asset()` (constructor-enforced),
        // which is also why this root can never be configured circularly: the base is the underlying, never the share.
        Mock_ERC4626 vault = new Mock_ERC4626("vSHARE", 18, address(dai), 1e18);
        assertEq(
            _probeBaseAsset(address(new sUSDe_CustomPriceFeed(address(vault), address(nav), address(dai))), "sUSDe"),
            address(dai),
            "sUSDe reports the vault underlying as its base"
        );

        // TwoFeedChainlinkPriceFeed (through CrossRateCustomPriceFeed), via stETH.
        Mock_PriceOracleChainlink rateFeed = new Mock_PriceOracleChainlink("LST/ETH", 1e18, 18);
        assertEq(
            _probeBaseAsset(
                address(new stETH_CustomPriceFeed(address(lst), address(rateFeed), 86_400, address(nav), address(dai))),
                "stETH"
            ),
            address(dai),
            "stETH reports its configured base"
        );

        // ankrETH — its own root, with BASE_ASSET as a plain immutable.
        assertEq(
            _probeBaseAsset(address(new ankrETH_CustomPriceFeed(address(lst), address(nav), address(dai))), "ankrETH"),
            address(dai),
            "ankrETH reports its configured base"
        );
    }

    /// @notice `ETHPlus_CustomPriceFeed` answers `BASE_ASSET()` with EXACTLY `address(0)` — "no NAV dependency" —
    ///         which is what makes it registrable.
    /// @dev **Pinned separately because it is the one value #268 newly introduced, and the only one whose
    ///      correctness is a VALUE rather than mere presence.** Every other root already exposed a public
    ///      `BASE_ASSET` getter before that PR, which only added `override`; ETHPlus had no such member at all and
    ///      gained `address public constant override BASE_ASSET = address(0)`.
    ///
    ///      A wrong constant here is NOT a compile error and NOT caught by anything else. If it were ever set to a
    ///      real asset, ETHPlus would become unregisterable for that asset ({IPrices-CustomFeedBaseCircular}) while
    ///      still compiling, still answering, and still passing every other test in this file — and ETH+ prices from
    ///      the Reserve Protocol basket and never reads the NAV, so any non-zero value would also be a lie about the
    ///      feed's actual dependency.
    function test_ethPlusDeclaresNoNavDependency() public {
        Mock_ERC20 ethPlus = new Mock_ERC20("ETH+", 18);
        ETHPlus_CustomPriceFeed feed = new ETHPlus_CustomPriceFeed(address(ethPlus), 86_400);
        assertEq(_probeBaseAsset(address(feed), "ETHPlus"), address(0), "ETHPlus must declare NO NAV dependency");

        // And that value is what registration accepts: `address(0)` can never equal a registrable asset.
        assertTrue(feed.BASE_ASSET() != address(ethPlus), "address(0) can never collide with the asset it prices");
    }
}
