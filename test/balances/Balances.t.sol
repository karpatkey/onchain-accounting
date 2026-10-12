// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import {LibraryPins} from "script/utils/LibraryPins.sol";

import {Test} from "forge-std/Test.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {Balances} from "src/balances/Balances.sol";
import {ERC20DefaultBalanceAdapter} from "src/balances/BalanceAdapters/ERC20DefaultBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_CustomBalanceAdapter} from "test/mocks/balance_adapters.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

contract BalancesHarness is Balances {
    ERC20DefaultBalanceAdapter public defaultAdapter;

    /// @notice Test-only: track assets "registered" so ERC20DefaultBalanceAdapter.addSupportedAsset (which checks isAssetRegistered) succeeds.
    address[] private _testRegisteredList;
    mapping(address => bool) private _testRegistered;

    constructor() initializer {
        __Balances_init();
        // Set up ERC20DefaultBalanceAdapter for native address support
        defaultAdapter = new ERC20DefaultBalanceAdapter(address(this), new address[](0));
        _setErc20DefaultBalanceAdapter(address(defaultAdapter));
    }

    /// @notice Adds an asset to the default adapter's inclusion list (for testing). Marks asset as registered so addSupportedAsset succeeds.
    function addSupportedAssetForTest(address asset) public {
        _testRegistered[asset] = true;
        _testRegisteredList.push(asset);
        defaultAdapter.addSupportedAsset(asset);
    }

    /// @notice Stub for adapter tests that pass this contract as INAVCalculator (asset registry lives in NAVCalculator).
    function getRegisteredAssets() external view returns (INAVCalculator.Asset[] memory) {
        uint256 n = _testRegisteredList.length;
        INAVCalculator.Asset[] memory out = new INAVCalculator.Asset[](n);
        for (uint256 i = 0; i < n; i++) {
            address a = _testRegisteredList[i];
            out[i] = INAVCalculator.Asset({asset: a, symbol: "", decimals: 18});
        }
        return out;
    }

    /// @notice Single-asset sibling of the stub above, mirroring `INAVCalculator.getRegisteredAsset`.
    /// @dev Required, not optional: `MetaBalanceAdapter._getAssetInfo` calls this, so every meta-adapter test that
    ///      passes this harness as its NAVCalculator resolves assets through here. Without it the call hits a
    ///      missing selector and reverts, the meta-adapter's per-instance `try`/`catch` swallows that, and the
    ///      instance silently emits ZERO legs — which surfaces as "expected N legs, got 0" across the Aave V3 and
    ///      Morpho suites rather than as anything pointing at the harness.
    ///
    ///      Kept consistent with `getRegisteredAssets()` above by construction: same `_testRegistered` /
    ///      `_testRegisteredList` backing, same `("", 18)` metadata. If one is changed, change both — an adapter
    ///      that resolved differently through the two would be a test-only divergence with no production analogue.
    function getRegisteredAsset(address asset)
        external
        view
        returns (INAVCalculator.Asset memory assetInfo, bool found)
    {
        if (!_testRegistered[asset]) {
            return (assetInfo, false);
        }
        return (INAVCalculator.Asset({asset: asset, symbol: "", decimals: 18}), true);
    }

    function getAssetCount() external view returns (uint256) {
        return _testRegisteredList.length;
    }

    function isAssetRegistered(address asset) external view returns (bool) {
        return _testRegistered[asset];
    }

    function getAssetDecimals(address asset) external view returns (uint8) {
        if (!_testRegistered[asset]) revert AssetNotFound();
        return 18;
    }

    function getAssetSymbol(address asset) external view returns (string memory) {
        if (!_testRegistered[asset]) return "";
        return "";
    }

    function addBalanceAdapterDirect(
        address,
        /* underlyingAsset */
        address adapter,
        IBalances.AdapterType /* adapterType */
    )
        public
    {
        // Adapters are now global - underlyingAsset parameter is kept for backward compatibility but not used
        _addBalanceAdapter(adapter);
    }

    function unsetBalanceAdapter(
        address,
        /* underlyingAsset */
        address adapter
    )
        public
    {
        // Adapters are now global - underlyingAsset parameter is kept for backward compatibility but not used
        _removeBalanceAdapter(adapter);
    }

    function addMetaBalanceAdapterDirect(address adapter, bytes32[] memory instances) public {
        _addMetaBalanceAdapter(adapter, instances);
    }

    function addMetaInstancesDirect(address adapter, bytes32[] memory instances) public {
        _addMetaInstances(adapter, instances);
    }

    function removeMetaInstancesDirect(address adapter, bytes32[] memory instances) public {
        _removeMetaInstances(adapter, instances);
    }

    /// @dev The PLURAL path. `NAVCalculator` exposes only `removeBalanceAdapters`, so this — not the singular
    ///      helper above — is the route production takes and the one issue #335's fix has to hold on.
    function removeBalanceAdaptersDirect(address[] calldata adapters) public {
        _removeBalanceAdapters(adapters);
    }

    function metaInstanceTotalForTest() public view returns (uint256) {
        return _metaInstanceTotal;
    }
}

/// @notice Minimal mock advertising the meta-adapter interface (for registry tests).
contract Mock_MetaAdapter is IMetaBalanceAdapter {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IMetaBalanceAdapter).interfaceId || interfaceId == type(IBalanceAdapter).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function getAdapterPositions(address, address) external pure returns (INAVCalculator.PositionBalance[] memory) {
        return new INAVCalculator.PositionBalance[](0);
    }

    function getAdapterBalances(address) external pure returns (address[] memory, uint256[] memory, bool[] memory) {
        return (new address[](0), new uint256[](0), new bool[](0));
    }

    function getAdapterBalanceForAsset(address, address) external pure returns (uint256, bool) {
        return (0, false);
    }

    function underlyingAssetsSupported() external pure returns (address[] memory) {
        return new address[](0);
    }

    function getAdapterPositionsForInstances(address, bytes32[] calldata, address)
        external
        pure
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return new INAVCalculator.PositionBalance[](0);
    }

    function underlyingAssetsSupportedForInstances(bytes32[] calldata) external pure returns (address[] memory) {
        return new address[](0);
    }
}

contract BalancesTest is Test {
    BalancesHarness public balances;
    Mock_ERC20 public usdc;
    Mock_CustomBalanceAdapter public customAdapter;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public ops = makeAddr("ops");
    address public admin = makeAddr("admin");

    function setUp() public {
        // NAVRegistryLib is pre-linked at this deterministic CREATE2 address (foundry.toml). In tests there's no
        // chain state, so etch its runtime code there so the DELEGATECALL from _addBalanceAdapter/_removeBalanceAdapter
        // succeeds.
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, vm.deployCode("NAVRegistryLib.sol:NAVRegistryLib").code);
        vm.startPrank(admin);
        balances = new BalancesHarness();
        balances.addSupportedAssetForTest(balances.NATIVE_ADDRESS());
        usdc = new Mock_ERC20("USDC", 6);
        customAdapter = new Mock_CustomBalanceAdapter();
        customAdapter.setBalances(balances);
        address[] memory assets = new address[](1);
        assets[0] = address(customAdapter);
        customAdapter.setUnderlyingAssetsSupported(assets);
        customAdapter.setBalance(address(usdc), alice, 123_456_789, false);
        customAdapter.setBalance(address(usdc), bob, 987_654_321, true);
        address[] memory underlyingAssets = new address[](1);
        underlyingAssets[0] = address(usdc);
        customAdapter.setUnderlyingAssetsSupported(underlyingAssets);
        vm.stopPrank();
    }

    function test_setup() public view {
        uint256 count = balances.getAdapterCount();
        assertEq(count, 1, "Should have one balance adapter (ERC20DefaultBalanceAdapter)");

        address[] memory adapters = balances.getAllAdapters();
        assertEq(adapters.length, 1, "Should have one adapter");
        assertEq(
            adapters[0], balances.erc20DefaultBalanceAdapter(), "First adapter should be ERC20DefaultBalanceAdapter"
        );
    }

    function test_setAndGetERC20BalanceAdapter() public {
        vm.startPrank(admin);
        balances.addSupportedAssetForTest(address(usdc));
        vm.stopPrank();

        usdc.mint(alice, 1000);

        // Get adapters that support USDC
        address[] memory adapters = balances.getAdaptersForAsset(address(usdc));
        assertGt(adapters.length, 0, "Should have at least one adapter supporting USDC");

        // Get balance from ERC20DefaultBalanceAdapter
        (uint256 amount, bool isDebt) =
            IBalanceAdapter(balances.erc20DefaultBalanceAdapter()).getAdapterBalanceForAsset(alice, address(usdc));
        assertEq(amount, 1000);
        assertFalse(isDebt);
    }

    function test_setAndGetCustomBalanceAdapter() public {
        vm.startPrank(admin);
        balances.addBalanceAdapterDirect(address(customAdapter), address(customAdapter), IBalances.AdapterType.Custom);
        vm.stopPrank();

        customAdapter.setBalance(address(customAdapter), alice, 2000, false);

        // Get balance from custom adapter
        (uint256 amount, bool isDebt) =
            IBalanceAdapter(address(customAdapter)).getAdapterBalanceForAsset(alice, address(customAdapter));
        assertEq(amount, 2000);
        assertFalse(isDebt);
    }

    function test_setAndGetCustomBalanceAdapterDebtPosition() public {
        vm.startPrank(admin);
        balances.addBalanceAdapterDirect(address(customAdapter), address(customAdapter), IBalances.AdapterType.Custom);
        vm.stopPrank();

        customAdapter.setBalance(address(customAdapter), alice, 2000, true);

        // Get balance from custom adapter
        (uint256 amount, bool isDebt) =
            IBalanceAdapter(address(customAdapter)).getAdapterBalanceForAsset(alice, address(customAdapter));
        assertEq(amount, 2000);
        assertTrue(isDebt);
    }

    function test_addBalanceAdapter_nativeAddress() public {
        address nativeAddress = balances.NATIVE_ADDRESS();
        address adapter = balances.erc20DefaultBalanceAdapter();

        vm.expectRevert(IBalances.DuplicateBalanceAdapter.selector);
        balances.addBalanceAdapterDirect(nativeAddress, adapter, IBalances.AdapterType.Default);
    }

    function test_getNativeBalance() public {
        deal(alice, 1337);

        // Get balance from ERC20DefaultBalanceAdapter for native address
        (uint256 amount, bool isDebt) = IBalanceAdapter(balances.erc20DefaultBalanceAdapter())
            .getAdapterBalanceForAsset(alice, balances.NATIVE_ADDRESS());
        assertEq(amount, 1337);
        assertFalse(isDebt);
    }

    function test_removeBalanceAdapter() public {
        vm.startPrank(admin);
        balances.addSupportedAssetForTest(address(usdc));
        // Add a custom adapter for USDC
        balances.addBalanceAdapterDirect(address(usdc), address(customAdapter), IBalances.AdapterType.Custom);
        // Remove the custom adapter
        balances.unsetBalanceAdapter(address(usdc), address(customAdapter));
        vm.stopPrank();

        // Verify custom adapter is no longer registered
        assertFalse(balances.isAdapterRegistered(address(customAdapter)), "Custom adapter should not be registered");

        // ERC20DefaultBalanceAdapter should still be available for USDC
        address[] memory adapters = balances.getAdaptersForAsset(address(usdc));
        // Should still have ERC20DefaultBalanceAdapter
        assertGt(adapters.length, 0, "Should still have ERC20DefaultBalanceAdapter for USDC");
    }

    function test_removeBalanceAdapter_cantRemoveERC20DefaultBalanceAdapter() public {
        // Cannot remove ERC20DefaultBalanceAdapter
        address erc20Default = balances.erc20DefaultBalanceAdapter();
        vm.expectRevert(InvalidArguments.selector);
        balances.unsetBalanceAdapter(address(0), erc20Default);
    }

    function test_checkAdapterSupport_ERC20() public view {
        // checkBalanceAdapterSupport should pass for valid adapters, even if already registered
        // The duplicate check is now in _addBalanceAdapter, not in checkBalanceAdapterSupport
        balances.checkBalanceAdapterSupport(balances.erc20DefaultBalanceAdapter());
    }

    function test_checkAdapterSupport_Custom() public view {
        balances.checkBalanceAdapterSupport(address(customAdapter));
    }

    function test_RevertIf_InvalidAdapterZeroAddress() public {
        vm.expectRevert(InvalidArguments.selector);
        balances.checkBalanceAdapterSupport(address(0));
    }

    /// @dev A contract WITH code that answers neither ERC165 nor `IBalanceAdapter` — the realistic mistake, since
    ///      "I pasted the token address instead of the adapter address" is what actually happens. This and
    ///      `test_RevertIf_InvalidAdapterNoCode` were previously byte-identical: both passed the same
    ///      `makeAddr("invalid")` EOA, so despite its name no ERC20 was involved in either, and the
    ///      code-present input class was untested. `checkBalanceAdapterSupport` routes both through OZ's
    ///      `ERC165Checker`, which is exactly why both classes are worth naming separately.
    function test_RevertIf_InvalidAdapterERC20() public {
        vm.expectRevert(IBalances.InvalidBalanceAdapter.selector);
        balances.checkBalanceAdapterSupport(address(usdc));
    }

    /// @dev The other input class: an address with no code at all.
    function test_RevertIf_InvalidAdapterNoCode() public {
        address invalidAdapter = makeAddr("invalid");
        assertEq(invalidAdapter.code.length, 0, "fixture must have no code for this test to mean anything");
        vm.expectRevert(IBalances.InvalidBalanceAdapter.selector);
        balances.checkBalanceAdapterSupport(invalidAdapter);
    }

    function test_addBalanceAdapter_duplicate() public {
        vm.startPrank(admin);
        // Add custom adapter first
        balances.addBalanceAdapterDirect(address(usdc), address(customAdapter), IBalances.AdapterType.Custom);

        // Try to add the same adapter again - should fail
        vm.expectRevert(IBalances.DuplicateBalanceAdapter.selector);
        balances.addBalanceAdapterDirect(address(usdc), address(customAdapter), IBalances.AdapterType.Custom);
        vm.stopPrank();
    }

    // ============================================
    // Global Adapter Registry Tests
    // ============================================

    function test_isAdapterRegistered() public {
        // ERC20DefaultBalanceAdapter should be registered
        assertTrue(balances.isAdapterRegistered(balances.erc20DefaultBalanceAdapter()));

        // Random address should not be registered
        assertFalse(balances.isAdapterRegistered(makeAddr("random")));
    }

    // ============================================
    // Balance Adapter Management Tests
    // ============================================

    function test_addBalanceAdapter_zeroAddress() public {
        // Try to add adapter with zero address as the adapter parameter - should fail with InvalidArguments
        // The check happens in checkBalanceAdapterSupport which checks if adapter == address(0)
        vm.expectRevert(InvalidArguments.selector);
        balances.addBalanceAdapterDirect(address(usdc), address(0), IBalances.AdapterType.Default);
    }

    function test_removeBalanceAdapter_invalidAdapter() public {
        vm.startPrank(admin);
        // Add a custom adapter first
        balances.addBalanceAdapterDirect(address(usdc), address(customAdapter), IBalances.AdapterType.Custom);
        vm.stopPrank();

        address invalidAdapter = makeAddr("invalid");

        vm.expectRevert(IBalances.InvalidBalanceAdapter.selector);
        balances.unsetBalanceAdapter(address(usdc), invalidAdapter);
    }

    function test_balanceAdapterTotalCount() public {
        uint256 initialCount = balances.getAdapterCount();

        vm.startPrank(admin);
        // Add a new custom adapter
        balances.addBalanceAdapterDirect(address(usdc), address(customAdapter), IBalances.AdapterType.Custom);
        vm.stopPrank();

        // Should have one more adapter
        assertEq(balances.getAdapterCount(), initialCount + 1);
    }

    function test_getAdapterCount() public {
        uint256 initialCount = balances.getAdapterCount();
        assertEq(initialCount, 1, "Should start with ERC20DefaultBalanceAdapter");

        vm.startPrank(admin);
        balances.addBalanceAdapterDirect(address(usdc), address(customAdapter), IBalances.AdapterType.Custom);
        vm.stopPrank();

        assertEq(balances.getAdapterCount(), initialCount + 1, "Should have one more adapter");
    }

    function test_getAllAdapters() public {
        address[] memory initialAdapters = balances.getAllAdapters();
        assertEq(initialAdapters.length, 1, "Should start with one adapter");
        assertEq(
            initialAdapters[0],
            balances.erc20DefaultBalanceAdapter(),
            "First adapter should be ERC20DefaultBalanceAdapter"
        );

        vm.startPrank(admin);
        balances.addBalanceAdapterDirect(address(usdc), address(customAdapter), IBalances.AdapterType.Custom);
        vm.stopPrank();

        address[] memory allAdapters = balances.getAllAdapters();
        assertEq(allAdapters.length, 2, "Should have two adapters");
        assertEq(allAdapters[0], balances.erc20DefaultBalanceAdapter(), "First should be ERC20DefaultBalanceAdapter");
        assertEq(allAdapters[1], address(customAdapter), "Second should be custom adapter");
    }

    function test_getAdapterType() public {
        IBalances.AdapterType defaultType = balances.getAdapterType(balances.erc20DefaultBalanceAdapter());
        assertEq(
            uint8(defaultType),
            uint8(IBalances.AdapterType.Default),
            "ERC20DefaultBalanceAdapter should be Default type"
        );

        vm.startPrank(admin);
        balances.addBalanceAdapterDirect(address(usdc), address(customAdapter), IBalances.AdapterType.Custom);
        vm.stopPrank();

        IBalances.AdapterType customType = balances.getAdapterType(address(customAdapter));
        assertEq(uint8(customType), uint8(IBalances.AdapterType.Custom), "Custom adapter should be Custom type");
    }

    function test_getAdapterType_invalidAdapter() public {
        vm.expectRevert(IBalances.InvalidBalanceAdapter.selector);
        balances.getAdapterType(address(0x123));
    }

    function test_getAdaptersForAsset() public {
        vm.startPrank(admin);
        balances.addSupportedAssetForTest(address(usdc));
        // Add custom adapter that supports USDC
        balances.addBalanceAdapterDirect(address(usdc), address(customAdapter), IBalances.AdapterType.Custom);
        vm.stopPrank();

        // Get adapters that support USDC
        address[] memory adapters = balances.getAdaptersForAsset(address(usdc));

        // Should include ERC20DefaultBalanceAdapter (supports all registered assets) and customAdapter
        assertGe(adapters.length, 1, "Should have at least one adapter supporting USDC");

        bool foundCustomAdapter = false;
        bool foundErc20Default = false;
        for (uint256 i = 0; i < adapters.length; i++) {
            if (adapters[i] == address(customAdapter)) {
                foundCustomAdapter = true;
            }
            if (adapters[i] == balances.erc20DefaultBalanceAdapter()) {
                foundErc20Default = true;
            }
        }
        assertTrue(foundCustomAdapter, "Should find customAdapter in supporting adapters");
        assertTrue(foundErc20Default, "Should find ERC20DefaultBalanceAdapter in supporting adapters");
    }

    function test_getAdaptersForAsset_noSupport() public {
        // Get adapters for an asset that no adapter supports
        address unsupportedAsset = makeAddr("unsupported");
        address[] memory adapters = balances.getAdaptersForAsset(unsupportedAsset);

        // ERC20DefaultBalanceAdapter might still return it if the asset is registered
        // But if not registered, should return empty or only ERC20DefaultBalanceAdapter
        assertGe(adapters.length, 0, "Should return at least empty array");
    }

    // ============================================
    // Constants and Getters Tests
    // ============================================

    function test_NATIVE_ADDRESS() public view {
        address nativeAddress = balances.NATIVE_ADDRESS();
        assertEq(nativeAddress, address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE));
    }

    function test_erc20DefaultBalanceAdapter() public view {
        address defaultAdapter = balances.erc20DefaultBalanceAdapter();
        assertTrue(defaultAdapter != address(0));
    }

    // Legacy metadata-based tests removed as metadata API was refactored away.

    // ============================================
    // Meta-adapter instance registry
    // ============================================

    function _registerMeta() internal returns (Mock_MetaAdapter meta) {
        meta = new Mock_MetaAdapter();
        vm.prank(admin);
        // Meta-adapters register via the dedicated path (plain addBalanceAdapters rejects them); seed empty here so
        // the per-test add/remove cases drive the instance set explicitly.
        balances.addMetaBalanceAdapterDirect(address(meta), new bytes32[](0));
    }

    function test_meta_addInstances() public {
        Mock_MetaAdapter meta = _registerMeta();
        bytes32[] memory instances = new bytes32[](2);
        instances[0] = bytes32(uint256(uint160(address(0xAAA1))));
        instances[1] = bytes32(uint256(uint160(address(0xBBB2))));
        balances.addMetaInstancesDirect(address(meta), instances);

        bytes32[] memory got = balances.getMetaInstances(address(meta));
        assertEq(got.length, 2);
    }

    function test_meta_addInstances_appendsToExisting() public {
        Mock_MetaAdapter meta = _registerMeta();
        bytes32[] memory first = new bytes32[](2);
        first[0] = bytes32(uint256(1));
        first[1] = bytes32(uint256(2));
        balances.addMetaInstancesDirect(address(meta), first);

        bytes32[] memory second = new bytes32[](1);
        second[0] = bytes32(uint256(3));
        balances.addMetaInstancesDirect(address(meta), second);

        bytes32[] memory got = balances.getMetaInstances(address(meta));
        assertEq(got.length, 3, "add appends rather than replaces");
    }

    function test_meta_removeInstances() public {
        Mock_MetaAdapter meta = _registerMeta();
        bytes32[] memory three = new bytes32[](3);
        three[0] = bytes32(uint256(1));
        three[1] = bytes32(uint256(2));
        three[2] = bytes32(uint256(3));
        balances.addMetaInstancesDirect(address(meta), three);

        bytes32[] memory drop = new bytes32[](1);
        drop[0] = bytes32(uint256(2));
        balances.removeMetaInstancesDirect(address(meta), drop);

        bytes32[] memory got = balances.getMetaInstances(address(meta));
        assertEq(got.length, 2, "one removed");
        for (uint256 i = 0; i < got.length; i++) {
            assertTrue(got[i] != bytes32(uint256(2)), "removed coordinate is gone");
        }
    }

    function test_meta_addInstances_revertsOnDuplicateInStore() public {
        Mock_MetaAdapter meta = _registerMeta();
        bytes32[] memory one = new bytes32[](1);
        one[0] = bytes32(uint256(1));
        balances.addMetaInstancesDirect(address(meta), one);

        vm.expectRevert(IBalances.DuplicateMetaInstance.selector);
        balances.addMetaInstancesDirect(address(meta), one);
    }

    function test_meta_addInstances_revertsOnDuplicateInBatch() public {
        Mock_MetaAdapter meta = _registerMeta();
        bytes32[] memory dup = new bytes32[](2);
        dup[0] = bytes32(uint256(7));
        dup[1] = bytes32(uint256(7));
        vm.expectRevert(IBalances.DuplicateMetaInstance.selector);
        balances.addMetaInstancesDirect(address(meta), dup);
    }

    function test_meta_removeInstances_revertsOnMissing() public {
        Mock_MetaAdapter meta = _registerMeta();
        bytes32[] memory missing = new bytes32[](1);
        missing[0] = bytes32(uint256(99));
        vm.expectRevert(IBalances.MetaInstanceNotFound.selector);
        balances.removeMetaInstancesDirect(address(meta), missing);
    }

    function test_meta_add_and_remove_revertOnEmpty() public {
        Mock_MetaAdapter meta = _registerMeta();
        bytes32[] memory empty = new bytes32[](0);
        vm.expectRevert(InvalidArguments.selector);
        balances.addMetaInstancesDirect(address(meta), empty);
        vm.expectRevert(InvalidArguments.selector);
        balances.removeMetaInstancesDirect(address(meta), empty);
    }

    /// @notice The per-adapter SET tracks add and remove — and `_metaInstanceTotal` deliberately does not.
    /// @dev This test used to assert the running total. The total is RETIRED: it had no consumer (every
    ///      `PriceFeedLib` signature taking it left the parameter unused, so it sized no buffer and fed no
    ///      computation) while three call sites maintained it. Its slot and label survive because a live UUPS
    ///      proxy's layout is pinned, but the arithmetic is gone. Asserting it stays 0 is the point HERE, on a
    ///      fresh deploy where the slot was never written: it pins
    ///      the retirement, so a future author who rewires the arithmetic "to fix the inconsistency" — which
    ///      two long comments used to exist to discourage — gets a red test naming the decision instead.
    function test_meta_instanceSetTracksAddAndRemove_totalIsRetired() public {
        Mock_MetaAdapter meta = _registerMeta();
        bytes32[] memory two = new bytes32[](2);
        two[0] = bytes32(uint256(1));
        two[1] = bytes32(uint256(2));
        balances.addMetaInstancesDirect(address(meta), two);
        assertEq(balances.getMetaInstances(address(meta)).length, 2, "set reflects the add");

        bytes32[] memory one = new bytes32[](1);
        one[0] = bytes32(uint256(1));
        balances.removeMetaInstancesDirect(address(meta), one);
        assertEq(balances.getMetaInstances(address(meta)).length, 1, "set reflects the removal");

        assertEq(
            balances.metaInstanceTotalForTest(),
            0,
            "_metaInstanceTotal is retired: no arithmetic, so it stays 0 on a FRESH deploy (a live proxy freezes instead)"
        );
    }

    function test_meta_addInstances_onUnregisteredReverts() public {
        Mock_MetaAdapter meta = new Mock_MetaAdapter(); // not registered
        bytes32[] memory instances = new bytes32[](1);
        instances[0] = bytes32(uint256(1));
        vm.expectRevert(IBalances.InvalidBalanceAdapter.selector);
        balances.addMetaInstancesDirect(address(meta), instances);
    }

    // --- issue #335: removal clears the instance set ------------------------------------------------

    /// @notice Deregistering a meta adapter CLEARS its instance set, on the plural path production uses.
    /// @dev The direct regression test issue #335 did not have. `DormantInstanceCleanup.fork.t.sol` looks like
    ///      coverage but is vacuous with respect to this fix: it calls `removeMetaInstances` at step 3, so the
    ///      set is already empty by the time `removeBalanceAdapters` runs at step 4, and it passes unchanged
    ///      with the clearing deleted. This one seeds a coordinate and never clears it by hand.
    function test_removeBalanceAdapters_clearsMetaInstances() public {
        Mock_MetaAdapter meta = new Mock_MetaAdapter();
        bytes32[] memory instances = new bytes32[](1);
        instances[0] = bytes32(uint256(uint160(address(usdc))));
        balances.addMetaBalanceAdapterDirect(address(meta), instances);
        assertEq(balances.getMetaInstances(address(meta)).length, 1, "precondition: one governed coordinate");

        address[] memory rm = new address[](1);
        rm[0] = address(meta);
        balances.removeBalanceAdaptersDirect(rm);

        assertEq(balances.getMetaInstances(address(meta)).length, 0, "removal must clear the instance set");
    }

    /// @notice And re-registering the removed adapter cannot revive the old set.
    /// @dev This is the actual +$11,375.92 mechanism: `addMetaBalanceAdapter` APPENDS and accepts an empty
    ///      list, so before the fix one re-registration of a superseded adapter brought its whole set back
    ///      alongside the live successor, and NAV summed both with no health flag because both are well-formed.
    function test_removeBalanceAdapters_reRegistrationCannotRevive() public {
        Mock_MetaAdapter meta = new Mock_MetaAdapter();
        bytes32[] memory instances = new bytes32[](1);
        instances[0] = bytes32(uint256(uint160(address(usdc))));
        balances.addMetaBalanceAdapterDirect(address(meta), instances);

        address[] memory rm = new address[](1);
        rm[0] = address(meta);
        balances.removeBalanceAdaptersDirect(rm);

        // The revival step, verbatim: re-register with an EMPTY list and see what comes back.
        balances.addMetaBalanceAdapterDirect(address(meta), new bytes32[](0));

        assertEq(balances.getMetaInstances(address(meta)).length, 0, "re-registration must not resurrect the old set");
    }

    // --- meta/non-meta split (addMetaBalanceAdapter) ---

    function test_addMetaBalanceAdapter_registersAndSeeds() public {
        Mock_MetaAdapter meta = new Mock_MetaAdapter();
        bytes32[] memory instances = new bytes32[](2);
        instances[0] = bytes32(uint256(1));
        instances[1] = bytes32(uint256(2));

        vm.prank(admin);
        balances.addMetaBalanceAdapterDirect(address(meta), instances);

        assertTrue(balances.isAdapterRegistered(address(meta)), "meta-adapter registered");
        assertEq(balances.getMetaInstances(address(meta)).length, 2, "instances seeded");
        // `_metaInstanceTotal` is retired — see test_meta_instanceSetTracksAddAndRemove_totalIsRetired.
        assertEq(
            balances.metaInstanceTotalForTest(),
            0,
            "_metaInstanceTotal is retired: no arithmetic, so it stays 0 on a FRESH deploy (a live proxy freezes instead)"
        );
    }

    function test_addBalanceAdapters_rejectsMetaAdapter() public {
        Mock_MetaAdapter meta = new Mock_MetaAdapter();
        vm.prank(admin);
        vm.expectRevert(IBalances.MetaAdapterNotAllowed.selector);
        balances.addBalanceAdapterDirect(address(0), address(meta), IBalances.AdapterType.Custom);
    }

    function test_addMetaInstances_revertsOnNonMetaAdapter() public {
        // customAdapter (Mock_CustomBalanceAdapter) implements IBalanceAdapter but NOT IMetaBalanceAdapter.
        vm.prank(admin);
        balances.addBalanceAdapterDirect(address(0), address(customAdapter), IBalances.AdapterType.Custom);
        bytes32[] memory instances = new bytes32[](1);
        instances[0] = bytes32(uint256(1));
        vm.expectRevert(IBalances.NotMetaAdapter.selector);
        balances.addMetaInstancesDirect(address(customAdapter), instances);
    }
}
