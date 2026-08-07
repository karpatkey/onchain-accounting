// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IAssetKindRegistry} from "src/nav/IAssetKindRegistry.sol";
import {AssetKindRegistry} from "src/nav/AssetKindRegistry.sol";
import {aa} from "test/helpers/AdapterArray.sol";
import {Mock_CustomBalanceAdapter} from "test/mocks/balance_adapters.sol";

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

/// @notice The `CapBalanceAdapter` shape: index 0 is a LITERAL, but a DIFFERENT literal per positionId. A per-adapter
///         override cannot express that, which is why Cap is excluded.
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
            asset: asset,
            symbol: IERC20Metadata(asset).symbol(),
            decimals: IERC20Metadata(asset).decimals()
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

    function getAdapterLabelCategory(address) external pure returns (string memory) {
        return string(new bytes(5000));
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
}

contract AdapterLabelOverridesTest is AdapterLabelOverridesBase {
    AssetKindRegistry internal registry;

    function setUp() public {
        setupAll();
        registry = new AssetKindRegistry(address(nav));
        // NOTE: deliberately NO `grantRole(MANAGER, registry)`, unlike the asset-kind tests. These overrides never
        // call back into the NAV, so they need no privilege at all — `test_overrides_needNoRoleGrant` pins that.
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));

        adapter = new LabelledAdapter("Mock Protocol", "Market", "wstETH/USDC");
        _register(adapter);
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

    function test_categoryOverride_replacesCategoryAndPreservesComputedLeaf() public {
        INAVCalculator.VerbosePosition memory v = _v();
        assertEq(v.labels.length, 2);
        assertEq(v.labels[0], "Market", "baseline category");
        assertEq(v.labels[1], "wstETH/USDC", "baseline leaf");

        vm.prank(navCalculatorManager);
        registry.setAdapterLabelCategory(address(adapter), "Lending Market");

        v = _v();
        assertEq(v.labels.length, 2, "the override must not change the array length");
        assertEq(v.labels[0], "Lending Market", "category must be overridden");
        assertEq(v.labels[1], "wstETH/USDC", "the COMPUTED LEAF must be untouched");
    }

    /// @dev The load-bearing claim of the whole design: the leaf stays LIVE. With a category override in place, a
    ///      change in the adapter's derived leaf must still flow through. A table that froze the leaf would fail this.
    function test_categoryOverride_leafStaysLive() public {
        vm.prank(navCalculatorManager);
        registry.setAdapterLabelCategory(address(adapter), "Lending Market");

        adapter.setLeaf("WETH/DAI");

        INAVCalculator.VerbosePosition memory v = _v();
        assertEq(v.labels[0], "Lending Market", "category still overridden");
        assertEq(v.labels[1], "WETH/DAI", "the leaf must be recomputed live, never frozen");
    }

    function test_categoryOverride_clearRestoresAdapterCategory() public {
        vm.startPrank(navCalculatorManager);
        registry.setAdapterLabelCategory(address(adapter), "Lending Market");
        assertEq(_v().labels[0], "Lending Market");
        registry.clearAdapterLabelCategory(address(adapter));
        vm.stopPrank();

        assertEq(_v().labels[0], "Market", "clearing must fall back to the adapter");
    }

    /// @dev An adapter that describes no segments has no category to correct. The override must leave the empty
    ///      reply empty rather than growing it to length 1.
    function test_categoryOverride_doesNotGrowAnEmptyLabelSet() public {
        NoLabelAdapter silent = new NoLabelAdapter();
        _register(silent);

        vm.prank(navCalculatorManager);
        registry.setAdapterLabelCategory(address(silent), "Invented Category");

        assertEq(_verboseFor(address(silent)).labels.length, 0, "an empty reply must stay empty");
    }

    /// @dev The documented hazard, asserted rather than assumed. `ERC20DefaultBalanceAdapter`'s shape is a single
    ///      element that IS the computed leaf, so an override there replaces the leaf. The mechanism sees an array,
    ///      not the source, and cannot tell a category from a leaf — hence the exclusion is operational, not enforced.
    function test_categoryOverride_onLeafOnlyAdapter_replacesTheLeaf_documentedHazard() public {
        LeafOnlyAdapter leafOnly = new LeafOnlyAdapter();
        _register(leafOnly);

        assertEq(_verboseFor(address(leafOnly)).labels[0], "USDC");

        vm.prank(navCalculatorManager);
        registry.setAdapterLabelCategory(address(leafOnly), "Wallet Balance");

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
        registry.setAdapterLabelCategory(address(adapter), "Lending Market");

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
        registry.setAdapterLabelCategory(address(adapter), "Lending Market");
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

    function test_RevertIf_setAdapterLabelCategory_notManager() public {
        vm.expectRevert(NotAuthorized.selector);
        registry.setAdapterLabelCategory(address(adapter), "Nope");
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

    function test_RevertIf_setAdapterLabelCategory_unregisteredAdapter() public {
        address ghost = makeAddr("ghost");
        vm.prank(navCalculatorManager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.AdapterNotRegistered.selector, ghost));
        registry.setAdapterLabelCategory(ghost, "Ghost Category");
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

    function test_RevertIf_clearAdapterLabelCategory_notSet() public {
        vm.prank(navCalculatorManager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.AdapterOverrideNotSet.selector, address(adapter)));
        registry.clearAdapterLabelCategory(address(adapter));
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
        assertEq(registry.getAdapterLabelCategory(address(adapter)), "");
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
        registry.setAdapterLabelCategory(address(multi), "Lending Market");
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

    /// @dev The second documented exclusion, asserted rather than assumed. `CapBalanceAdapter` emits a DIFFERENT
    ///      literal at index 0 per position, so one per-adapter override necessarily rewrites both legs. This is why
    ///      Cap must not be given a category override, and it is a distinct reason from `ERC20DefaultBalanceAdapter`'s.
    function test_categoryOverride_onPerPositionCategoryAdapter_rewritesBothLegs_documentedHazard() public {
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
        registry.setAdapterLabelCategory(address(cap), "Synthetic Dollar");

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

    /// @dev The honest measurement behind the docstring. The MISS path (no override) is the common case and is
    ///      strictly more expensive than before, because it pays the registry reads on top of the adapter call. This
    ///      bounds that surcharge rather than claiming it away, and it is the test the `PriceFeedLib.toVerbose`
    ///      docstring points at.
    function test_gas_registryLegIsBounded() public {
        // Warm the read once so the comparison is not dominated by first-touch storage costs.
        _v();

        uint256 before = gasleft();
        nav.getAccountPositionsVerbose(safe, address(0));
        uint256 withRegistry = before - gasleft();

        vm.prank(navCalculatorManager);
        registry.setAdapterProtocolName(address(adapter), "Overridden Protocol");

        before = gasleft();
        nav.getAccountPositionsVerbose(safe, address(0));
        uint256 withOverride = before - gasleft();

        // Both must stay far inside the verbose read's own ceiling; the registry leg is two capped staticcalls per
        // distinct adapter, so it cannot approach the 100k stipend it is bounded by.
        assertLt(withRegistry, 1_000_000, "the miss path must stay bounded");
        assertLt(withOverride, 1_000_000, "the hit path must stay bounded");
        emit log_named_uint("verbose read gas, override MISS", withRegistry);
        emit log_named_uint("verbose read gas, override HIT ", withOverride);
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

    function test_setAdapterLabelCategory_emits() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit IAssetKindRegistry.AdapterLabelCategorySet(address(adapter), "Lending Market");
        vm.prank(navCalculatorManager);
        registry.setAdapterLabelCategory(address(adapter), "Lending Market");
    }

    function test_clearAdapterLabelCategory_emits() public {
        vm.prank(navCalculatorManager);
        registry.setAdapterLabelCategory(address(adapter), "Lending Market");

        vm.expectEmit(true, false, false, true, address(registry));
        emit IAssetKindRegistry.AdapterLabelCategoryCleared(address(adapter));
        vm.prank(navCalculatorManager);
        registry.clearAdapterLabelCategory(address(adapter));
    }

    // ------------------------------------------------------------------
    // Validator parity: the category setter must be guarded exactly like the name setter
    // ------------------------------------------------------------------

    function test_RevertIf_clearAdapterLabelCategory_notManager() public {
        vm.expectRevert(NotAuthorized.selector);
        registry.clearAdapterLabelCategory(address(adapter));
    }

    function test_RevertIf_setAdapterLabelCategory_empty() public {
        vm.prank(navCalculatorManager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.EmptyAdapterOverride.selector, address(adapter)));
        registry.setAdapterLabelCategory(address(adapter), "");
    }

    function test_RevertIf_setAdapterLabelCategory_tooLong() public {
        string memory tooLong = "123456789012345678901234567890123"; // 33 bytes
        vm.prank(navCalculatorManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssetKindRegistry.AdapterOverrideTooLong.selector, address(adapter), uint256(33), uint256(32)
            )
        );
        registry.setAdapterLabelCategory(address(adapter), tooLong);
    }

    function test_setAdapterLabelCategory_atMaxLength() public {
        string memory exact = "12345678901234567890123456789012"; // 32 bytes
        vm.prank(navCalculatorManager);
        registry.setAdapterLabelCategory(address(adapter), exact);
        assertEq(_v().labels[0], exact);
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
