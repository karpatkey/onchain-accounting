// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_CustomPriceFeed} from "test/mocks/price_oracles.sol";
import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";

/// @notice Minimal concrete meta-adapter that does nothing but expose `_getAssetInfo`, so the resolution path the
///         fix actually changed can be exercised directly.
contract AssetInfoProbeAdapter is MetaBalanceAdapter {
    constructor(address nav_) MetaBalanceAdapter(nav_) {}

    function probe(address asset) external view returns (INAVCalculator.Asset memory, bool) {
        return _getAssetInfo(asset);
    }

    function _instancePositions(address, bytes32, address)
        internal
        pure
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return new INAVCalculator.PositionBalance[](0);
    }

    function _instanceAssets(bytes32) internal pure override returns (address[] memory) {
        return new address[](0);
    }

    function _protocolBrand() internal pure override returns (bytes32) {
        return bytes32("probe");
    }

    function _protocolId() internal pure override returns (bytes32) {
        return bytes32("probe");
    }

    function _protocolSubId() internal pure override returns (bytes32) {
        return bytes32("probe");
    }

    function positionLabels(bytes calldata) external pure override returns (string[] memory) {
        return new string[](0);
    }
}

/// @notice A NAVCalculator stand-in whose ARRAY getter reverts, while the single-asset getter works.
/// @dev The regression guard's instrument. Any implementation of `_getAssetInfo` that still resolves through
///      `getRegisteredAssets()` fails against this immediately and unambiguously — no gas measurement involved,
///      so it cannot rot on an opcode-price change the way a threshold would.
contract ArrayGetterPoisonedNav {
    error ArrayGetterMustNotBeCalled();

    mapping(address => bool) internal _reg;

    function register(address a) external {
        _reg[a] = true;
    }

    function getRegisteredAssets() external pure returns (INAVCalculator.Asset[] memory) {
        revert ArrayGetterMustNotBeCalled();
    }

    function getRegisteredAsset(address asset) external view returns (INAVCalculator.Asset memory a, bool found) {
        if (!_reg[asset]) return (a, false);
        return (INAVCalculator.Asset({asset: asset, symbol: "P", decimals: 18}), true);
    }
}

/// @title `getRegisteredAsset` — behaviour and the O(1) property
/// @notice Guards the fix for `MetaBalanceAdapter._getAssetInfo`, which used to resolve one token by fetching the
///         WHOLE asset registry and linear-scanning it (`RegisteredAssetLib.find(getRegisteredAssets(), asset)`).
///         That cost **6,274,562 gas for a single 50-token Balancer instance at 43 registered assets** and 18.4M at
///         100 — super-linear, because every call allocated an N-element array that is never freed. `_eligible`
///         runs it before every emitted leg, so it multiplied by tokens × instances and, past a point, exhausted
///         the per-adapter stipend and turned a NAV read into a REVERT.
/// @dev **These tests assert the PROPERTY, not absolute gas numbers**, and that is deliberate. An absolute
///      threshold would encode today's opcode prices, rot on any solc or EVM change, and — worse — would still
///      pass if someone reintroduced an O(N) scan while the registry happened to be small. What actually needs
///      guarding is that lookup cost does not grow with:
///
///        1. **registry size** — the regression that made this super-linear, and
///        2. **position within the registry** — the tell-tale of a linear scan, since scanning makes the LAST
///           asset far dearer than the first while a mapping load does not care.
///
///      Both are expressed as ratios against a generous tolerance, so they cannot go brittle but cannot pass
///      against a scan either: at 100 registered assets an array-fetch-and-scan costs orders of magnitude more for
///      the last element than the first, which no tolerance here would absorb.
contract NAVCalculatorRegisteredAssetGetterTest is SuperTest {
    /// @notice Assets registered on top of SuperTest's baseline, to push the registry well past mainnet's 43.
    uint256 internal constant EXTRA_ASSETS = 100;

    address[] internal _extra;

    function setUp() public {
        setupAll();

        vm.startPrank(navCalculatorManager);
        for (uint256 i = 0; i < EXTRA_ASSETS; i++) {
            Mock_ERC20 t = new Mock_ERC20(string.concat("T", vm.toString(i)), 18);
            Mock_CustomPriceFeed f = new Mock_CustomPriceFeed("T", address(t), 1e8, 8);
            nav.registerAsset(address(t), address(f), IPrices.PriceType.Custom, type(uint256).max);
            _extra.push(address(t));
        }
        vm.stopPrank();
    }

    /// @notice Measures one `getRegisteredAsset` through the external ABI, warm.
    /// @dev Called twice per subject by every test below, and only the SECOND figure is used: the first pays
    ///      EIP-2929's cold account/slot charges, which are a property of what the test touched previously rather
    ///      than of the lookup, and would swamp the comparison being made.
    function _warmCost(address asset) internal view returns (uint256) {
        nav.getRegisteredAsset(asset); // warm the slots
        uint256 before = gasleft();
        nav.getRegisteredAsset(asset);
        return before - gasleft();
    }

    // -----------------------------------------------------------------------

    function test_returnsTheEntryForARegisteredAsset() public view {
        (INAVCalculator.Asset memory a, bool found) = nav.getRegisteredAsset(address(usdc));
        assertTrue(found, "USDC is registered");
        assertEq(a.asset, address(usdc));
        assertEq(a.decimals, 6, "metadata comes from the registry, not the caller");
        assertEq(a.symbol, "USDC");
    }

    /// @notice The non-reverting contract, which is the whole reason this is a new function rather than a widened
    ///         `_getRegisteredAsset` (that one reverts `AssetNotFound`).
    /// @dev "Not registered" is an ORDINARY outcome on an adapter's emission path — the leg is skipped. If this
    ///      reverted, every unregistered token an adapter encountered would fail the whole instance read, turning
    ///      a skipped leg into a dropped position.
    function test_absentAssetReturnsFalseAndDoesNotRevert() public {
        (INAVCalculator.Asset memory a, bool found) = nav.getRegisteredAsset(makeAddr("never-registered"));
        assertFalse(found, "absent asset reports not-found");
        assertEq(a.asset, address(0), "and the struct is zeroed");
        assertEq(a.decimals, 0);
    }

    /// @notice Unregistering must flip `found` — otherwise a stale entry keeps being valued after governance
    ///         removed it.
    function test_unregisteredAssetStopsBeingFound() public {
        address target = _extra[0];
        (, bool before) = nav.getRegisteredAsset(target);
        assertTrue(before, "registered to begin with");

        vm.prank(navCalculatorManager);
        nav.unregisterAsset(target);

        (, bool after_) = nav.getRegisteredAsset(target);
        assertFalse(after_, "unregistering flips found to false");
    }

    /// @notice Survives the registry's swap-and-pop. Removing an asset moves the LAST entry into the removed
    ///         index, so the moved asset's `_assetIndex` must be rewritten — if it were not, the getter would
    ///         return the wrong entry or lose it entirely, and a mapping-backed lookup is exactly where that class
    ///         of bug hides.
    function test_survivesSwapAndPopOfAnEarlierAsset() public {
        address moved = _extra[_extra.length - 1]; // currently the last registry entry
        address removed = _extra[0];

        vm.prank(navCalculatorManager);
        nav.unregisterAsset(removed);

        (INAVCalculator.Asset memory a, bool found) = nav.getRegisteredAsset(moved);
        assertTrue(found, "the swapped-in asset is still found after the pop");
        assertEq(a.asset, moved, "and resolves to itself, not to the entry it replaced");
    }

    // -----------------------------------------------------------------------
    // The regression guard
    // -----------------------------------------------------------------------

    /// @notice **The test that actually guards the fix.** `MetaBalanceAdapter._getAssetInfo` must resolve through
    ///         the single-asset getter and never through `getRegisteredAssets()`.
    /// @dev The gas-shape assertions below prove `getRegisteredAsset` is O(1), which is true by construction and
    ///      would pass against the OLD code too — they say nothing about which getter `_getAssetInfo` calls. This
    ///      one does, and deterministically: the NAV stand-in reverts on the array getter, so an implementation
    ///      that reached for it fails outright rather than merely costing more.
    ///
    ///      Deliberately not `vm.expectCall`-based. This asserts the negative — that a call does NOT happen — which
    ///      expectCall states awkwardly, and it also proves the resolution still WORKS, which a call assertion
    ///      does not.
    function test_getAssetInfoNeverTouchesTheArrayGetter() public {
        ArrayGetterPoisonedNav poisoned = new ArrayGetterPoisonedNav();
        AssetInfoProbeAdapter probeAdapter = new AssetInfoProbeAdapter(address(poisoned));

        address known = makeAddr("registered-token");
        poisoned.register(known);

        // Resolves a registered asset without ever calling the array getter.
        (INAVCalculator.Asset memory a, bool found) = probeAdapter.probe(known);
        assertTrue(found, "_getAssetInfo must resolve via getRegisteredAsset, not the array getter");
        assertEq(a.asset, known);
        assertEq(a.decimals, 18);

        // And the not-found path is equally array-free — this is the one `_eligible` takes most often on a wide
        // pool, and under the old scan it was the WORST case.
        (, bool missing) = probeAdapter.probe(makeAddr("unregistered-token"));
        assertFalse(missing, "the miss path must also avoid the array getter");
    }

    // -----------------------------------------------------------------------
    // The O(1) property
    // -----------------------------------------------------------------------

    /// @notice Cost must not depend on WHERE the asset sits in the registry. A linear scan makes the last entry
    ///         dramatically dearer than the first; a mapping load does not care.
    function test_costIsIndependentOfPositionInTheRegistry() public view {
        uint256 firstCost = _warmCost(_extra[0]);
        uint256 lastCost = _warmCost(_extra[_extra.length - 1]);

        // Generous both ways — this is a shape assertion, not a benchmark. A scan over 100+ entries would blow
        // past any factor here; identical mapping loads sit within a few gas of each other.
        assertLt(lastCost, firstCost * 2, "last-entry lookup must not scale with position (linear scan?)");
        assertLt(firstCost, lastCost * 2, "and neither should the first");
    }

    /// @notice Cost must not depend on HOW MANY assets are registered. This is the regression that made the old
    ///         path super-linear: it fetched the whole array every call.
    function test_costIsIndependentOfRegistrySize() public {
        uint256 costAtFull = _warmCost(_extra[_extra.length - 1]);

        // Shrink the registry substantially, then measure a still-registered asset again.
        vm.startPrank(navCalculatorManager);
        for (uint256 i = 0; i < EXTRA_ASSETS / 2; i++) {
            nav.unregisterAsset(_extra[i]);
        }
        vm.stopPrank();

        uint256 costAtHalf = _warmCost(_extra[_extra.length - 1]);

        assertLt(costAtFull, costAtHalf * 2, "halving the registry must not materially change lookup cost");
        assertLt(costAtHalf, costAtFull * 2, "nor should growing it");
    }

    /// @notice A miss must be as cheap as a hit. Under the old scan a miss was the WORST case — it walked the
    ///         entire array before concluding nothing — and `_eligible` takes that path for every unregistered
    ///         token an adapter touches, which on a wide pool is most of them.
    function test_missIsNotTheWorstCase() public {
        uint256 hitCost = _warmCost(_extra[_extra.length - 1]);
        uint256 missCost = _warmCost(makeAddr("absent"));

        assertLt(missCost, hitCost * 2, "a miss must not cost more than a hit (full-scan fallback?)");
    }
}
