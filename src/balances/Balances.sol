// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IBalances} from "./IBalances.sol";
import {IBalanceAdapter} from "./IBalanceAdapter.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {NAVRegistryLib} from "src/nav/NAVRegistryLib.sol";

import {InvalidArguments} from "src/errors.sol";

/// @title Balances
/// @author KPK
/// @notice Manages the registry of balance adapters for different tokens.
abstract contract Balances is IBalances, Initializable {
    //
    // Libraries
    //
    using ERC165Checker for address;
    using SafeCast for uint256;
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    //
    // Constants
    //

    /// @notice ERC-7528 convention for ETH address representation
    address public constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    /// @notice The symbol of the chain's native token, used for display purposes
    string internal _nativeTokenSymbol;

    //
    // Storage
    //

    /// @notice Mapping from token address to balance adapters.
    mapping(address token => EnumerableMap.AddressToUintMap adapters) private _balanceAdapters;

    /// @notice Total count of balance adapters.
    uint256 public balanceAdapterTotalCount;

    /// @notice Global adapter registry - all adapters in the system
    address[] private _globalAdapters;

    /// @notice Mapping from adapter address to adapter type
    mapping(address adapter => AdapterType) private _adapterTypes;

    /// @notice Quick lookup for adapter registration
    mapping(address adapter => bool) private _isAdapterRegistered;

    /// @notice ERC20Default adapter singleton (automatically registered)
    /// @dev Set during initialization by derived contract
    address public erc20DefaultBalanceAdapter;

    /// @notice Per-adapter list of meta-adapter instance coordinates to query (e.g. vault addresses widened to
    ///         bytes32). This is the governed, mutable "which instances" registry that keeps adapters immutable.
    ///         Only meta-adapters read it (via getMetaInstances(address(this))); it is inert for other adapters.
    ///         Mutated via addMetaInstances / removeMetaInstances, which reject duplicates (a duplicate would
    ///         double-count NAV) and missing coordinates respectively.
    mapping(address adapter => bytes32[] instances) private _metaInstances;

    /// @notice Running total of configured meta instances across all adapters (cheap NAV buffer sizing).
    /// @dev RETIRED — arithmetic removed, NAME AND SLOT DELIBERATELY UNCHANGED. Still SLOADed, but by nothing
    ///      that uses it: `NAVCalculator` forwards it at six call sites and all five `PriceFeedLib` signatures
    ///      taking it leave the parameter
    ///      unused, so it sized no buffer and fed no computation. It was maintained by three call sites and
    ///      defended by two long comments in two files telling future authors not to "fix" its inconsistency —
    ///      a standing prose-drift generator for a number with no consumer. The arithmetic is gone; the SLOT
    ///      and its LABEL stay exactly as they were: the committed baseline under
    ///      `script/upgrade/storage-layout/` pins this label, and editing a drift-detection baseline to match
    ///      my own change is the move this repo forbids. A retired counter is worth a stale-looking name; a
    ///      silenced layout guard is not.
    uint256 internal _metaInstanceTotal;

    /// @dev Reserved storage gap for future Balances expansions (47 slots; 3 consumed by meta-adapter registry).
    // solhint-disable-next-line var-name-mixedcase
    uint256[47] private __balancesGap;

    /// @notice Which meta adapter currently governs a coordinate, or address(0) if unclaimed.
    /// @dev DECLARED AFTER THE GAP DELIBERATELY. Shrinking `__balancesGap` from 48 and putting the new
    ///      variable BEFORE it moves the gap itself from slot 62 to 63, which
    ///      `script/upgrade/check_storage_layout.py` rejects as MOVED. Declared after, `_claimant` takes the
    ///      slot the gap gave up (its old last slot) and nothing in the layout moves at all — the same shape
    ///      `assetKindRegistry` uses against `_gap`.
    /// @dev THE ownership relation, materialised. Before this, ownership was the emergent product of three
    ///      independently mutable stores — this map, `_supportedAssets` on the default adapter, and
    ///      `_isAdapterRegistered` — with no place it could be read, so every mutator had to re-establish it
    ///      by performing the right compensating writes on the others. Seven writers accumulated that way, and
    ///      six review rounds each found one of them missing a write. Adding writers could not converge,
    ///      because each fix was itself a new writer to get wrong.
    ///
    ///      One slot per coordinate, written only by `_claim` / `_release`. Dual claim stops being something
    ///      a scan must detect and becomes something the storage shape cannot represent — and the nested
    ///      O(adapters x instances) scans that approximated it are deleted, taking with them the "guard loops
    ///      over the wrong set" defect shape that a vacuous empty-batch loop produced.
    ///
    ///      Consumes one gap slot, so the layout of everything after it is unchanged on a live proxy.
    mapping(bytes32 coordinate => address adapter) private _claimant;

    //
    // Constructor
    //

    /// @notice Initializer for UUPS proxy
    /// @dev Derived contracts should deploy ERC20DefaultBalanceAdapter and call _setErc20DefaultBalanceAdapter()
    // solhint-disable-next-line func-name-mixedcase
    // forge-lint: disable-next-line(mixed-case-function)
    function __Balances_init() internal onlyInitializing {
        _nativeTokenSymbol = "ETH"; // Default value; override via _setNativeTokenSymbol in derived init
    }

    /// @notice Sets the native token symbol (e.g. "ETH", "xDAI"). Call from derived contract's initializer.
    /// @param symbol The native token symbol
    function _setNativeTokenSymbol(string memory symbol) internal {
        _nativeTokenSymbol = symbol;
    }

    /// @notice Internal function to set and register the ERC20Default adapter
    /// @dev Called by derived contracts after deploying ERC20DefaultBalanceAdapter
    /// @param defaultAdapter The address of the deployed ERC20DefaultBalanceAdapter
    function _setErc20DefaultBalanceAdapter(address defaultAdapter) internal {
        if (erc20DefaultBalanceAdapter != address(0)) {
            revert InvalidArguments(); // Already set
        }
        erc20DefaultBalanceAdapter = defaultAdapter;

        // Add to global adapter registry
        _globalAdapters.push(erc20DefaultBalanceAdapter);
        _adapterTypes[erc20DefaultBalanceAdapter] = AdapterType.Default; // ERC20Default handles both ERC20 and Native
        _isAdapterRegistered[erc20DefaultBalanceAdapter] = true;
    }

    //
    // IBalances
    //

    /// @inheritdoc IBalances
    function checkBalanceAdapterSupport(address adapter) public view {
        if (adapter == address(0)) revert InvalidArguments();

        if (!adapter.supportsInterface(type(IBalanceAdapter).interfaceId)) {
            revert InvalidBalanceAdapter();
        }
    }

    /// @inheritdoc IBalances
    function getAllAdapters() public view override returns (address[] memory) {
        return _globalAdapters;
    }

    /// @inheritdoc IBalances
    function getAdapterCount() public view override returns (uint256) {
        return _globalAdapters.length;
    }

    /// @inheritdoc IBalances
    function isAdapterRegistered(address adapter) public view override returns (bool) {
        return _isAdapterRegistered[adapter];
    }

    /// @inheritdoc IBalances
    function getAdapterType(address adapter) public view override returns (AdapterType) {
        if (!_isAdapterRegistered[adapter]) {
            revert InvalidBalanceAdapter();
        }
        return _adapterTypes[adapter];
    }

    /// @inheritdoc IBalances
    function getAdaptersForAsset(address asset) public view override returns (address[] memory) {
        // Loop + per-adapter try/catch delegated to NAVRegistryLib (external library) to keep NAVCalculator
        // under EIP-170.
        return NAVRegistryLib.getAdaptersForAsset(_globalAdapters, asset);
    }

    //
    // Internal API
    //

    /// @notice Adds a single (non-meta) balance adapter globally.
    /// @dev Not on the production path — NAVCalculator registers through the batch `_addBalanceAdapters` /
    ///      `_addMetaBalanceAdapter`. Retained for the test harness (`addBalanceAdapterDirect`); kept thin so the
    ///      single and batch validation stay equivalent (both bottom out in `NAVRegistryLib`'s shared
    ///      `_registerAdapter` — this path via `addBalanceAdapter`, the batch via `addBalanceAdapters`).
    /// @param adapter The address of the adapter.
    function _addBalanceAdapter(address adapter) internal {
        // Storage mutation + interface validation delegated to NAVRegistryLib (external library, DELEGATECALL) to
        // keep NAVCalculator under EIP-170; the running count + event stay inline (cheaper than crossing the boundary).
        NAVRegistryLib.addBalanceAdapter(_isAdapterRegistered, _globalAdapters, _adapterTypes, adapter);
        balanceAdapterTotalCount++;

        // Emit event with address(0) for underlyingAsset since adapters are global
        emit BalanceAdapterAdded(address(0), adapter, AdapterType.Custom);
    }

    /// @notice Registers a meta-adapter and seeds its instance set atomically (ADR 0010). The adapter must
    ///         implement IMetaBalanceAdapter; plain adapters use _addBalanceAdapter instead. Storage mutation +
    ///         interface validation are delegated to NAVRegistryLib; the running counts + event stay inline.
    /// @param adapter The meta-adapter to register.
    /// @param instances The instance coordinates to seed (may be empty).
    function _addMetaBalanceAdapter(address adapter, bytes32[] memory instances) internal {
        // Storage mutation + BalanceAdapterAdded event delegated to NAVRegistryLib; only the running counts inline.
        NAVRegistryLib.addMetaBalanceAdapter(
            _isAdapterRegistered,
            _globalAdapters,
            _adapterTypes,
            _metaInstances,
            _claimant,
            adapter,
            instances,
            erc20DefaultBalanceAdapter
        );
        balanceAdapterTotalCount++;
    }

    /// @notice Removes the adapter from the global registry.
    /// @param adapter The address of the adapter.
    function _removeBalanceAdapter(address adapter) internal {
        // Storage mutation + guards delegated to NAVRegistryLib (see _addBalanceAdapter); count + event stay inline.
        // Removal CLEARS the adapter's meta-instance set (issue #335). It used to be left dormant, and this
        // comment used to explain why that was survivable — it was not: `addMetaBalanceAdapter` APPENDS and
        // accepts an empty list, so one re-registration of a superseded adapter revived the whole set
        // alongside its live successor and NAV summed both (+$11,375.92 measured on ACCOUNT_11, with no
        // health flag, because both readings are well-formed).
        //
        // `_metaInstanceTotal` is RETIRED: the arithmetic is gone entirely rather than made consistent. It
        // sized nothing — every `PriceFeedLib` signature taking it left the parameter unused — so three call
        // sites and two long comments were maintaining a number with no consumer. Its slot and label survive
        // untouched because the storage layout of a live UUPS proxy is pinned.
        //
        // NOTE: this singular path currently has NO CALLER in `src/` — `NAVCalculator` exposes only the plural
        // `removeBalanceAdapters`. The clearing below is correct but unreachable today; the plural variant in
        // `NAVRegistryLib` is the one that does the real work for issue #335. Kept in step so the two cannot
        // diverge if a caller is ever added.
        NAVRegistryLib.removeBalanceAdapter(
            _isAdapterRegistered,
            _globalAdapters,
            _adapterTypes,
            _metaInstances,
            _claimant,
            adapter,
            erc20DefaultBalanceAdapter
        );
        balanceAdapterTotalCount--;

        // Emit event with address(0) for underlyingAsset since adapters are global
        emit BalanceAdapterRemoved(address(0), adapter);
    }

    /// @notice Batch-registers non-meta balance adapters. The loop + validation + per-adapter event are delegated
    ///         to NAVRegistryLib (external library, DELEGATECALL) to keep NAVCalculator under EIP-170; only the
    ///         running count stays inline.
    /// @param adapters The adapters to register.
    function _addBalanceAdapters(address[] calldata adapters) internal {
        balanceAdapterTotalCount += NAVRegistryLib.addBalanceAdapters(
            _isAdapterRegistered, _globalAdapters, _adapterTypes, adapters
        );
    }

    /// @notice Batch-removes balance adapters. Loop + guards + per-adapter event delegated to NAVRegistryLib.
    /// @param adapters The adapters to remove.
    function _removeBalanceAdapters(address[] calldata adapters) internal {
        (uint256 removedCount,) = NAVRegistryLib.removeBalanceAdapters(
            _isAdapterRegistered,
            _globalAdapters,
            _adapterTypes,
            _metaInstances,
            _claimant,
            erc20DefaultBalanceAdapter,
            adapters
        );
        balanceAdapterTotalCount -= removedCount;
    }

    //
    // Meta-adapter instance registry
    //

    /// @inheritdoc IBalances
    function getMetaInstances(address adapter) public view override returns (bytes32[] memory) {
        return _metaInstances[adapter];
    }

    /// @dev THE only route by which a token becomes a wallet-reported holding: arms the default adapter for
    ///      `asset`, reverting if a meta adapter already governs it. Check and inclusion are fused inside the
    ///      library so no caller can perform one without the other.
    function _includeAssetIfUnclaimed(address asset) internal {
        NAVRegistryLib.includeAssetIfUnclaimed(_claimant, erc20DefaultBalanceAdapter, asset);
    }

    /// @notice Appends instance coordinates to a meta-adapter's set (ADR 0010). All-or-nothing: reverts with
    ///         DuplicateMetaInstance if any coordinate is already present or repeated within the batch, since a
    ///         duplicate would double-count NAV. Empty input reverts. A zero coordinate is allowed (harmless — the
    ///         adapter's per-instance read reverts and is isolated to an empty result). Only meta-adapters read
    ///         this set, so it is inert for other adapters.
    /// @param adapter The registered adapter.
    /// @param instances The instance coordinates to add.
    function _addMetaInstances(address adapter, bytes32[] memory instances) internal {
        // Loop + validation delegated to NAVRegistryLib (external library, DELEGATECALL) to keep NAVCalculator
        // under EIP-170; only the running total stays inline.
        NAVRegistryLib.addMetaInstances(
            _isAdapterRegistered, _metaInstances, _claimant, adapter, instances, erc20DefaultBalanceAdapter
        );
    }

    /// @notice Removes instance coordinates from a meta-adapter's set (ADR 0010). All-or-nothing: reverts with
    ///         MetaInstanceNotFound if any coordinate is not present (a coordinate repeated within the batch also
    ///         reverts, since the first removal makes the second lookup miss). Empty input reverts. Order is not
    ///         preserved (swap-and-pop).
    /// @param adapter The registered adapter.
    /// @param instances The instance coordinates to remove.
    function _removeMetaInstances(address adapter, bytes32[] memory instances) internal {
        // Loop + validation delegated to NAVRegistryLib (see _addMetaInstances); only the running total stays inline.
        NAVRegistryLib.removeMetaInstances(
            _isAdapterRegistered, _metaInstances, _claimant, adapter, instances, erc20DefaultBalanceAdapter
        );
    }
}
