// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_CustomPriceFeed} from "test/mocks/price_oracles.sol";
import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";

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
    // Equivalence with the path this replaced
    // -----------------------------------------------------------------------

    /// @notice **The property this PR actually needs to be true**, and the one nothing else guards: the O(1) getter
    ///         must agree with the linear scan it replaced, for every reachable registry state — same `found`, same
    ///         `asset`, same `symbol`, same `decimals`.
    /// @dev A perf change that quietly altered a RESULT would be far worse than the gas it saved: `_eligible` gates
    ///      every emitted leg, so a `found` that flipped false would make legs vanish silently, and one that
    ///      flipped true would value an unregistered asset.
    ///
    ///      Fuzzed over randomised register/unregister sequences rather than fixed cases, because the interesting
    ///      states are the ones swap-and-pop produces after many mutations, not the ones anyone thinks to write
    ///      down. Also asserts the REVERSE direction — every entry in the array is reachable through the index and
    ///      the index points back at that same entry — which catches an orphaned or cross-wired index that a
    ///      forward-only check would miss.
    /// @param seed Drives which assets get unregistered.
    /// @param probe An arbitrary address to resolve, so misses are covered as densely as hits.
    function testFuzz_agreesWithTheLinearScanItReplaced(uint256 seed, address probe) public {
        // Mutate the registry: unregister a pseudo-random subset, exercising swap-and-pop repeatedly.
        //
        // NO contract read gates this loop, and that is the third iteration of this decision. Guarding on
        // `getRegisteredAsset` was self-referential. Guarding on `isAssetRegistered` LOOKED independent and is not:
        // it is `return _assetIndex[asset] != 0` (NAVCalculator.sol:739), the identical single SLOAD that produces
        // `found` in the function under test, so any `_assetIndex` fault making a registered asset read as index 0
        // silences BOTH — nothing gets unregistered, the registry stays as `setUp` left it, and the fuzz never
        // exercises one swap-and-pop while still reporting PASS.
        //
        // No guard is needed: each index is visited exactly once and every `_extra[i]` is registered in `setUp`, so
        // `unregisterAsset` can never be called twice on the same asset. Non-degeneracy is then asserted directly
        // from a LOCAL tally rather than inferred from a contract read — which is the only formulation that cannot
        // be silenced by the storage the test is meant to be checking.
        uint256 removed;
        vm.startPrank(navCalculatorManager);
        for (uint256 i = 0; i < _extra.length; i++) {
            if (uint256(keccak256(abi.encode(seed, i))) % 3 == 0) {
                nav.unregisterAsset(_extra[i]);
                removed++;
            }
        }
        vm.stopPrank();

        // The load-bearing non-degeneracy assertion. With 100 assets at ~1/3 each, `removed == 0` has probability
        // (2/3)^100 ~ 2.5e-18, so this is not a flake risk — it is the guarantee that the swap-and-pop states this
        // fuzz exists to explore were actually reached on this run.
        assertGt(removed, 0, "fuzz degenerated: no asset was unregistered, so swap-and-pop was never exercised");

        INAVCalculator.Asset[] memory snapshot = nav.getRegisteredAssets();

        // Forward: the getter agrees with the scan, on the fuzzed probe and on every registered asset.
        _assertAgrees(snapshot, probe);
        _assertAgrees(snapshot, address(usdc));
        _assertAgrees(snapshot, nav.NATIVE_ADDRESS());
        for (uint256 i = 0; i < _extra.length; i++) {
            _assertAgrees(snapshot, _extra[i]);
        }

        // Reverse: every array entry is reachable through the index AND resolves to itself. A forward-only check
        // passes happily against an index that has orphaned or cross-wired an entry.
        for (uint256 i = 0; i < snapshot.length; i++) {
            (INAVCalculator.Asset memory viaIndex, bool found) = nav.getRegisteredAsset(snapshot[i].asset);
            assertTrue(found, "every array entry must be reachable through the index");
            assertEq(viaIndex.asset, snapshot[i].asset, "and the index must point back at that same entry");
        }
    }

    /// @notice Asserts the O(1) getter and `RegisteredAssetLib.find` return identical results for one asset.
    function _assertAgrees(INAVCalculator.Asset[] memory snapshot, address asset) internal view {
        (INAVCalculator.Asset memory viaIndex, bool foundIndex) = nav.getRegisteredAsset(asset);
        (INAVCalculator.Asset memory viaScan, bool foundScan) = RegisteredAssetLib.find(snapshot, asset);

        assertEq(foundIndex, foundScan, "found must agree with the linear scan");
        assertEq(viaIndex.asset, viaScan.asset, "asset must agree");
        assertEq(viaIndex.decimals, viaScan.decimals, "decimals must agree");
        assertEq(viaIndex.symbol, viaScan.symbol, "symbol must agree");
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

        // Free, and much stronger than the gas comparison above: that loop removed 50 entries, and every
        // swap-and-pop moves the then-LAST entry into an earlier slot — starting with the very asset being
        // measured here. So this subject has been relocated repeatedly, and the index must have been rewritten
        // correctly every time. Assert it still resolves to ITSELF, not merely that it is still cheap.
        (INAVCalculator.Asset memory a, bool found) = nav.getRegisteredAsset(_extra[_extra.length - 1]);
        assertTrue(found, "subject survives 50 swap-and-pops");
        assertEq(a.asset, _extra[_extra.length - 1], "and still resolves to itself, not to an entry it displaced");
    }

    /// @notice A miss must not scale with registry size. Under the old scan a miss was the WORST case — it walked
    ///         the entire array before concluding nothing — and `_eligible` takes that path for every unregistered
    ///         token an adapter touches, which on a wide pool is most of them.
    /// @dev Deliberately NOT "a miss is cheaper than a hit". That version cannot fail for ANY implementation of this
    ///      getter: a miss returns early on one `SLOAD` where a hit additionally does an array read and a string
    ///      copy, so it is structurally cheaper and the assertion proves nothing the signature does not already.
    ///      Size-independence is the property that actually distinguishes a mapping load from a scan.
    function test_missDoesNotScaleWithRegistrySize() public {
        uint256 missAtFull = _warmCost(makeAddr("absent"));

        vm.startPrank(navCalculatorManager);
        for (uint256 i = 0; i < EXTRA_ASSETS / 2; i++) {
            nav.unregisterAsset(_extra[i]);
        }
        vm.stopPrank();

        uint256 missAtHalf = _warmCost(makeAddr("absent"));

        assertLt(missAtFull, missAtHalf * 2, "a miss must not scale with how many assets are registered");
        assertLt(missAtHalf, missAtFull * 2, "nor shrink with it");
    }
}
