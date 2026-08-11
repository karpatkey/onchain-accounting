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

/// @dev ERC-1967 implementation slot (`keccak256("eip1967.proxy.implementation") - 1`). Used to locate the UUPS
///      implementation behind the NAV proxy so `_coolAll` can cool it: it is a separate account, and the proxy's
///      first DELEGATECALL into it on a fresh call pays a cold-account premium.
bytes32 constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

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

    /// @dev **EVERY gas figure in this file is measured through one of these two helpers, and that is load-bearing.**
    ///      Measuring several arms sequentially in ONE frame does not put them on equal footing: each call's dynamic
    ///      return (`string[]`, `string[][]`, `VerbosePosition[]`) is ABI-decoded into the CALLER's memory, advancing
    ///      the free-memory pointer, and memory cost is quadratic in the frame total. So every successive arm pays
    ///      more expansion than the last for identical work. Measured on this fixture, repeating the SAME call:
    ///
    ///        same frame    display   493,378 -> 498,752   (+1,343 per call)
    ///                      account 2,154,364 -> 2,215,762 (+20,466 per call)
    ///        fresh frame   display   491,676 every time, account 2,093,268 every time -- bit-identical
    ///
    ///      An external call gets a fresh memory region, so the measurement inside is independent of whatever the
    ///      test frame already allocated. `vm.cool` / `vm.store` are applied OUTSIDE, before entering: account
    ///      warmth and storage are frame-independent, memory is not.
    ///
    ///      ⚠️ **Do not inline `gasleft()` around a call in a test body.** The inline form silently attributes the
    ///      harness's own memory growth to the code under test: it put ~20,500 of drift into the account-path
    ///      surcharge and ~61,000 into its absolute total, and no assertion in this file would have caught it.
    function measureVerbose(address account) external view returns (uint256 used) {
        uint256 t = gasleft();
        nav.getAccountPositionsVerbose(account, address(0));
        used = t - gasleft();
    }

    /// @dev Configuration-surface counterpart of {measureVerbose}; see there for why the fresh frame is required.
    function measureDisplay(address[] calldata adapters) external view returns (uint256 used) {
        uint256 t = gasleft();
        nav.getAdapterDisplayInfo(adapters);
        used = t - gasleft();
    }

    /// @dev Measures the registry surcharge against a real no-registry baseline.
    ///
    ///      Arm ORDER no longer biases anything: each arm is measured in its own frame via {measureVerbose}, so the
    ///      memory baseline is identical for all three. (An earlier revision had to measure the baseline first to
    ///      limit that bias; with fresh frames the ordering is free.)
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
        uint256 noRegistry = this.measureVerbose(safe);
        vm.store(address(nav), rslot, bytes32(saved));

        uint256 miss = this.measureVerbose(safe);

        vm.prank(navCalculatorManager);
        registry.setAdapterProtocolName(address(adapter), "Overridden Protocol");
        uint256 hit = this.measureVerbose(safe);

        emit log_named_uint("verbose read gas, NO registry ", noRegistry);
        emit log_named_uint("verbose read gas, override HIT", hit);
        emit log_named_uint("verbose read gas, override MISS", miss);
        emit log_named_uint("surcharge, 1 adapter / 1 position", miss - noRegistry);

        assertLt(noRegistry, hit, "no registry must be cheapest");
        assertLt(hit, miss, "a hit must be cheaper than a miss (it skips the adapter staticcall)");
        // Bound derived from the second-pair mutant (duplicate the two lookups inside the cache branch), which is
        // exactly the regression this message names: clean 5,311 PASS / mutant 10,623 FAIL / bound 8,000.
        assertLt(miss - noRegistry, 8_000, "one distinct adapter must cost at most one pair of registry reads");
    }

    /// @dev **Catches the per-position regression WARM, with its bound set from a MUTATION, not from taste.** Two
    ///      positions from ONE adapter: the lookup is cached at the `adapter != prevAdapter` boundary, so the
    ///      surcharge must stay one pair of registry reads per DISTINCT adapter. `test_gas_coldVsWarm_twoAdapters` is
    ///      the COLD counterpart; between them the caching property is defended warm and cold, and nothing else in
    ///      this file defends it.
    ///
    ///      Measured on clean HEAD: 10,650. Measured with the lookup moved out of the cache branch so it runs per
    ///      position: 15,978. An earlier revision bounded this at 50,000 and therefore passed under that exact
    ///      mutation — the regression it was written to catch shipped green. The bound is 12,000: above the honest
    ///      number, below the mutant, with ~13% of headroom. ⚠️ When this goes red, RE-DERIVE the bound from the
    ///      mutant; do not simply raise it. Raising a bound to make a test pass is how the 50,000 above, the 34,000
    ///      on the cold counterpart and the 20,000 on {test_gas_coldVsWarm_oneAdapter} all came to enforce nothing.
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

        bytes32 rslot = _registrySlot();
        uint256 saved = uint256(vm.load(address(nav), rslot));
        vm.store(address(nav), rslot, bytes32(0));
        uint256 noRegistry = this.measureVerbose(safe);
        vm.store(address(nav), rslot, bytes32(saved));

        uint256 withRegistry = this.measureVerbose(safe);

        uint256 surcharge = withRegistry - noRegistry;
        emit log_named_uint("surcharge, 2 adapters / 3 positions", surcharge);
        assertLt(surcharge, 12_000, "the surcharge must scale with DISTINCT ADAPTERS, not with positions");
    }

    /// @dev The hostile-registry ceiling the `_NAME_READ_GAS` docstring actually claims: a registry that burns its
    ///      whole stipend costs 2x{_NAME_READ_GAS} per DISTINCT adapter and no more, and the read still completes.
    ///      Nothing exercised this before, so the cited bound was asserted rather than measured.
    function test_gas_hostileRegistryIsBoundedByTheStipend() public {
        RawReplier burner = new RawReplier();
        burner.stageBurnGas();
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(burner));

        // Gas in its own frame; the returned data is fetched separately, since only the CONTENT is asserted on.
        uint256 used = this.measureVerbose(safe);
        INAVCalculator.VerbosePosition[] memory all = nav.getAccountPositionsVerbose(safe, address(0));

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
        assertLt(
            used,
            2 * 2 * 100_000 + 200_000,
            "a stipend-burning registry must stay inside 2x_NAME_READ_GAS per distinct adapter, plus the underlying read"
        );
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

        uint256 used = this.measureDisplay(three);
        (string[] memory names, string[][] memory labels) = nav.getAdapterDisplayInfo(three);
        emit log_named_uint("configuration surface gas, stipend-burning registry, 3 entries", used);

        // Fail-open: a burning registry must degrade to the adapter's own value, never revert the enumeration.
        assertEq(names.length, 3);
        assertEq(labels.length, 3);
        assertEq(names[0], "Mock Protocol", "burning registry must fall back to the adapter");
        assertEq(names[1], "Mock Protocol", "and on the duplicate entry too");
        assertEq(names[2], "", "a non-adapter address yields an empty name, not a revert");

        // Ceiling: 2 x _NAME_READ_GAS (100k) per ENTRY, plus the adapters' own reads. Bounded well inside it.
        assertLt(
            used,
            3 * 2 * 100_000 + 400_000,
            "the configuration ceiling is 2x the stipend PER ENTRY, plus the adapters' own reads"
        );
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
        registry.setAdapterLabelCategory(address(adapter), "Lending Market");
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
    function test_configurationSurface_surfacesCategoryForMetaShapedAdapter() public {
        MetaShapedAdapter meta = new MetaShapedAdapter();
        _register(meta);

        address[] memory one = new address[](1);
        one[0] = address(meta);

        // Control: with no override, the configuration surface legitimately has no breadcrumb for this adapter.
        (, string[][] memory before) = nav.getAdapterDisplayInfo(one);
        assertEq(before.length, 1);
        assertEq(before[0].length, 0, "control: a meta-shaped adapter has no positionId-independent breadcrumb");

        vm.prank(navCalculatorManager);
        registry.setAdapterLabelCategory(address(meta), "Lending Market");

        (, string[][] memory afterSet) = nav.getAdapterDisplayInfo(one);
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
        registry.setAdapterLabelCategory(address(adapter), "Lending Market");
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
        registry.setAdapterLabelCategory(address(adapter), "Lending Market");
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

    /// @dev COLD-SLOT measurement. Every other gas test here warms the read first, so its surcharge is a FLOOR: a
    ///      real portfolio touches each adapter's registry slots cold. `vm.cool(registry)` marks the registry's
    ///      storage SLOTS cold again, which is the only clean way to produce that state inside one test transaction
    ///      (EIP-2929 warmth otherwise persists for the whole call frame). It does NOT restore the cold-ACCOUNT
    ///      premium, despite its forge-std docstring -- see `_coolAll` for the measurement -- so this surcharge, like
    ///      every other cold figure in this file, is slots-only and remains a floor on what a fresh call pays.
    ///
    ///      All three measurements share an identical baseline: the adapters are warmed once up front and are never
    ///      cooled, so the ONLY thing that differs between warm and cold is the registry. That isolation is what
    ///      makes the delta attributable.
    function test_gas_coldVsWarm_oneAdapter() public {
        nav.getAccountPositionsVerbose(safe, address(0)); // warm everything

        bytes32 rslot = _registrySlot();
        uint256 saved = uint256(vm.load(address(nav), rslot));

        // Baseline: registry not consulted at all. Adapters warm.
        vm.store(address(nav), rslot, bytes32(0));
        uint256 base = this.measureVerbose(safe);
        vm.store(address(nav), rslot, bytes32(saved));

        // Registry WARM (its slots were touched by the warm-up read).
        uint256 warm = this.measureVerbose(safe);

        // Registry COLD. Cooled OUTSIDE the measured frame -- warmth is frame-independent, memory is not.
        vm.cool(address(registry));
        uint256 cold = this.measureVerbose(safe);

        emit log_named_uint("1 adapter | baseline no-registry ", base);
        emit log_named_uint("1 adapter | surcharge WARM       ", warm - base);
        emit log_named_uint("1 adapter | surcharge COLD       ", cold - base);
        emit log_named_uint("1 adapter | cold premium         ", cold - warm);

        assertGt(cold, warm, "a cold registry must cost more than a warm one");
        // Bound set FROM A MUTANT, not from taste. The mutant is a second pair of registry reads per distinct adapter
        // (duplicate the two lookups inside the `adapter != prevAdapter` branch) -- precisely the regression this
        // message names. An earlier 20,000 passed under it (mutant 14,719) and so enforced nothing:
        //   clean 9,311 PASS / mutant 14,623 FAIL / bound 12,000.
        assertLt(cold - base, 12_000, "one distinct adapter, cold, must stay within one pair of cold reads");
    }

    /// @dev The same, with TWO distinct adapters emitting three positions, so the per-DISTINCT-ADAPTER property is
    ///      testable cold as well as warm. The bound is what the mutation below has to break.
    function test_gas_coldVsWarm_twoAdapters() public {
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

        nav.getAccountPositionsVerbose(safe, address(0)); // warm everything

        bytes32 rslot = _registrySlot();
        uint256 saved = uint256(vm.load(address(nav), rslot));

        vm.store(address(nav), rslot, bytes32(0));
        uint256 base = this.measureVerbose(safe);
        vm.store(address(nav), rslot, bytes32(saved));

        uint256 warm = this.measureVerbose(safe);

        vm.cool(address(registry));
        uint256 cold = this.measureVerbose(safe);

        emit log_named_uint("2 adapters/3 positions | baseline ", base);
        emit log_named_uint("2 adapters/3 positions | WARM     ", warm - base);
        emit log_named_uint("2 adapters/3 positions | COLD     ", cold - base);
        emit log_named_uint("2 adapters/3 positions | premium  ", cold - warm);

        assertGt(cold, warm, "cold must exceed warm");
        // Cold surcharge must still scale with DISTINCT ADAPTERS, not positions. A per-position lookup on this
        // 3-position fixture inflates it past this bound -- which the mutation test proves.
        // Bound set FROM THE MUTATION, not from taste: clean 18,650 / per-position mutant 23,978.
        // An earlier 34,000 passed under that mutant and was therefore worthless.
        assertLt(cold - base, 22_000, "cold surcharge must scale with distinct adapters, not positions");
    }

    /// @dev The BENIGN path of the configuration surface. Only its hostile-registry ceiling was ever measured, which
    ///      is not much use to an operator.
    ///
    ///      ⚠️ This fixture registers only TWO adapters, so a full enumeration here is N=2 and dividing its total by
    ///      2 would attribute fixed call overhead to each entry. The MARGINAL per-entry cost is measured separately
    ///      below by comparing N=2 against N=27 (mainnet's registered-adapter count per the fork rehearsal), padding
    ///      with repeated addresses. Repeats are warm after the first touch, so that marginal figure is a WARM
    ///      per-entry loop cost and a floor, not a cold one.
    function test_gas_configurationSurface_benignPath() public {
        address[] memory all = nav.getAllAdapters();

        // Warm, then measure a full enumeration. Every emit is deferred until after the last measurement -- see
        // {measureVerbose}; an emit allocates its message and would shift the frame the measurements sit in.
        nav.getAdapterDisplayInfo(all);
        uint256 warm = this.measureDisplay(all);

        vm.cool(address(registry));
        uint256 cold = this.measureDisplay(all);

        emit log_named_uint("configuration surface | adapters actually registered in fixture", all.length);
        emit log_named_uint("configuration surface | WARM, full enumeration", warm);
        emit log_named_uint("configuration surface | COLD, full enumeration", cold);
        emit log_named_uint("configuration surface | per entry WARM        ", warm / all.length);
        emit log_named_uint("configuration surface | per entry COLD        ", cold / all.length);
        assertGt(cold, warm, "cold enumeration must cost more than warm");
    }

    /// @dev Marginal per-ENTRY cost of the configuration surface: N=2 vs N=27, so fixed call overhead cancels.
    function test_gas_configurationSurface_marginalPerEntry() public {
        address[] memory all = nav.getAllAdapters();
        address[] memory pad = new address[](27);
        for (uint256 i = 0; i < 27; i++) {
            pad[i] = all[i % all.length];
        }
        nav.getAdapterDisplayInfo(all);
        nav.getAdapterDisplayInfo(pad); // warm both shapes

        uint256 gN = this.measureDisplay(all);
        uint256 g27 = this.measureDisplay(pad);

        emit log_named_uint("config surface | N=2  total ", gN);
        emit log_named_uint("config surface | N=27 total ", g27);
        emit log_named_uint("config surface | MARGINAL per entry (warm)", (g27 - gN) / (27 - all.length));
        assertGt(g27, gN, "more entries must cost more");
    }

    /// @dev Registers distinct adapters until the NAV holds `target` of them, returning the full set.
    ///      Each is a SEPARATE contract, so each occupies its own registry mapping slots -- which is the whole point:
    ///      repeated addresses are warm after the first touch and understate a real enumeration.
    function _growTo(uint256 target) internal returns (address[] memory) {
        while (nav.getAllAdapters().length < target) {
            LabelledAdapter a = new LabelledAdapter("Proto", "Market", "leaf");
            _register(a);
        }
        return nav.getAllAdapters();
    }

    /// @dev Cools every account a NAV read touches whose warmth this fixture controls: the registry, the supplied
    ///      adapters, the NAV PROXY (its own slots are read on every call and were previously left warm -- cooling
    ///      them is worth a measured 4,000 exactly, two cold-SLOAD deltas), and the two accounts it DELEGATECALLs into,
    ///      the UUPS implementation and the externally linked `PriceFeedLib` (`getAdapterDisplayInfo` is a single
    ///      forward into it).
    ///
    ///      ⚠️ **`vm.cool` cools SLOTS ONLY in forge 1.7.1, despite its forge-std docstring claiming it also marks
    ///      "the account address as cold".** Measured, storage-free control: a warm call costs 514 gas and 540 after
    ///      `vm.cool` -- +26, not the +2,500 a genuine cold-ACCOUNT access (2,600 vs 100) would add. So cooling the
    ///      implementation and `PriceFeedLib` -- which hold no storage this path reads -- moves the total by
    ///      EXACTLY ZERO (measured: 930,471 either way). An earlier revision recorded ~130 here; that was drift from
    ///      same-frame measurement, not an effect. They are cooled anyway: correct in intent, and correct in effect
    ///      if a later forge implements the address half.
    ///
    ///      The consequence is that EVERY "cold" number in this file is slots-cold, so it is a FLOOR: a real fresh
    ///      call additionally pays one cold-account premium per distinct account it touches, which this cheatcode
    ///      cannot reproduce inside a single test transaction (creating or calling an account warms it for the rest of
    ///      the transaction). On the 27-adapter display path that is 30 accounts -- 27 adapters, the implementation,
    ///      `PriceFeedLib`, the registry -- at 2,500 each, so **~75,000 unmeasured**. The proxy is excluded: EIP-2929
    ///      pre-warms a transaction's `to`. Size a gas limit from the reported total PLUS that margin.
    function _coolAll(address[] memory xs) internal {
        // ORDER IS LOAD-BEARING: `vm.load` WARMS the slot it reads, so reading the implementation slot after
        // `vm.cool(address(nav))` would silently re-warm it and hand the measured call a warm SLOAD. Read first,
        // cool second.
        address impl = address(uint160(uint256(vm.load(address(nav), ERC1967_IMPL_SLOT))));
        vm.cool(address(registry));
        vm.cool(address(nav));
        vm.cool(impl);
        vm.cool(LibraryPins.PRICE_FEED_LIB);
        for (uint256 i = 0; i < xs.length; i++) {
            vm.cool(xs[i]);
        }
    }

    /// @dev THE 27-DISTINCT FIXTURE. 27 is mainnet's registered-adapter count per the fork rehearsal.
    ///      Two isolations are reported and they answer different questions:
    ///        - REGISTRY-COLD only: the registry surcharge, methodologically identical to the account-path numbers.
    ///        - EVERYTHING-COLD: every account this fixture can cool -- registry, adapters, the proxy's own slots, the
    ///          UUPS implementation, `PriceFeedLib` -- with all SLOTS cold. It is a FLOOR on a fresh call, not the
    ///          fresh-call cost: `vm.cool` does not reproduce cold-ACCOUNT premiums, leaving ~75,000 unmeasured. See
    ///          `_coolAll` for the measured proof and the arithmetic. Size a gas limit from this PLUS that margin.
    function test_gas_configurationSurface_27Distinct_cold() public {
        address[] memory all = _growTo(27);

        nav.getAdapterDisplayInfo(all); // warm everything
        uint256 warm = this.measureDisplay(all);

        vm.cool(address(registry));
        uint256 regCold = this.measureDisplay(all);

        nav.getAdapterDisplayInfo(all); // re-warm
        _coolAll(all);
        uint256 allCold = this.measureDisplay(all);

        emit log_named_uint("27 distinct | WARM total            ", warm);
        emit log_named_uint("27 distinct | REGISTRY-COLD total   ", regCold);
        emit log_named_uint("27 distinct | EVERYTHING-COLD total ", allCold);
        emit log_named_uint("27 distinct | registry premium      ", regCold - warm);
        emit log_named_uint("27 distinct | per entry WARM        ", warm / 27);
        emit log_named_uint("27 distinct | per entry ALL-COLD    ", allCold / 27);
        assertGt(regCold, warm, "cooling the registry must cost more");
        assertGt(allCold, regCold, "cooling the adapters too must cost more still");

        // ⚠️ DISTINCTNESS IS ASSERTED HERE, AFTER THE MEASUREMENTS, AND THE POSITION IS LOAD-BEARING. A length check
        // alone would pass on a padded array of repeats -- the exact flaw that makes the 555,122 figure unusable --
        // so the premise of this fixture has to be enforced, not just named. But `assertTrue(bool, string)` allocates
        // its message in memory on every call, and an O(N^2) sweep of 351 of them expands the test frame's memory
        // enough that the SUBSEQUENT measured call pays materially more expansion: running it before the measurement
        // inflated EVERYTHING-COLD by ~3,255. Assert after measuring, and accumulate into one bool so a single
        // message is allocated.
        bool distinct = true;
        for (uint256 i = 0; i < all.length; i++) {
            for (uint256 j = i + 1; j < all.length; j++) {
                if (all[i] == all[j]) distinct = false;
            }
        }
        assertTrue(distinct, "fixture adapters must be DISTINCT: repeats are warm after the first touch");
    }

    /// @dev Linearity at scale: totals at N = 1, 9, 18, 27 DISTINCT adapters, everything cold each time. If the
    ///      marginal cost per entry is flat the surface is linear and safe to extrapolate; if it climbs, it is not.
    ///
    ///      The flatness is ASSERTED, not merely logged, because a logged-only measurement lets a super-linear
    ///      regression through CI silently. Bound derived FROM A MUTANT, per this PR's own rule -- a plausible O(N^2)
    ///      dedup scan over already-processed entries in `PriceFeedLib.adapterDisplayInfo`:
    ///
    ///        clean   34,741 vs 34,397  = +1.0%   PASS
    ///        mutant  39,458 vs 35,404  = +11.4%  FAIL
    ///        bound   +5%
    ///
    ///      Compares the LAST marginal against the FIRST, since super-linearity shows up as growth across windows.
    function test_gas_configurationSurface_linearityAtScale() public {
        address[] memory all = _growTo(27);
        uint256[4] memory ns = [uint256(1), 9, 18, 27];
        uint256[4] memory tot;
        for (uint256 k = 0; k < 4; k++) {
            address[] memory sub = new address[](ns[k]);
            for (uint256 i = 0; i < ns[k]; i++) {
                sub[i] = all[i];
            }
            nav.getAdapterDisplayInfo(sub); // warm, then cool everything for an equal footing
            _coolAll(sub);
            // Fresh frame per sample. Without it the loop measured ascending N in ONE frame, so each sample sat on
            // more accumulated memory than the last -- an N-correlated term that the +5% assertion below could have
            // read as super-linearity coming from the harness rather than from the surface.
            tot[k] = this.measureDisplay(sub);
        }
        emit log_named_uint("linearity | N=1  all-cold total", tot[0]);
        emit log_named_uint("linearity | N=9  all-cold total", tot[1]);
        emit log_named_uint("linearity | N=18 all-cold total", tot[2]);
        emit log_named_uint("linearity | N=27 all-cold total", tot[3]);
        uint256 first = (tot[1] - tot[0]) / 8;
        uint256 mid = (tot[2] - tot[1]) / 9;
        uint256 last = (tot[3] - tot[2]) / 9;
        emit log_named_uint("linearity | marginal per entry, 1->9  ", first);
        emit log_named_uint("linearity | marginal per entry, 9->18 ", mid);
        emit log_named_uint("linearity | marginal per entry, 18->27", last);

        // Integer form of "last marginal is at most 5% above the first" -- see the mutation run above.
        assertLe(last * 100, first * 105, "marginal per-entry cost must stay flat: the surface must not be superlinear");
    }

    /// @dev The ACCOUNT path at scale, cold, with 27 DISTINCT adapters -- the SCALE measurement, extended from N=2.
    ///
    ///      ⚠️ Its ceiling is a COARSE SCALE GUARD, not a caching defense, and is NOT mutation-derived. Every adapter
    ///      that emits here emits exactly ONE position, so per-adapter and per-position lookups are indistinguishable
    ///      -- the per-position mutant left this test's surcharge unchanged. The per-DISTINCT-ADAPTER caching
    ///      property is defended SOLELY by `test_gas_coldVsWarm_twoAdapters` (2 adapters / 3 positions), whose bound
    ///      IS derived from that mutant. What this test contributes is the MEASUREMENT of the surcharge at scale; the
    ///      linearity claim is asserted in `test_gas_configurationSurface_linearityAtScale`, not here.
    ///
    ///      ⚠️ **27 adapters are REGISTERED but only 26 EMIT.** The fixture's `ERC20DefaultBalanceAdapter` holds no
    ///      balance for `safe`, so it contributes no position and the override lookup never runs for it. The
    ///      per-adapter figure therefore divides by the EMITTING count, which is measured rather than assumed; an
    ///      earlier revision divided by 27 and published a per-adapter number ~4% low.
    function test_gas_accountPath_27Distinct_cold() public {
        address[] memory all = _growTo(27);
        nav.getAccountPositionsVerbose(safe, address(0)); // warm

        bytes32 rslot = _registrySlot();
        uint256 saved = uint256(vm.load(address(nav), rslot));
        vm.store(address(nav), rslot, bytes32(0));
        uint256 base = this.measureVerbose(safe);
        vm.store(address(nav), rslot, bytes32(saved));

        vm.cool(address(registry));
        uint256 cold = this.measureVerbose(safe);

        // Counted AFTER the measurements: it is a full verbose read plus an O(N^2) scan.
        uint256 emitting = _adaptersEmittingPositions(all);
        uint256 surcharge = cold - base;

        emit log_named_uint("account path | adapters REGISTERED        ", all.length);
        emit log_named_uint("account path | adapters EMITTING positions", emitting);
        emit log_named_uint("account path | baseline no-registry       ", base);
        emit log_named_uint("account path | COLD surcharge             ", surcharge);
        emit log_named_uint("account path | per EMITTING adapter       ", surcharge / emitting);

        // Coarse scale ceiling, NOT mutation-derived: one position per emitting adapter, so the per-position mutant
        // leaves `surcharge` unchanged. `test_gas_coldVsWarm_twoAdapters` is the mutation-derived guard.
        assertLt(surcharge, 300_000, "cold surcharge must stay within the coarse 27-adapter scale ceiling");
        assertEq(all.length, 27, "fixture must hold 27 registered adapters");
        assertEq(emitting, 26, "fixture shape: 26 of the 27 emit; the default ERC20 adapter holds no balance for safe");
    }

    /// @dev How many of `xs` actually produce at least one position for `safe`. Deliberately NOT `xs.length`: a
    ///      registered adapter with nothing to report never reaches the override lookup, so using the registered
    ///      count as a divisor understates the true per-adapter cost.
    function _adaptersEmittingPositions(address[] memory xs) internal view returns (uint256 n) {
        INAVCalculator.VerbosePosition[] memory v = nav.getAccountPositionsVerbose(safe, address(0));
        for (uint256 i = 0; i < xs.length; i++) {
            for (uint256 j = 0; j < v.length; j++) {
                if (v[j].position.balanceAdapter == xs[i]) {
                    n++;
                    break;
                }
            }
        }
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
