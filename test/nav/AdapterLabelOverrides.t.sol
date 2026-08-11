// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IAssetKindRegistry} from "src/nav/IAssetKindRegistry.sol";
import {AssetKindRegistry} from "src/nav/AssetKindRegistry.sol";
import {aa} from "test/helpers/AdapterArray.sol";
import {Mock_CustomBalanceAdapter} from "test/mocks/balance_adapters.sol";
import {RawReplier} from "test/mocks/RawReplier.sol";

/// @notice Adapter shaped like the meta family: a constant `protocolName()` plus a `[category, leaf]` pair whose leaf
///         is re-read on every call, so a frozen leaf would be detectable.
contract LabelledAdapter is Mock_CustomBalanceAdapter {
    string private _name;
    string private _category;
    string private _leaf;

    constructor(string memory name_, string memory category_, string memory leaf_) {
        _name = name_;
        _category = category_;
        _leaf = leaf_;
    }

    /// @notice Mutates the LEAF only — the stand-in for the live on-chain reads the real computed adapters perform.
    function setLeaf(string memory leaf_) external {
        _leaf = leaf_;
    }

    function protocolName() external view returns (string memory) {
        return _name;
    }

    function positionLabels(bytes calldata) external view returns (string[] memory out) {
        out = new string[](2);
        out[0] = _category;
        out[1] = _leaf;
    }
}

/// @notice Adapter whose ONLY label segment is computed — the `ERC20DefaultBalanceAdapter` shape, and the single
///         documented case that must not be given a category override.
contract LeafOnlyAdapter is Mock_CustomBalanceAdapter {
    function protocolName() external pure returns (string memory) {
        return "Wallet";
    }

    function positionLabels(bytes calldata) external pure returns (string[] memory out) {
        out = new string[](1);
        out[0] = "USDC";
    }
}

/// @notice Adapter that describes no segments at all, to pin that a category override never grows an empty reply.
contract NoLabelAdapter is Mock_CustomBalanceAdapter {
    function protocolName() external pure returns (string memory) {
        return "Silent";
    }

    function positionLabels(bytes calldata) external pure returns (string[] memory) {
        return new string[](0);
    }
}

/// @notice A LITERAL segment that is a DIFFERENT literal per positionId. A per-adapter override cannot express that:
///         one write rewrites every position of the adapter.
/// @dev ⚠️ **This shape no longer has a counterpart in `src/`, and that is the point of keeping it.** It modelled
///      `CapBalanceAdapter`, which served both Cap legs from one contract (`["Savings","stcUSD"]` vs
///      `["Stablecoin","cUSD"]`); that adapter was SPLIT into `CapStablecoinBalanceAdapter` /
///      `CapSavingsBalanceAdapter` precisely so no deployed adapter is in this state — `BALANCE_ADAPTERS.md` §6.2's
///      sweep is the evidence that Cap was the only one. The mock stays because the MECHANISM's limitation is
///      unchanged and unenforceable, so the next adapter author who reaches for a per-position literal needs the
///      behaviour pinned rather than rediscovered.
/// @dev Implements {IBalanceAdapter} directly rather than extending `Mock_CustomBalanceAdapter`, because that mock
///      hardcodes `row.positionId = abi.encode(address(this))` for every row and its `getAdapterPositions` is not
///      `virtual`. With one positionId shared by both legs, `positionLabels` would take the same branch twice and the
///      test would assert nothing — the control assertion in the test below is what caught exactly that.
contract PerPositionCategoryAdapter is IBalanceAdapter {
    address private immutable SAVINGS_ASSET;
    address private immutable STABLE_ASSET;

    constructor(address savingsAsset, address stableAsset) {
        SAVINGS_ASSET = savingsAsset;
        STABLE_ASSET = stableAsset;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function underlyingAssetsSupported() public view override returns (address[] memory out) {
        out = new address[](2);
        out[0] = SAVINGS_ASSET;
        out[1] = STABLE_ASSET;
    }

    function getAdapterBalanceForAsset(address, address) external pure override returns (uint256, bool) {
        return (1e6, false);
    }

    function getAdapterBalances(address)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory debts)
    {
        assets = underlyingAssetsSupported();
        amounts = new uint256[](2);
        amounts[0] = 1e6;
        amounts[1] = 1e6;
        debts = new bool[](2);
    }

    /// @dev Two rows, each carrying its OWN positionId — the property the shared mock cannot express.
    function getAdapterPositions(address, address)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        positions = new INAVCalculator.PositionBalance[](2);
        positions[0] = _row(SAVINGS_ASSET);
        positions[1] = _row(STABLE_ASSET);
    }

    function _row(address asset) private view returns (INAVCalculator.PositionBalance memory row) {
        row.balanceAsset = INAVCalculator.Asset({
            asset: asset, symbol: IERC20Metadata(asset).symbol(), decimals: IERC20Metadata(asset).decimals()
        });
        row.balanceAdapter = address(this);
        row.amount = 1e6;
        row.isDebt = false;
        row.positionId = abi.encode(asset);
        row.positionKind = PositionKind.Supplied;
    }

    function protocolName() external pure returns (string memory) {
        return "Cap";
    }

    function positionLabels(bytes calldata positionId) external view returns (string[] memory out) {
        out = new string[](2);
        if (abi.decode(positionId, (address)) == SAVINGS_ASSET) {
            out[0] = "Savings";
            out[1] = "stcUSD";
        } else {
            out[0] = "Stablecoin";
            out[1] = "cUSD";
        }
    }
}

/// @notice Behaves like a REAL meta-adapter: `positionLabels("")` returns `[]` (its breadcrumb is per-position), and
///         a genuine positionId returns `[category, leaf]`.
/// @dev This shape is what `MetaBalanceAdapter._addressLabels` produces — `_pidAddress` rejects a non-32-byte pid, so
///      the empty pid yields an empty array. 21 of 33 deployable adapters do this. `LabelledAdapter` does NOT model
///      it (it returns a fixed array for any positionId), which is exactly why the first version of the
///      surface-agreement test could not see the category override being dropped on the configuration path.
contract MetaShapedAdapter is Mock_CustomBalanceAdapter {
    function protocolName() external pure returns (string memory) {
        return "Morpho";
    }

    function positionLabels(bytes calldata positionId) external pure returns (string[] memory out) {
        if (positionId.length != 32) return new string[](0);
        out = new string[](2);
        out[0] = "Vault";
        out[1] = "steakUSDC";
    }
}

/// @notice The `ConvexCurveLPStakingMetaBalanceAdapter` shape: a reply whose LENGTH varies by position — 2 elements
///         when its leaf probe comes back empty, 3 when it answers.
/// @dev This is the mock that makes the `min(reply.length, override.length)` bound assertable against something real
///      rather than hypothetical. `ConvexCurveLPStakingMetaBalanceAdapter.positionLabels` builds `["Staking",
///      "Curve LP"]` or `["Staking", "Curve LP", coins]` depending on whether `rewarderCoinSymbols` answers, so a
///      3-segment override written under a fixed-length assumption is a `Panic(0x32)` on live data the moment the
///      probe fails. Most of the meta family is a milder version of the same thing (0, 1 or 2 by position).
contract VaryingLengthAdapter is Mock_CustomBalanceAdapter {
    bool private _deep;

    /// @notice Toggles the third segment on/off, standing in for the leaf probe succeeding or failing.
    function setDeep(bool deep_) external {
        _deep = deep_;
    }

    function protocolName() external pure returns (string memory) {
        return "Convex";
    }

    function positionLabels(bytes calldata) external view returns (string[] memory out) {
        out = new string[](_deep ? 3 : 2);
        out[0] = "Staking";
        out[1] = "Curve LP";
        if (_deep) out[2] = "crvUSD/USDC";
    }
}

/// @notice A registry that reverts on every call, to prove the read path is fail-open against a NON-ZERO but broken
///         registry — the case `address(0)` short-circuiting does not cover.
contract RevertingRegistry {
    fallback() external {
        revert("registry down");
    }
}

/// @notice A registry that returns a well-formed but absurdly long reply, to prove the output window holds.
contract OverlongRegistry {
    function getAdapterProtocolName(address) external pure returns (string memory) {
        return string(new bytes(5000));
    }

    function getAdapterLabels(address) external pure returns (string[] memory out) {
        out = new string[](1);
        out[0] = string(new bytes(5000));
    }
}

abstract contract AdapterLabelOverridesBase is SuperTest {
    LabelledAdapter internal adapter;

    function _register(Mock_CustomBalanceAdapter a) internal {
        a.setBalances(nav);
        a.setUnderlyingAssetsSupported(aa(address(usdc)));
        a.setBalance(address(usdc), safe, 5 * 10 ** usdc.decimals(), false);
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(a)));
    }

    function _verboseFor(address a) internal view returns (INAVCalculator.VerbosePosition memory) {
        INAVCalculator.VerbosePosition[] memory all = nav.getAccountPositionsVerbose(safe, address(0));
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].position.balanceAdapter == a) return all[i];
        }
        revert("adapter position not found");
    }

    function _v() internal view returns (INAVCalculator.VerbosePosition memory) {
        return _verboseFor(address(adapter));
    }

    /// @notice A one-segment override — exactly what the retired `setAdapterLabelCategory(adapter, s)` did.
    /// @dev Every migrated call site in this file uses this, which is itself the evidence for the subsumption ruling:
    ///      the scalar setter was a strict special case of the array one, not a complement to it.
    function one(string memory a) internal pure returns (string[] memory out) {
        out = new string[](1);
        out[0] = a;
    }

    function two(string memory a, string memory b) internal pure returns (string[] memory out) {
        out = new string[](2);
        out[0] = a;
        out[1] = b;
    }

    function three(string memory a, string memory b, string memory c) internal pure returns (string[] memory out) {
        out = new string[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    /// @notice The configuration surface's breadcrumb for a single adapter.
    function _configLabels(address a) internal view returns (string[] memory) {
        address[] memory one_ = new address[](1);
        one_[0] = a;
        (, string[][] memory labels) = nav.getAdapterDisplayInfo(one_);
        return labels[0];
    }
}

contract AdapterLabelOverridesTest is AdapterLabelOverridesBase {
    AssetKindRegistry internal registry;

    function setUp() public {
        setupAll();
        registry = new AssetKindRegistry(address(nav));
        // NOTE: deliberately NO `grantRole(MANAGER, registry)`, unlike the asset-kind tests. These overrides never
        // invoke any STATE-CHANGING NAV function, so they need no role grant at all. (They DO read the NAV:
        // `hasRole` on the gate and `isAdapterRegistered` in the setters, both `view`. An earlier revision of
        // this note said "never call back into the NAV", which was false.)
        // `test_overrides_needNoRoleGrant` pins that.
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));

        adapter = new LabelledAdapter("Mock Protocol", "Market", "wstETH/USDC");
        _register(adapter);
    }

    /// @dev Locates `assetKindRegistry`'s storage slot by SCANNING for the known address rather than hardcoding an
    ///      index, which would silently stop matching after any NAVCalculator layout change and turn the
    ///      zero-registry baseline into a no-op that measures nothing.
    ///
    ///      **Finding the address is not enough — it must be the RIGHT slot.** The scan returns the first slot whose
    ///      low 160 bits match, and more than one slot could hold that address. So the candidate is PROVEN by
    ///      zeroing it and checking the public `assetKindRegistry()` getter actually reads back `address(0)`, then
    ///      restoring. A wrong match fails that check and reverts, instead of yielding a baseline that silently
    ///      measures the un-zeroed path.
    function _registrySlot() internal returns (bytes32) {
        for (uint256 i = 0; i < 200; i++) {
            bytes32 slot = bytes32(i);
            uint256 word = uint256(vm.load(address(nav), slot));
            if (address(uint160(word)) != address(registry)) continue;
            vm.store(address(nav), slot, bytes32(0));
            bool proven = address(nav.assetKindRegistry()) == address(0);
            vm.store(address(nav), slot, bytes32(word));
            if (proven) return slot;
        }
        revert("assetKindRegistry slot not found (or candidate failed the zeroing proof)");
    }

    // ------------------------------------------------------------------
    // (A) protocolName override
    // ------------------------------------------------------------------

    /// @dev **This is the arm that must go red** when the `_adapterOverrides` lookup is removed from
    ///      `PriceFeedLib.toVerbose`. The first assertion passes either way (it is the adapter's own name); the
    ///      second is reachable only when the override is consulted.
    function test_protocolNameOverride_replacesAdapterName() public {
        assertEq(_v().protocolName, "Mock Protocol", "baseline: the adapter's own name");

        vm.prank(navCalculatorManager);
        registry.setAdapterProtocolName(address(adapter), "Overridden Protocol");

        assertEq(_v().protocolName, "Overridden Protocol", "the override must win over the adapter staticcall");
    }

    function test_protocolNameOverride_clearRestoresAdapterName() public {
        vm.startPrank(navCalculatorManager);
        registry.setAdapterProtocolName(address(adapter), "Overridden Protocol");
        assertEq(_v().protocolName, "Overridden Protocol");
        registry.clearAdapterProtocolName(address(adapter));
        vm.stopPrank();

        assertEq(_v().protocolName, "Mock Protocol", "clearing must fall back to the adapter");
    }

    /// @dev The override must not leak across adapters — it is keyed, not global.
    function test_protocolNameOverride_isPerAdapter() public {
        LabelledAdapter other = new LabelledAdapter("Other Protocol", "Vault", "sUSDe");
        _register(other);

        vm.prank(navCalculatorManager);
        registry.setAdapterProtocolName(address(adapter), "Overridden Protocol");

        assertEq(_v().protocolName, "Overridden Protocol");
        assertEq(_verboseFor(address(other)).protocolName, "Other Protocol", "a sibling adapter is unaffected");
    }

    // ------------------------------------------------------------------
    // (B) label-category override
    // ------------------------------------------------------------------

    function test_labelsOverride_replacesSegment0AndPreservesComputedLeaf() public {
        INAVCalculator.VerbosePosition memory v = _v();
        assertEq(v.labels.length, 2);
        assertEq(v.labels[0], "Market", "baseline category");
        assertEq(v.labels[1], "wstETH/USDC", "baseline leaf");

        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(adapter), one("Lending Market"));

        v = _v();
        assertEq(v.labels.length, 2, "the override must not change the array length");
        assertEq(v.labels[0], "Lending Market", "category must be overridden");
        assertEq(v.labels[1], "wstETH/USDC", "the COMPUTED LEAF must be untouched");
    }

    /// @dev The load-bearing claim of the whole design: the leaf stays LIVE. With a category override in place, a
    ///      change in the adapter's derived leaf must still flow through. A table that froze the leaf would fail this.
    function test_labelsOverride_leafStaysLive() public {
        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(adapter), one("Lending Market"));

        adapter.setLeaf("WETH/DAI");

        INAVCalculator.VerbosePosition memory v = _v();
        assertEq(v.labels[0], "Lending Market", "category still overridden");
        assertEq(v.labels[1], "WETH/DAI", "the leaf must be recomputed live, never frozen");
    }

    function test_labelsOverride_clearRestoresAdapterSegments() public {
        vm.startPrank(navCalculatorManager);
        registry.setAdapterLabels(address(adapter), one("Lending Market"));
        assertEq(_v().labels[0], "Lending Market");
        registry.clearAdapterLabels(address(adapter));
        vm.stopPrank();

        assertEq(_v().labels[0], "Market", "clearing must fall back to the adapter");
    }

    /// @dev An adapter that describes no segments has no category to correct. The override must leave the empty
    ///      reply empty rather than growing it to length 1.
    function test_labelsOverride_doesNotGrowAnEmptyLabelSet() public {
        NoLabelAdapter silent = new NoLabelAdapter();
        _register(silent);

        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(silent), one("Invented Category"));

        assertEq(_verboseFor(address(silent)).labels.length, 0, "an empty reply must stay empty");
    }

    /// @dev The documented hazard, asserted rather than assumed, and now the ONLY adapter-level exclusion left.
    ///      `ERC20DefaultBalanceAdapter`'s shape is a single element that IS the computed leaf, so any override there
    ///      replaces the leaf. The mechanism sees an array, not the source, and cannot tell a category from a leaf —
    ///      hence the exclusion is operational, not enforced. Note there is no way to express "override nothing" for a
    ///      one-element reply: `[""]` is refused as an override that reads back as absence, so the guidance really is
    ///      "leave this adapter alone".
    function test_labelsOverride_onLeafOnlyAdapter_replacesTheLeaf_documentedHazard() public {
        LeafOnlyAdapter leafOnly = new LeafOnlyAdapter();
        _register(leafOnly);

        assertEq(_verboseFor(address(leafOnly)).labels[0], "USDC");

        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(leafOnly), one("Wallet Balance"));

        assertEq(
            _verboseFor(address(leafOnly)).labels[0],
            "Wallet Balance",
            "index 0 is replaced whether or not it was a category: the documented hazard"
        );
    }

    /// @dev The two overrides are independent stores; setting one must not imply or disturb the other.
    function test_overrides_areIndependent() public {
        vm.prank(navCalculatorManager);
        registry.setAdapterProtocolName(address(adapter), "Overridden Protocol");

        INAVCalculator.VerbosePosition memory v = _v();
        assertEq(v.protocolName, "Overridden Protocol");
        assertEq(v.labels[0], "Market", "the category is untouched by a name override");

        vm.prank(navCalculatorManager);
        registry.clearAdapterProtocolName(address(adapter));
        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(adapter), one("Lending Market"));

        v = _v();
        assertEq(v.protocolName, "Mock Protocol", "the name is untouched by a category override");
        assertEq(v.labels[0], "Lending Market");
    }

    // ------------------------------------------------------------------
    // Fallback: an un-overridden adapter is byte-identical
    // ------------------------------------------------------------------

    /// @dev Verification item 4. Snapshot the whole verbose reply for an adapter with no override, set overrides on a
    ///      DIFFERENT adapter, and require the untouched one to hash identically.
    function test_noOverride_isByteIdentical() public {
        LabelledAdapter other = new LabelledAdapter("Other Protocol", "Vault", "sUSDe");
        _register(other);

        INAVCalculator.VerbosePosition memory before = _verboseFor(address(other));
        bytes32 beforeHash = keccak256(abi.encode(before.protocolName, before.labels));

        vm.startPrank(navCalculatorManager);
        registry.setAdapterProtocolName(address(adapter), "Overridden Protocol");
        registry.setAdapterLabels(address(adapter), one("Lending Market"));
        vm.stopPrank();

        INAVCalculator.VerbosePosition memory afterOverride = _verboseFor(address(other));
        assertEq(
            keccak256(abi.encode(afterOverride.protocolName, afterOverride.labels)),
            beforeHash,
            "an adapter with no override must be byte-identical"
        );
        assertEq(afterOverride.protocolName, "Other Protocol");
        assertEq(afterOverride.labels[0], "Vault");
        assertEq(afterOverride.labels[1], "sUSDe");
    }

    // ------------------------------------------------------------------
    // Governance and validation
    // ------------------------------------------------------------------

    /// @dev The design property that motivated hosting this here: the overrides are a pure read store that never
    ///      calls the NAV, so the registry needs NO role on it. `setUp` deliberately never grants one.
    function test_overrides_needNoRoleGrant() public {
        assertFalse(nav.hasRole(MANAGER, address(registry)), "precondition: the registry holds no role on the NAV");

        vm.prank(navCalculatorManager);
        registry.setAdapterProtocolName(address(adapter), "Overridden Protocol");

        assertEq(_v().protocolName, "Overridden Protocol", "the override works with zero privilege on the NAV");
    }

    function test_RevertIf_setAdapterProtocolName_notManager() public {
        vm.expectRevert(NotAuthorized.selector);
        registry.setAdapterProtocolName(address(adapter), "Nope");
    }

    function test_RevertIf_setAdapterLabels_notManager() public {
        vm.expectRevert(NotAuthorized.selector);
        registry.setAdapterLabels(address(adapter), one("Nope"));
    }

    function test_RevertIf_clearAdapterProtocolName_notManager() public {
        vm.expectRevert(NotAuthorized.selector);
        registry.clearAdapterProtocolName(address(adapter));
    }

    function test_RevertIf_setAdapterProtocolName_unregisteredAdapter() public {
        address ghost = makeAddr("ghost");
        vm.prank(navCalculatorManager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.AdapterNotRegistered.selector, ghost));
        registry.setAdapterProtocolName(ghost, "Ghost Protocol");
    }

    function test_RevertIf_setAdapterLabels_unregisteredAdapter() public {
        address ghost = makeAddr("ghost");
        vm.prank(navCalculatorManager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.AdapterNotRegistered.selector, ghost));
        registry.setAdapterLabels(ghost, one("Ghost Category"));
    }

    function test_RevertIf_setAdapterProtocolName_empty() public {
        vm.prank(navCalculatorManager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.EmptyAdapterOverride.selector, address(adapter)));
        registry.setAdapterProtocolName(address(adapter), "");
    }

    function test_RevertIf_setAdapterProtocolName_tooLong() public {
        string memory tooLong = "123456789012345678901234567890123"; // 33 bytes
        vm.prank(navCalculatorManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssetKindRegistry.AdapterOverrideTooLong.selector, address(adapter), uint256(33), uint256(32)
            )
        );
        registry.setAdapterProtocolName(address(adapter), tooLong);
    }

    /// @dev Exactly at the bound must be accepted — an off-by-one here would silently forbid a legal name.
    function test_setAdapterProtocolName_atMaxLength() public {
        string memory exact = "12345678901234567890123456789012"; // 32 bytes
        vm.prank(navCalculatorManager);
        registry.setAdapterProtocolName(address(adapter), exact);
        assertEq(_v().protocolName, exact);
    }

    function test_RevertIf_clearAdapterProtocolName_notSet() public {
        vm.prank(navCalculatorManager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.AdapterOverrideNotSet.selector, address(adapter)));
        registry.clearAdapterProtocolName(address(adapter));
    }

    function test_RevertIf_clearAdapterLabels_notSet() public {
        vm.prank(navCalculatorManager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.AdapterOverrideNotSet.selector, address(adapter)));
        registry.clearAdapterLabels(address(adapter));
    }

    /// @dev Clearing must stay possible after the adapter is deregistered, or an override would be both unreadable
    ///      and unremovable. This is the stranding hazard the asset-label path documents and this one avoids.
    function test_clearAdapterProtocolName_worksAfterDeregistration() public {
        vm.prank(navCalculatorManager);
        registry.setAdapterProtocolName(address(adapter), "Overridden Protocol");

        vm.prank(navCalculatorManager);
        nav.removeBalanceAdapters(aa(address(adapter)));

        vm.prank(navCalculatorManager);
        registry.clearAdapterProtocolName(address(adapter));

        assertEq(registry.getAdapterProtocolName(address(adapter)), "", "the override must be removable");
    }

    function test_getters_returnEmptyWhenUnset() public view {
        assertEq(registry.getAdapterProtocolName(address(adapter)), "");
        assertEq(registry.getAdapterLabels(address(adapter)).length, 0, "no label override set");
    }

    // ------------------------------------------------------------------
    // Per-adapter cache: the override must reach EVERY position, not just the first
    // ------------------------------------------------------------------

    /// @dev `toVerbose` fetches the overrides only when `adapter != prevAdapter` and reuses the cached values for the
    ///      rest of that adapter's contiguous run. Every other test registers a one-asset adapter, so that branch is
    ///      taken on every iteration and the cache-HIT path never runs. This registers a TWO-position adapter so the
    ///      second position is served from the cache — a regression that reset or mis-scoped `prevCategory` after use
    ///      would drop the override on positions 2..n of every real multi-instance meta-adapter and go unnoticed.
    function test_override_appliesToEveryPositionOfTheSameAdapter() public {
        LabelledAdapter multi = new LabelledAdapter("Multi Protocol", "Market", "leaf");
        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(dai);
        multi.setBalances(nav);
        multi.setUnderlyingAssetsSupported(assets);
        multi.setBalance(address(usdc), safe, 5 * 10 ** usdc.decimals(), false);
        multi.setBalance(address(dai), safe, 5 * 10 ** dai.decimals(), false);
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(multi)));

        vm.startPrank(navCalculatorManager);
        registry.setAdapterProtocolName(address(multi), "Overridden Protocol");
        registry.setAdapterLabels(address(multi), one("Lending Market"));
        vm.stopPrank();

        INAVCalculator.VerbosePosition[] memory all = nav.getAccountPositionsVerbose(safe, address(0));
        uint256 seen;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].position.balanceAdapter != address(multi)) continue;
            ++seen;
            assertEq(all[i].protocolName, "Overridden Protocol", "name must apply to every position of the adapter");
            assertEq(all[i].labels[0], "Lending Market", "category must apply to every position of the adapter");
            assertEq(all[i].labels[1], "leaf", "leaf untouched on every position");
        }
        assertEq(seen, 2, "the adapter must have produced two positions, or the cache path was not exercised");
    }

    /// @dev The mechanism's per-position limitation, asserted rather than assumed: an adapter emitting a DIFFERENT
    ///      literal at index 0 per position has both of them rewritten by one per-adapter override.
    ///
    ///      **No adapter in `src/` is in this state any more.** `CapBalanceAdapter` was, at both indices, and was
    ///      split into two one-leg adapters rather than accommodated here. This test therefore pins a property of the
    ///      MECHANISM against a synthetic shape — which is still worth having, because nothing on-chain can detect the
    ///      shape and the fix is always "split the adapter", never "extend the table".
    function test_labelsOverride_onPerPositionLiteralAdapter_rewritesBothLegs_documentedHazard() public {
        PerPositionCategoryAdapter cap = new PerPositionCategoryAdapter(address(usdc), address(dai));
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(cap)));

        // Baseline: the two legs genuinely carry different categories.
        INAVCalculator.VerbosePosition[] memory all = nav.getAccountPositionsVerbose(safe, address(0));
        string memory catA;
        string memory catB;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].position.balanceAdapter != address(cap)) continue;
            if (bytes(catA).length == 0) catA = all[i].labels[0];
            else catB = all[i].labels[0];
        }
        assertTrue(
            keccak256(bytes(catA)) != keccak256(bytes(catB)), "control: this adapter's categories differ per position"
        );

        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(cap), one("Synthetic Dollar"));

        all = nav.getAccountPositionsVerbose(safe, address(0));
        uint256 seen;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].position.balanceAdapter != address(cap)) continue;
            ++seen;
            assertEq(all[i].labels[0], "Synthetic Dollar", "one override rewrites BOTH legs: the documented hazard");
        }
        assertEq(seen, 2);
    }

    // ------------------------------------------------------------------
    // Fail-open against a NON-ZERO but broken registry
    // ------------------------------------------------------------------

    /// @dev `setAssetKindRegistry` rejects only `address(0)`, so a MANAGER can wire an EOA, a self-destructed
    ///      contract, or a pre-override registry with no such selectors. The verbose read must degrade to "no
    ///      override", never revert. The zero-address short-circuit does not cover any of these.
    function test_revertingRegistry_failsOpenToTheAdapter() public {
        // The deployment is hoisted ABOVE the prank on purpose: `vm.prank` applies to the next call OR CREATE, so
        // `new` inside the pranked expression consumes it and the setter runs unpranked, reverting NotAuthorized.
        address broken = address(new RevertingRegistry());
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(broken);

        INAVCalculator.VerbosePosition memory v = _v();
        assertEq(v.protocolName, "Mock Protocol", "a reverting registry must fall back to the adapter");
        assertEq(v.labels[0], "Market");
        assertEq(v.labels[1], "wstETH/USDC");
    }

    function test_eoaRegistry_failsOpenToTheAdapter() public {
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(makeAddr("not a contract"));

        INAVCalculator.VerbosePosition memory v = _v();
        assertEq(v.protocolName, "Mock Protocol", "a codeless registry must fall back to the adapter");
        assertEq(v.labels[0], "Market");
    }

    /// @dev An over-long reply must be truncated by the output window, fail to decode, and yield "" — not revert and
    ///      not blow up the frame.
    function test_overlongRegistryReply_failsOpenToTheAdapter() public {
        address overlong = address(new OverlongRegistry());
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(overlong);

        INAVCalculator.VerbosePosition memory v = _v();
        assertEq(v.protocolName, "Mock Protocol", "an over-long reply must degrade, not override");
        assertEq(v.labels[0], "Market", "and must not replace the category either");
    }

    /// @dev Replacing the registry silently drops every override — the behaviour documented on
    ///      {IAssetKindRegistry.clearAdapterProtocolName}. Pinned so the silence is a recorded property rather than a
    ///      surprise: nothing reverts, and the label simply reverts to the adapter's own constant.
    function test_replacingRegistry_silentlyDropsOverrides() public {
        vm.prank(navCalculatorManager);
        registry.setAdapterProtocolName(address(adapter), "Overridden Protocol");
        assertEq(_v().protocolName, "Overridden Protocol");

        address fresh = address(new AssetKindRegistry(address(nav)));
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(fresh);

        assertEq(_v().protocolName, "Mock Protocol", "a fresh registry silently loses every override");
    }

    // ------------------------------------------------------------------
    // Gas: the registry leg must stay bounded
    // ------------------------------------------------------------------

    /// @dev Measures the registry surcharge against a real no-registry baseline.
    ///
    ///      **The baseline is measured FIRST, deliberately.** An earlier revision measured it last, after two prior
    ///      verbose reads had already grown this frame's memory; since memory cost is quadratic in the frame total,
    ///      that biased the baseline UP and the published surcharge DOWN. Ordering is part of the measurement.
    ///
    ///      **What this test does and does not bound.** It bounds the surcharge for ONE distinct adapter emitting ONE
    ///      position. It CANNOT distinguish a per-adapter lookup from a per-position one, because with one position
    ///      the two are identical — an earlier revision's comment claimed otherwise and was simply wrong. The
    ///      per-position regression is caught by {test_gas_surchargeIsPerAdapter_notPerPosition}, and only by it.
    function test_gas_registryLegIsBounded() public {
        _v(); // warm every path

        bytes32 rslot = _registrySlot();
        uint256 saved = uint256(vm.load(address(nav), rslot));
        vm.store(address(nav), rslot, bytes32(0));
        uint256 before = gasleft();
        nav.getAccountPositionsVerbose(safe, address(0));
        uint256 noRegistry = before - gasleft();
        vm.store(address(nav), rslot, bytes32(saved));

        before = gasleft();
        nav.getAccountPositionsVerbose(safe, address(0));
        uint256 miss = before - gasleft();

        vm.prank(navCalculatorManager);
        registry.setAdapterProtocolName(address(adapter), "Overridden Protocol");
        before = gasleft();
        nav.getAccountPositionsVerbose(safe, address(0));
        uint256 hit = before - gasleft();

        emit log_named_uint("verbose read gas, NO registry ", noRegistry);
        emit log_named_uint("verbose read gas, override HIT", hit);
        emit log_named_uint("verbose read gas, override MISS", miss);
        emit log_named_uint("surcharge, 1 adapter / 1 position", miss - noRegistry);

        assertLt(noRegistry, hit, "no registry must be cheapest");
        assertLt(hit, miss, "a hit must be cheaper than a miss (it skips the adapter staticcall)");
        // Measured ~5.1k. Bound just above it, so a second pair of reads (~+5k) breaks this.
        assertLt(miss - noRegistry, 8_000, "one distinct adapter must cost at most one pair of registry reads");
    }

    /// @dev **The only test that catches the per-position regression, and its bound is set from a MUTATION, not from
    ///      taste.** Two positions from ONE adapter: the lookup is cached at the `adapter != prevAdapter` boundary,
    ///      so the surcharge must stay one pair of registry reads per DISTINCT adapter.
    ///
    ///      ⚠️ **Re-measured when the segment-0-only category override became the per-segment
    ///      {IAssetKindRegistry.setAdapterLabels} array override, which made this leg genuinely more expensive.** The
    ///      registry read went from one flat `string` to a `string[]` behind the isolating decode shim, so the
    ///      surcharge rose from 9,790 to **15,343**, and the 12,000 bound below it had to move. That is a real cost
    ///      increase, not measurement noise, and it is stated rather than absorbed.
    ///
    ///      Both arms, on this tree: **15,343** clean vs **20,292** with the override read moved out of the cache
    ///      branch so it runs per position. The bound is **17,500** — above the honest number with room for compiler
    ///      drift, below the mutant. (History worth keeping: an earlier revision bounded this at 50,000 and therefore
    ///      PASSED under that exact mutation, so the regression it was written to catch shipped green. The bound is
    ///      set from the mutant every time for that reason.)
    function test_gas_surchargeIsPerAdapter_notPerPosition() public {
        LabelledAdapter multi = new LabelledAdapter("Multi Protocol", "Market", "leaf");
        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(dai);
        multi.setBalances(nav);
        multi.setUnderlyingAssetsSupported(assets);
        multi.setBalance(address(usdc), safe, 5 * 10 ** usdc.decimals(), false);
        multi.setBalance(address(dai), safe, 5 * 10 ** dai.decimals(), false);
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(multi)));
        nav.getAccountPositionsVerbose(safe, address(0)); // warm

        // Baseline FIRST, for the same ordering reason as above.
        bytes32 rslot = _registrySlot();
        uint256 saved = uint256(vm.load(address(nav), rslot));
        vm.store(address(nav), rslot, bytes32(0));
        uint256 before = gasleft();
        nav.getAccountPositionsVerbose(safe, address(0));
        uint256 noRegistry = before - gasleft();
        vm.store(address(nav), rslot, bytes32(saved));

        before = gasleft();
        nav.getAccountPositionsVerbose(safe, address(0));
        uint256 withRegistry = before - gasleft();

        uint256 surcharge = withRegistry - noRegistry;
        emit log_named_uint("surcharge, 2 adapters / 3 positions", surcharge);
        assertLt(surcharge, 17_500, "the surcharge must scale with DISTINCT ADAPTERS, not with positions");
    }

    /// @dev The hostile-registry ceiling the `_NAME_READ_GAS` docstring actually claims: a registry that burns its
    ///      whole stipend costs 2x{_NAME_READ_GAS} per DISTINCT adapter and no more, and the read still completes.
    ///      Nothing exercised this before, so the cited bound was asserted rather than measured.
    function test_gas_hostileRegistryIsBoundedByTheStipend() public {
        RawReplier burner = new RawReplier();
        burner.stageBurnGas();
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(burner));

        uint256 before = gasleft();
        INAVCalculator.VerbosePosition[] memory all = nav.getAccountPositionsVerbose(safe, address(0));
        uint256 used = before - gasleft();

        emit log_named_uint("verbose read gas, stipend-burning registry", used);
        // Fail-open still holds: the adapter's own values come back.
        bool found;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].position.balanceAdapter != address(adapter)) continue;
            found = true;
            assertEq(all[i].protocolName, "Mock Protocol", "a burning registry must fall back, not override");
        }
        assertTrue(found, "adapter position not found");
        // Two distinct adapters emit positions here (ERC20Default + ours), so the ceiling is 2 adapters x 2 reads x
        // 100k, plus the underlying read. Bounded well inside the verbose read's own budget.
        assertLt(used, 600_000, "a stipend-burning registry must stay inside 2x_NAME_READ_GAS per distinct adapter");
    }

    /// @dev The CONFIGURATION-path hostile-registry ceiling, which nothing exercised before. The `_NAME_READ_GAS`
    ///      docstring previously cited `test_gas_hostileRegistryIsBoundedByTheStipend` for this, but that test only
    ///      calls `getAccountPositionsVerbose` and never reaches `adapterDisplayInfo`.
    ///
    ///      The bound here is deliberately per-ARRAY-ENTRY, not per distinct adapter: {adapterDisplayInfo} has no
    ///      `prevAdapter` cache — it is a flat loop over the caller's array — so a caller passing the same adapter N
    ///      times pays N times. That is the honest shape of the ceiling and it is what this asserts.
    function test_gas_configurationSurface_hostileRegistryIsBounded() public {
        RawReplier burner = new RawReplier();
        burner.stageBurnGas();
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(burner));

        // Three entries, deliberately including a duplicate: the cost must track ENTRIES, not distinct adapters.
        address[] memory three = new address[](3);
        three[0] = address(adapter);
        three[1] = address(adapter);
        three[2] = address(usdc); // not an adapter at all; must still not revert

        uint256 before = gasleft();
        (string[] memory names, string[][] memory labels) = nav.getAdapterDisplayInfo(three);
        uint256 used = before - gasleft();
        emit log_named_uint("configuration surface gas, stipend-burning registry, 3 entries", used);

        // Fail-open: a burning registry must degrade to the adapter's own value, never revert the enumeration.
        assertEq(names.length, 3);
        assertEq(labels.length, 3);
        assertEq(names[0], "Mock Protocol", "burning registry must fall back to the adapter");
        assertEq(names[1], "Mock Protocol", "and on the duplicate entry too");
        assertEq(names[2], "", "a non-adapter address yields an empty name, not a revert");

        // Ceiling: 2 x _NAME_READ_GAS (100k) per ENTRY, plus the adapters' own reads. Bounded well inside it.
        assertLt(used, 3 * 2 * 100_000 + 400_000, "the configuration ceiling is 2x the stipend PER ENTRY");
    }

    /// @dev Never-revert on the configuration surface for inputs that are not adapters at all.
    function test_configurationSurface_neverRevertsOnHostileInput() public view {
        address[] memory odd = new address[](4);
        odd[0] = address(0);
        odd[1] = address(0xdead);
        odd[2] = address(nav);
        odd[3] = address(adapter);
        (string[] memory names, string[][] memory labels) = nav.getAdapterDisplayInfo(odd);
        assertEq(names.length, 4);
        assertEq(labels.length, 4);
        assertEq(names[3], "Mock Protocol", "the real adapter still resolves among the junk");
    }

    // ------------------------------------------------------------------
    // The two display SURFACES must agree
    // ------------------------------------------------------------------

    /// @dev **The surface-agreement invariant.** An override changes what `getAccountPositionsVerbose` reports. A
    ///      consumer that instead enumerates `getAllAdapters()` must see the SAME string, or the two surfaces
    ///      disagree silently about one adapter — the phantom-sibling split this whole feature exists to remove,
    ///      reintroduced between two views instead of between two adapters.
    ///
    ///      Asserted for BOTH an overridden adapter and an un-overridden one, so the test fails whether the
    ///      configuration path ignores the override OR wrongly applies one.
    function test_configurationAndPositionSurfaces_agree() public {
        LabelledAdapter other = new LabelledAdapter("Other Protocol", "Vault", "sUSDe");
        _register(other);

        vm.startPrank(navCalculatorManager);
        registry.setAdapterProtocolName(address(adapter), "Overridden Protocol");
        registry.setAdapterLabels(address(adapter), one("Lending Market"));
        vm.stopPrank();

        address[] memory all = nav.getAllAdapters();
        (string[] memory names, string[][] memory labels) = nav.getAdapterDisplayInfo(all);
        assertEq(names.length, all.length, "one name per adapter");
        assertEq(labels.length, all.length, "one breadcrumb per adapter");

        INAVCalculator.VerbosePosition[] memory verbose = nav.getAccountPositionsVerbose(safe, address(0));

        uint256 compared;
        for (uint256 i = 0; i < all.length; i++) {
            for (uint256 j = 0; j < verbose.length; j++) {
                if (verbose[j].position.balanceAdapter != all[i]) continue;
                assertEq(
                    names[i],
                    verbose[j].protocolName,
                    "configuration and position surfaces must report the SAME protocol name"
                );
                ++compared;
                break;
            }
        }
        assertGe(compared, 2, "must have compared at least the overridden and un-overridden adapters");

        // And the override is genuinely visible on the configuration surface, not merely equal by both being wrong.
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i] != address(adapter)) continue;
            assertEq(names[i], "Overridden Protocol", "the configuration surface must show the override");
            assertEq(labels[i][0], "Lending Market", "and the category override");
            assertEq(labels[i][1], "wstETH/USDC", "leaf still derived live");
        }
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i] != address(other)) continue;
            assertEq(names[i], "Other Protocol", "an un-overridden adapter still reports its own constant");
            assertEq(labels[i][0], "Vault", "and its own category");
        }
    }

    /// @dev The configuration surface must be fail-open too: a broken registry degrades to the adapter's constant
    ///      rather than reverting the whole enumeration.
    function test_configurationSurface_failsOpenOnBrokenRegistry() public {
        address broken = address(new RevertingRegistry());
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(broken);

        address[] memory all = nav.getAllAdapters();
        (string[] memory names,) = nav.getAdapterDisplayInfo(all);
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i] != address(adapter)) continue;
            assertEq(names[i], "Mock Protocol", "a broken registry must fall back on the configuration surface too");
        }
    }

    /// @dev With NO override, an adapter that describes nothing must yield an empty breadcrumb — never a grown array.
    function test_configurationSurface_emptyStaysEmptyWithoutOverride() public {
        NoLabelAdapter silent = new NoLabelAdapter();
        _register(silent);

        address[] memory one = new address[](1);
        one[0] = address(silent);
        (, string[][] memory labels) = nav.getAdapterDisplayInfo(one);
        assertEq(labels[0].length, 0, "no override means no breadcrumb");
    }

    /// @dev **The gap the first version of this feature shipped with.** Every meta-adapter answers
    ///      `positionLabels("")` with `[]`, so skipping the override on an empty reply (as the POSITION path
    ///      correctly does) meant a category set on a Morpho/Uniswap meta-adapter was visible on
    ///      `getAccountPositionsVerbose` and invisible on the configuration surface — the two surfaces disagreeing
    ///      about `labels[0]`, which is the very split this feature exists to close. The configuration path now
    ///      surfaces the override as a one-element breadcrumb.
    function test_configurationSurface_surfacesOverrideForMetaShapedAdapter() public {
        MetaShapedAdapter meta = new MetaShapedAdapter();
        _register(meta);

        address[] memory listed = new address[](1);
        listed[0] = address(meta);

        // Control: with no override, the configuration surface legitimately has no breadcrumb for this adapter.
        (, string[][] memory before) = nav.getAdapterDisplayInfo(listed);
        assertEq(before.length, 1);
        assertEq(before[0].length, 0, "control: a meta-shaped adapter has no positionId-independent breadcrumb");

        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(meta), one("Lending Market"));

        (, string[][] memory afterSet) = nav.getAdapterDisplayInfo(listed);
        assertEq(afterSet[0].length, 1, "the override must be surfaced, not dropped");
        assertEq(afterSet[0][0], "Lending Market", "and it must be the category the operator set");

        // And it must AGREE with what the position path reports at index 0 for the same adapter.
        INAVCalculator.VerbosePosition memory v = _verboseFor(address(meta));
        assertEq(v.labels[0], "Lending Market", "position path reports the same category");
        assertEq(v.labels[1], "steakUSDC", "leaf still derived live on the position path");
        assertEq(afterSet[0][0], v.labels[0], "the two surfaces must agree on labels[0]");
    }

    // ------------------------------------------------------------------
    // The other two toVerbose call sites
    // ------------------------------------------------------------------

    /// @dev `toVerbose` has THREE call sites and the diff changed all three, but every other test in this file reaches
    ///      only `getAccountPositionsVerbose`. Passing `address(0)` at either of the others — an easy slip, since that
    ///      is the documented "no registry" value — would silently drop every override on that entry point and leave
    ///      the whole suite green. These two tests close that.
    function test_override_appliesTo_getAccountNavVerbose() public {
        vm.startPrank(navCalculatorManager);
        registry.setAdapterProtocolName(address(adapter), "Overridden Protocol");
        registry.setAdapterLabels(address(adapter), one("Lending Market"));
        vm.stopPrank();

        INAVCalculator.VerboseNAV memory vn = nav.getAccountNavVerbose(safe, address(0));
        bool found;
        for (uint256 i = 0; i < vn.positions.length; i++) {
            if (vn.positions[i].position.balanceAdapter != address(adapter)) continue;
            found = true;
            assertEq(vn.positions[i].protocolName, "Overridden Protocol", "getAccountNavVerbose must apply overrides");
            assertEq(vn.positions[i].labels[0], "Lending Market", "and the category override too");
            assertEq(vn.positions[i].labels[1], "wstETH/USDC", "leaf still live");
        }
        assertTrue(found, "adapter position not found in getAccountNavVerbose");
    }

    function test_override_appliesTo_getAccountPositionsForAssetVerbose() public {
        vm.startPrank(navCalculatorManager);
        registry.setAdapterProtocolName(address(adapter), "Overridden Protocol");
        registry.setAdapterLabels(address(adapter), one("Lending Market"));
        vm.stopPrank();

        INAVCalculator.VerbosePosition[] memory all =
            nav.getAccountPositionsForAssetVerbose(safe, address(usdc), address(0));
        bool found;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].position.balanceAdapter != address(adapter)) continue;
            found = true;
            assertEq(all[i].protocolName, "Overridden Protocol", "ForAssetVerbose must apply overrides");
            assertEq(all[i].labels[0], "Lending Market", "and the category override too");
            assertEq(all[i].labels[1], "wstETH/USDC", "leaf still live");
        }
        assertTrue(found, "adapter position not found in getAccountPositionsForAssetVerbose");
    }

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    function test_setAdapterProtocolName_emits() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit IAssetKindRegistry.AdapterProtocolNameSet(address(adapter), "Overridden Protocol");
        vm.prank(navCalculatorManager);
        registry.setAdapterProtocolName(address(adapter), "Overridden Protocol");
    }

    function test_clearAdapterProtocolName_emits() public {
        vm.prank(navCalculatorManager);
        registry.setAdapterProtocolName(address(adapter), "Overridden Protocol");

        vm.expectEmit(true, false, false, true, address(registry));
        emit IAssetKindRegistry.AdapterProtocolNameCleared(address(adapter));
        vm.prank(navCalculatorManager);
        registry.clearAdapterProtocolName(address(adapter));
    }

    function test_setAdapterLabels_emits() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit IAssetKindRegistry.AdapterLabelsSet(address(adapter), one("Lending Market"));
        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(adapter), one("Lending Market"));
    }

    function test_clearAdapterLabels_emits() public {
        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(adapter), one("Lending Market"));

        vm.expectEmit(true, false, false, true, address(registry));
        emit IAssetKindRegistry.AdapterLabelsCleared(address(adapter));
        vm.prank(navCalculatorManager);
        registry.clearAdapterLabels(address(adapter));
    }

    // ------------------------------------------------------------------
    // Validator parity: the category setter must be guarded exactly like the name setter
    // ------------------------------------------------------------------

    function test_RevertIf_clearAdapterLabels_notManager() public {
        vm.expectRevert(NotAuthorized.selector);
        registry.clearAdapterLabels(address(adapter));
    }

    function test_RevertIf_setAdapterLabels_singleEmptyElement() public {
        vm.prank(navCalculatorManager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.EmptyAdapterOverride.selector, address(adapter)));
        registry.setAdapterLabels(address(adapter), one(""));
    }

    function test_RevertIf_setAdapterLabels_elementTooLong() public {
        string memory tooLong = "123456789012345678901234567890123"; // 33 bytes
        vm.prank(navCalculatorManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssetKindRegistry.AdapterLabelTooLong.selector, address(adapter), uint256(0), uint256(33), uint256(32)
            )
        );
        registry.setAdapterLabels(address(adapter), one(tooLong));
    }

    function test_setAdapterLabels_elementAtMaxLength() public {
        string memory exact = "12345678901234567890123456789012"; // 32 bytes
        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(adapter), one(exact));
        assertEq(_v().labels[0], exact);
    }

    // ------------------------------------------------------------------
    // DEPTH: the per-segment override
    // ------------------------------------------------------------------

    /// @dev **The load-bearing bound, against a reply whose length genuinely varies.** `VaryingLengthAdapter` is the
    ///      `ConvexCurveLPStakingMetaBalanceAdapter` shape: 2 segments when its leaf probe comes back empty, 3 when it
    ///      answers. A 3-element override must therefore write only 2 of them in the shallow state — writing index 2
    ///      of a 2-element array is `Panic(0x32)`, which would revert the whole verbose read and destroy the
    ///      never-revert property the label path is built on.
    ///
    ///      Both states are asserted in ONE test on purpose: the shallow arm proves the bound holds, and the deep arm
    ///      proves the bound is not simply dropping the third segment always. A test with only the shallow arm passes
    ///      against an implementation that ignores index 2 entirely.
    function test_labelsOverride_appliesOnlyWithinTheShorterArray() public {
        VaryingLengthAdapter varying = new VaryingLengthAdapter();
        _register(varying);

        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(varying), three("Staking Position", "Curve Pool", "OVERRIDDEN"));

        // Shallow: the adapter emits 2 segments, so the third override element must be inert — not a revert.
        INAVCalculator.VerbosePosition memory v = _verboseFor(address(varying));
        assertEq(v.labels.length, 2, "the override must not lengthen the reply");
        assertEq(v.labels[0], "Staking Position");
        assertEq(v.labels[1], "Curve Pool");

        // Deep: the same override now has a third segment to land on.
        varying.setDeep(true);
        v = _verboseFor(address(varying));
        assertEq(v.labels.length, 3, "the adapter, not the override, decides the length");
        assertEq(v.labels[0], "Staking Position");
        assertEq(v.labels[1], "Curve Pool");
        assertEq(v.labels[2], "OVERRIDDEN", "and the third element is genuinely applied when it exists");
    }

    /// @dev The same bound on the CONFIGURATION surface, which has its own branch and could regress independently.
    function test_labelsOverride_appliesOnlyWithinTheShorterArray_configurationSurface() public {
        VaryingLengthAdapter varying = new VaryingLengthAdapter();
        _register(varying);

        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(varying), three("Staking Position", "Curve Pool", "OVERRIDDEN"));

        string[] memory labels = _configLabels(address(varying));
        assertEq(labels.length, 2, "the configuration surface truncates to the adapter's reply too");
        assertEq(labels[0], "Staking Position");
        assertEq(labels[1], "Curve Pool");
    }

    /// @dev `""` means "leave this segment alone", which is the whole reason a COMPUTED leaf survives a category
    ///      correction. Asserted twice over: the leaf is right immediately, and it is still recomputed live afterwards
    ///      — a frozen copy would pass the first assertion and fail the second.
    function test_labelsOverride_emptyStringLeavesTheSegmentAlone() public {
        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(adapter), two("Lending Market", ""));

        INAVCalculator.VerbosePosition memory v = _v();
        assertEq(v.labels.length, 2);
        assertEq(v.labels[0], "Lending Market", "segment 0 replaced");
        assertEq(v.labels[1], "wstETH/USDC", "segment 1 skipped: the adapter's computed leaf stands");

        adapter.setLeaf("WETH/DAI");
        v = _v();
        assertEq(v.labels[0], "Lending Market");
        assertEq(v.labels[1], "WETH/DAI", "and it is still derived LIVE, not frozen at override time");
    }

    /// @dev The other direction: a `""` at index 0 leaves the adapter's own category and still writes the leaf. This
    ///      is what makes the skip a per-INDEX decision rather than a prefix-length one.
    function test_labelsOverride_emptyStringAtSegment0LeavesTheCategory() public {
        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(adapter), two("", "sUSDe (Ethena)"));

        INAVCalculator.VerbosePosition memory v = _v();
        assertEq(v.labels[0], "Market", "the adapter's own category is untouched");
        assertEq(v.labels[1], "sUSDe (Ethena)", "while the deeper segment IS replaced");
    }

    /// @dev The case the whole feature exists for: an adapter whose leaf is ALSO a literal, so both segments are
    ///      per-adapter constants and both are correctable. (`LidoWithdrawalQueueBalanceAdapter` is the real one:
    ///      `["Withdrawal Queue", "stETH"]`.)
    function test_labelsOverride_replacesEverySegmentWhenAllAreLiteral() public {
        LabelledAdapter queue = new LabelledAdapter("Lido", "Withdrawal Queue", "stETH");
        _register(queue);

        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(queue), two("Withdrawal Queue", "Lido stETH"));

        INAVCalculator.VerbosePosition memory v = _verboseFor(address(queue));
        assertEq(v.labels.length, 2);
        assertEq(v.labels[0], "Withdrawal Queue");
        assertEq(v.labels[1], "Lido stETH");
    }

    /// @dev An override longer than {AssetKindRegistry.MAX_ADAPTER_LABEL_SEGMENTS} is rejected at the setter, and one
    ///      at the bound is accepted but cannot lengthen a 2-element reply — so `NAVCalculator`'s
    ///      `_MAX_LABEL_ELEMENTS = 8` is unreachable from the registry side. This is the element-cap property stated
    ///      as an assertion instead of a comment.
    function test_labelsOverride_cannotLengthenAReplyPastTheElementCap() public {
        string[] memory eight = new string[](8);
        for (uint256 i; i < 8; ++i) {
            eight[i] = "seg";
        }
        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(adapter), eight);

        assertEq(_v().labels.length, 2, "the adapter emitted 2 segments, so 2 is what comes back");
        assertEq(_configLabels(address(adapter)).length, 2, "and the same on the configuration surface");
    }

    function test_RevertIf_setAdapterLabels_tooManySegments() public {
        string[] memory nine = new string[](9);
        for (uint256 i; i < 9; ++i) {
            nine[i] = "seg";
        }
        vm.prank(navCalculatorManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssetKindRegistry.TooManyAdapterLabels.selector, address(adapter), uint256(9), uint256(8)
            )
        );
        registry.setAdapterLabels(address(adapter), nine);
    }

    function test_setAdapterLabels_atMaxSegments() public {
        string[] memory eight = new string[](8);
        for (uint256 i; i < 8; ++i) {
            eight[i] = "seg";
        }
        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(adapter), eight);
        assertEq(registry.getAdapterLabels(address(adapter)).length, 8, "exactly at the bound must be accepted");
    }

    /// @dev An empty ARRAY and an array of only `""` are the same mistake — an override that overlays nothing at any
    ///      index and therefore reads back as absence. Both must be refused rather than silently stored, or a caller
    ///      trying to clear gets success for a request that did nothing.
    function test_RevertIf_setAdapterLabels_emptyArray() public {
        vm.prank(navCalculatorManager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.EmptyAdapterOverride.selector, address(adapter)));
        registry.setAdapterLabels(address(adapter), new string[](0));
    }

    function test_RevertIf_setAdapterLabels_allElementsEmpty() public {
        vm.prank(navCalculatorManager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.EmptyAdapterOverride.selector, address(adapter)));
        registry.setAdapterLabels(address(adapter), three("", "", ""));
    }

    /// @dev ...but an array with SOME empty elements is legitimate and must be stored verbatim, `""` included, since
    ///      the read path needs the positions to line up. A setter that compacted the skips would shift every later
    ///      segment.
    function test_setAdapterLabels_storesSkipSentinelsVerbatim() public {
        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(adapter), three("", "Leaf", ""));

        string[] memory stored = registry.getAdapterLabels(address(adapter));
        assertEq(stored.length, 3, "the skips occupy their indices");
        assertEq(stored[0], "");
        assertEq(stored[1], "Leaf");
        assertEq(stored[2], "");
    }

    /// @dev The index must be reported, not just "one of them is too long" — with eight candidate segments the
    ///      scalar error's payload is not actionable. Asserted at a NON-ZERO index so a hardcoded 0 fails.
    function test_RevertIf_setAdapterLabels_elementTooLong_namesTheIndex() public {
        string memory tooLong = "123456789012345678901234567890123"; // 33 bytes
        vm.prank(navCalculatorManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssetKindRegistry.AdapterLabelTooLong.selector, address(adapter), uint256(1), uint256(33), uint256(32)
            )
        );
        registry.setAdapterLabels(address(adapter), two("Fine", tooLong));
    }

    // ------------------------------------------------------------------
    // DEPTH: the two surfaces must agree at EVERY segment
    // ------------------------------------------------------------------

    /// @dev **The surface-agreement invariant, at depth.** Both display paths overlay through the same
    ///      `PriceFeedLib._applyLabelOverride`, so they cannot report different segments for one adapter. Asserted
    ///      element-by-element over the whole array — not just `labels[0]` — because the array override is exactly
    ///      what makes a deeper disagreement possible for the first time.
    function test_bothSurfaces_agreeOnEverySegment() public {
        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(adapter), two("Lending Market", ""));

        string[] memory position = _v().labels;
        string[] memory config = _configLabels(address(adapter));

        assertEq(config.length, position.length, "the two surfaces must agree on the ARRAY LENGTH");
        assertGt(position.length, 1, "control: there is more than one segment to disagree about");
        for (uint256 i; i < position.length; ++i) {
            assertEq(config[i], position[i], "the two surfaces must agree at every segment");
        }
        // ...and agree on the right values, not merely on the same wrong ones.
        assertEq(position[0], "Lending Market");
        assertEq(position[1], "wstETH/USDC");
    }

    /// @dev The empty-reply divergence, PRESERVED. The position path leaves an adapter that described nothing empty;
    ///      the configuration path grows it, because there the operator's answer is the whole answer. Skipping the
    ///      grow left the two surfaces disagreeing for 21 of 33 adapters, so this is pinned rather than assumed.
    ///
    ///      What the array override adds: the grown array is the override's LEADING NON-EMPTY PREFIX, so a trailing
    ///      `""` is dropped rather than rendered as a blank segment. An implementation that copied the whole override
    ///      answers length 2 here with `labels[1] == ""`.
    function test_configurationSurface_growsEmptyReplyToLeadingNonEmptyPrefixOnly() public {
        MetaShapedAdapter meta = new MetaShapedAdapter();
        _register(meta);

        assertEq(_configLabels(address(meta)).length, 0, "control: no breadcrumb without an override");

        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(meta), two("Lending Market", ""));

        string[] memory config = _configLabels(address(meta));
        assertEq(config.length, 1, "the trailing skip must NOT be surfaced as a blank segment");
        assertEq(config[0], "Lending Market");

        // The position path still leaves the EMPTY reply alone (its `positionLabels("")` is what was empty), while a
        // real positionId gets the overlay — the deliberate asymmetry, both halves in one place.
        INAVCalculator.VerbosePosition memory v = _verboseFor(address(meta));
        assertEq(v.labels.length, 2, "the position path sees a real 2-segment reply");
        assertEq(v.labels[0], "Lending Market", "and agrees with the configuration surface at segment 0");
        assertEq(v.labels[1], "steakUSDC", "leaf still derived live");
    }

    /// @dev The grow must stop at the FIRST empty element, not skip past it. An override of `["", "Curve Pool"]` on an
    ///      adapter with no breadcrumb must grow to NOTHING: promoting `"Curve Pool"` to index 0 would put it at an
    ///      index the position path never shows it at, which is the surface disagreement in a new costume.
    function test_configurationSurface_skippedSegment0GrowsNothing() public {
        MetaShapedAdapter meta = new MetaShapedAdapter();
        _register(meta);

        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(meta), two("", "Curve Pool"));

        assertEq(_configLabels(address(meta)).length, 0, "a skipped segment 0 must not be filled from below");
    }

    /// @dev Every segment of a multi-segment override reaches the configuration surface when the adapter has nothing
    ///      to say — the counterpart of the test above, so "grow to the prefix" is not read as "grow to one".
    function test_configurationSurface_growsToTheWholeOverrideWhenNoneAreSkipped() public {
        MetaShapedAdapter meta = new MetaShapedAdapter();
        _register(meta);

        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(meta), two("Withdrawal Queue", "Lido stETH"));

        string[] memory config = _configLabels(address(meta));
        assertEq(config.length, 2);
        assertEq(config[0], "Withdrawal Queue");
        assertEq(config[1], "Lido stETH");
    }

    // ------------------------------------------------------------------
    // DEPTH: gas — read ONCE PER ADAPTER, not per position
    // ------------------------------------------------------------------

    /// @dev **The array override must stay a per-ADAPTER cost.** It is fetched in the same `adapter != prevAdapter`
    ///      branch that already caches `protocolName()`, so a two-position adapter must pay for one read, not two.
    ///      Moving `_labelOverride` into the loop body is the regression this catches, and the bound below is set
    ///      from that MUTATION rather than from taste — the precedent being
    ///      `test_gas_surchargeIsPerAdapter_notPerPosition`, whose original 50,000 bound passed under the exact
    ///      mutation it was written to catch.
    ///
    ///      Measured on this tree, both arms: **20,746 cached** vs **30,033** with `_labelOverride` moved out of the
    ///      `adapter != prevAdapter` branch and into the loop body. The bound is **25,000** — above the honest number
    ///      with room for compiler drift, and comfortably below the mutant. (An earlier revision of this line quoted
    ///      "12,349 vs 19,469"; those numbers were never measured and the 15,000 bound derived from them failed
    ///      against the honest tree. Recorded rather than quietly replaced, because a fabricated measurement in a
    ///      comment is the exact failure this file's other gas notes keep warning about.)
    function test_gas_labelOverride_isPerAdapter_notPerPosition() public {
        LabelledAdapter multi = new LabelledAdapter("Multi Protocol", "Market", "leaf");
        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(dai);
        multi.setBalances(nav);
        multi.setUnderlyingAssetsSupported(assets);
        multi.setBalance(address(usdc), safe, 5 * 10 ** usdc.decimals(), false);
        multi.setBalance(address(dai), safe, 5 * 10 ** dai.decimals(), false);
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(multi)));

        vm.prank(navCalculatorManager);
        registry.setAdapterLabels(address(multi), two("Lending Market", ""));
        nav.getAccountPositionsVerbose(safe, address(0)); // warm

        // Baseline FIRST — memory cost is quadratic in the frame total, so measuring it last biases it upward and the
        // surcharge downward. Same ordering discipline as the tests above.
        bytes32 rslot = _registrySlot();
        uint256 saved = uint256(vm.load(address(nav), rslot));
        vm.store(address(nav), rslot, bytes32(0));
        uint256 before = gasleft();
        nav.getAccountPositionsVerbose(safe, address(0));
        uint256 noRegistry = before - gasleft();
        vm.store(address(nav), rslot, bytes32(saved));

        before = gasleft();
        nav.getAccountPositionsVerbose(safe, address(0));
        uint256 withRegistry = before - gasleft();

        uint256 surcharge = withRegistry - noRegistry;
        emit log_named_uint("label-override surcharge, 2 adapters / 3 positions", surcharge);
        assertLt(surcharge, 25_000, "the override read must scale with DISTINCT ADAPTERS, not with positions");

        // And it must still be CORRECT on every position, so a "cheap" mutant that drops the override cannot pass by
        // being fast.
        INAVCalculator.VerbosePosition[] memory all = nav.getAccountPositionsVerbose(safe, address(0));
        uint256 seen;
        for (uint256 i; i < all.length; ++i) {
            if (all[i].position.balanceAdapter != address(multi)) continue;
            ++seen;
            assertEq(all[i].labels[0], "Lending Market");
            assertEq(all[i].labels[1], "leaf");
        }
        assertEq(seen, 2, "two positions, or the cache-hit path was not exercised");
    }
}

/// @notice The same read path with NO registry wired at all — the state of every NAV before `08` runs, and the state
///         the rest of the suite exercises by default.
contract AdapterLabelOverridesNoRegistryTest is AdapterLabelOverridesBase {
    function setUp() public {
        setupAll();
        adapter = new LabelledAdapter("Mock Protocol", "Market", "wstETH/USDC");
        _register(adapter);
    }

    /// @dev A zero registry must short-circuit, not revert and not degrade: the verbose read returns exactly the
    ///      adapter's own name and labels.
    function test_zeroRegistry_verboseReadIsUnchanged() public view {
        assertEq(address(nav.assetKindRegistry()), address(0), "precondition: no registry wired");

        INAVCalculator.VerbosePosition memory v = _v();
        assertEq(v.protocolName, "Mock Protocol");
        assertEq(v.labels.length, 2);
        assertEq(v.labels[0], "Market");
        assertEq(v.labels[1], "wstETH/USDC");
    }
}
