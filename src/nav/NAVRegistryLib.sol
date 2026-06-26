// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {INAVCalculator} from "./INAVCalculator.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
import {ERC20DefaultBalanceAdapter} from "src/balances/protocols/ERC20DefaultBalanceAdapter.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title NAVRegistryLib
/// @notice External library for NAVCalculator's registry storage mutations (the asset registry + the balance-adapter
///         registry), extracted to keep NAVCalculator under EIP-170 (mirrors the PriceFeedLib pattern).
/// @dev Functions are `external` so the library compiles as a separate artifact and is invoked via DELEGATECALL,
///      operating on the caller's own storage through the passed `storage` references. Pre-linked at a deterministic
///      CREATE2 address (see `foundry.toml`) and deployed by `01_2_DeployNAVImplementation.s.sol` before NAVCalculator.
///      Only the heavier, no-return mutations live here (register/unregister asset; add/remove adapter); the trivial
///      getters and the running counts / event emission stay inline in the caller (cheaper than crossing the boundary).
/// @author KPK
library NAVRegistryLib {
    using ERC165Checker for address;

    /// @notice Native-asset sentinel (mirrors Balances.NATIVE_ADDRESS).
    address private constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    // -------------------------------------------------------------------------
    // ERC20Default adapter factory
    // -------------------------------------------------------------------------

    /// @notice Deploys a fresh ERC20DefaultBalanceAdapter bound to the calling NAVCalculator and returns it.
    /// @dev This function does NOT enforce single-deploy semantics — each call deploys a new adapter. The
    ///      one-adapter invariant is enforced by the caller: NAVCalculator.initialize calls this exactly once and
    ///      passes the result to `_setErc20DefaultBalanceAdapter`, which reverts if the default adapter is already set.
    ///      Called via DELEGATECALL, so `address(this)` is the NAV proxy — the adapter's
    ///      immutable NAV_CALCULATOR is pinned to it and the proxy is the CREATE deployer. Housed here so the
    ///      adapter's ~5 KB creation bytecode is embedded in THIS external library rather than NAVCalculator's
    ///      runtime code, keeping NAVCalculator well under EIP-170. `initialAssets` seeds the inclusion list
    ///      (e.g. NATIVE_ADDRESS) at construction without a callback to the still-initializing proxy.
    /// @param initialAssets Assets to pre-add to the adapter's inclusion list.
    /// @return adapter The deployed ERC20DefaultBalanceAdapter address.
    function deployDefaultAdapter(address[] memory initialAssets) external returns (address adapter) {
        return address(new ERC20DefaultBalanceAdapter(address(this), initialAssets));
    }

    // -------------------------------------------------------------------------
    // Asset registry
    // -------------------------------------------------------------------------

    /// @notice Registers an asset in the NAV/Pricing registry.
    /// @dev Fetches decimals and symbol: for NATIVE_ADDRESS uses 18 and `nativeTokenSymbol`; otherwise requires
    ///      ERC20-compatible (decimals() and symbol()) and reverts if not. Mirrors the former NAVCalculator._registerAsset.
    /// @param registeredAssets The ordered asset registry (storage ref)
    /// @param assetIndex The 1-based index map (storage ref; 0 = not registered)
    /// @param asset The asset to register
    /// @param nativeTokenSymbol The symbol to use for the native asset sentinel
    function registerAsset(
        INAVCalculator.Asset[] storage registeredAssets,
        mapping(address => uint256) storage assetIndex,
        address asset,
        string memory nativeTokenSymbol
    ) external {
        if (assetIndex[asset] != 0) {
            revert InvalidArguments(); // Asset already registered
        }
        uint8 decimals;
        string memory symbol;
        if (asset == NATIVE_ADDRESS) {
            decimals = 18;
            symbol = nativeTokenSymbol;
        } else {
            try IERC20Metadata(asset).decimals() returns (uint8 d) {
                decimals = d;
            } catch {
                revert InvalidArguments(); // Not ERC20 compatible
            }
            try IERC20Metadata(asset).symbol() returns (string memory s) {
                symbol = s;
            } catch {
                revert InvalidArguments(); // Not ERC20 compatible
            }
        }
        registeredAssets.push(INAVCalculator.Asset({asset: asset, symbol: symbol, decimals: decimals}));
        assetIndex[asset] = registeredAssets.length;
    }

    /// @notice Unregisters an asset from the NAV/Pricing registry (swap-remove, keeps the index map 1-based).
    /// @dev Mirrors the former NAVCalculator._unregisterAsset.
    /// @param registeredAssets The ordered asset registry (storage ref)
    /// @param assetIndex The 1-based index map (storage ref)
    /// @param asset The asset to unregister
    function unregisterAsset(
        INAVCalculator.Asset[] storage registeredAssets,
        mapping(address => uint256) storage assetIndex,
        address asset
    ) external {
        uint256 idx = assetIndex[asset];
        if (idx == 0) {
            revert AssetNotFound();
        }
        uint256 lastIdx = registeredAssets.length;
        if (idx != lastIdx) {
            INAVCalculator.Asset memory lastAsset = registeredAssets[lastIdx - 1];
            registeredAssets[idx - 1] = lastAsset;
            assetIndex[lastAsset.asset] = idx;
        }
        registeredAssets.pop();
        delete assetIndex[asset];
    }

    // -------------------------------------------------------------------------
    // Balance-adapter registry
    // -------------------------------------------------------------------------

    /// @notice Adds a balance adapter to the global registry (Custom type), after validating it supports the
    ///         IBalanceAdapter interface. Mirrors the storage work of the former Balances._addBalanceAdapter;
    ///         the running count and the BalanceAdapterAdded event stay in the caller wrapper.
    /// @param isAdapterRegistered Quick-lookup registration map (storage ref)
    /// @param globalAdapters The global adapter list (storage ref)
    /// @param adapterTypes The adapter-type map (storage ref)
    /// @param adapter The adapter to add
    function addBalanceAdapter(
        mapping(address => bool) storage isAdapterRegistered,
        address[] storage globalAdapters,
        mapping(address => IBalances.AdapterType) storage adapterTypes,
        address adapter
    ) external {
        _registerAdapter(isAdapterRegistered, globalAdapters, adapterTypes, adapter, false);
    }

    /// @notice Registers a meta-adapter and seeds its instance set in one operation. Requires the adapter to
    ///         implement both IBalanceAdapter and IMetaBalanceAdapter. Reverts DuplicateBalanceAdapter if already
    ///         registered, InvalidBalanceAdapter / NotMetaAdapter on the interface checks, and DuplicateMetaInstance
    ///         on a repeated coordinate. An empty instance list is allowed (registers the meta-adapter with no
    ///         instances yet). Emits BalanceAdapterAdded here (surfaces from the caller's address via DELEGATECALL);
    ///         the running counts (balanceAdapterTotalCount, _metaInstanceTotal) stay in the caller wrapper.
    /// @param isAdapterRegistered Quick-lookup registration map (storage ref)
    /// @param globalAdapters The global adapter list (storage ref)
    /// @param adapterTypes The adapter-type map (storage ref)
    /// @param metaInstances The per-adapter instance-set map (storage ref)
    /// @param adapter The meta-adapter to add
    /// @param instances The instance coordinates to seed (may be empty)
    /// @return added The number of coordinates seeded (== instances.length)
    function addMetaBalanceAdapter(
        mapping(address => bool) storage isAdapterRegistered,
        address[] storage globalAdapters,
        mapping(address => IBalances.AdapterType) storage adapterTypes,
        mapping(address => bytes32[]) storage metaInstances,
        address adapter,
        bytes32[] memory instances
    ) external returns (uint256 added) {
        _registerAdapter(isAdapterRegistered, globalAdapters, adapterTypes, adapter, true);
        emit IBalances.BalanceAdapterAdded(address(0), adapter, IBalances.AdapterType.Custom);
        added = _appendInstances(metaInstances[adapter], instances);
    }

    /// @notice Removes an adapter from the global registry (swap-remove). Reverts on the ERC20Default singleton or an
    ///         unregistered adapter. Mirrors the storage work of the former Balances._removeBalanceAdapter; the running
    ///         count and the BalanceAdapterRemoved event stay in the caller wrapper.
    /// @param isAdapterRegistered Quick-lookup registration map (storage ref)
    /// @param globalAdapters The global adapter list (storage ref)
    /// @param adapterTypes The adapter-type map (storage ref)
    /// @param adapter The adapter to remove
    /// @param erc20DefaultBalanceAdapter The default-adapter singleton that may not be removed
    function removeBalanceAdapter(
        mapping(address => bool) storage isAdapterRegistered,
        address[] storage globalAdapters,
        mapping(address => IBalances.AdapterType) storage adapterTypes,
        address adapter,
        address erc20DefaultBalanceAdapter
    ) external {
        if (adapter == erc20DefaultBalanceAdapter) {
            revert InvalidArguments(); // Cannot remove ERC20DefaultBalanceAdapter
        }
        if (!isAdapterRegistered[adapter]) {
            revert IBalances.InvalidBalanceAdapter();
        }

        uint256 len = globalAdapters.length;
        for (uint256 i = 0; i < len; i++) {
            if (globalAdapters[i] == adapter) {
                globalAdapters[i] = globalAdapters[len - 1];
                globalAdapters.pop();
                break;
            }
        }

        delete isAdapterRegistered[adapter];
        delete adapterTypes[adapter];
    }

    /// @notice Batch-registers non-meta balance adapters (the whole `addBalanceAdapters` body), emitting
    ///         BalanceAdapterAdded per adapter. Events emitted here surface from the caller's address (DELEGATECALL).
    ///         Reverts InvalidArguments (empty list / zero adapter), DuplicateBalanceAdapter, InvalidBalanceAdapter,
    ///         or MetaAdapterNotAllowed (a meta-adapter must use addMetaBalanceAdapter). All-or-nothing.
    /// @return count Number of adapters registered (== adapters.length).
    function addBalanceAdapters(
        mapping(address => bool) storage isAdapterRegistered,
        address[] storage globalAdapters,
        mapping(address => IBalances.AdapterType) storage adapterTypes,
        address[] calldata adapters
    ) external returns (uint256 count) {
        count = adapters.length;
        if (count == 0) revert InvalidArguments();
        for (uint256 i = 0; i < count; i++) {
            address adapter = adapters[i];
            _registerAdapter(isAdapterRegistered, globalAdapters, adapterTypes, adapter, false);
            emit IBalances.BalanceAdapterAdded(address(0), adapter, IBalances.AdapterType.Custom);
        }
    }

    /// @notice Batch-removes balance adapters (the whole `removeBalanceAdapters` body), emitting BalanceAdapterRemoved
    ///         per adapter (swap-remove). Reverts InvalidArguments (empty list / the ERC20Default singleton) and
    ///         InvalidBalanceAdapter (unregistered). All-or-nothing.
    /// @return count Number of adapters removed (== adapters.length).
    function removeBalanceAdapters(
        mapping(address => bool) storage isAdapterRegistered,
        address[] storage globalAdapters,
        mapping(address => IBalances.AdapterType) storage adapterTypes,
        address erc20DefaultBalanceAdapter,
        address[] calldata adapters
    ) external returns (uint256 count) {
        count = adapters.length;
        if (count == 0) revert InvalidArguments();
        for (uint256 i = 0; i < count; i++) {
            address adapter = adapters[i];
            if (adapter == erc20DefaultBalanceAdapter) revert InvalidArguments();
            if (!isAdapterRegistered[adapter]) revert IBalances.InvalidBalanceAdapter();
            uint256 len = globalAdapters.length;
            for (uint256 j = 0; j < len; j++) {
                if (globalAdapters[j] == adapter) {
                    globalAdapters[j] = globalAdapters[len - 1];
                    globalAdapters.pop();
                    break;
                }
            }
            delete isAdapterRegistered[adapter];
            delete adapterTypes[adapter];
            emit IBalances.BalanceAdapterRemoved(address(0), adapter);
        }
    }

    /// @notice Returns every registered adapter that lists `asset` in its `underlyingAssetsSupported()`. A faulty
    ///         adapter (reverting that call) is skipped. Mirrors the storage work of the former
    ///         Balances.getAdaptersForAsset; extracted here to keep NAVCalculator under EIP-170.
    /// @param globalAdapters The global adapter list (storage ref)
    /// @param asset The asset to match
    function getAdaptersForAsset(address[] storage globalAdapters, address asset)
        external
        view
        returns (address[] memory)
    {
        uint256 adapterCount = globalAdapters.length;
        address[] memory temp = new address[](adapterCount);
        uint256 count = 0;

        for (uint256 i = 0; i < adapterCount; i++) {
            try IBalanceAdapter(globalAdapters[i]).underlyingAssetsSupported() returns (
                address[] memory supportedAssets
            ) {
                for (uint256 j = 0; j < supportedAssets.length; j++) {
                    if (supportedAssets[j] == asset) {
                        temp[count++] = globalAdapters[i];
                        break;
                    }
                }
            } catch {
                continue;
            }
        }

        return ArrayLib.copySliceAddress(temp, count);
    }

    /// @notice Returns the de-duplicated set of assets referenced by a list of position balances. Extracted from
    ///         NAVCalculator (hot read path) to keep it under EIP-170; NAV reads are off-chain eth_call so the
    ///         DELEGATECALL overhead is immaterial.
    /// @dev    Currently UNCALLED: PR #73 moved NAVCalculator's read engine into `PriceFeedLib`, which does its
    ///         own dedup (`PriceFeedLib._extractUniqueAssets`). Retained here rather than removed because deleting
    ///         it would change `NAVRegistryLib`'s bytecode and force a second CREATE2-pin regeneration (foundry.toml
    ///         + LibraryPins + ~15 etch sites) for no functional gain; safe to drop in any future change that
    ///         already touches `NAVRegistryLib`.
    /// @param positions The position balances to scan
    /// @return uniqueAssets The distinct asset addresses
    function extractUniqueAssets(INAVCalculator.PositionBalance[] memory positions)
        external
        pure
        returns (address[] memory uniqueAssets)
    {
        uint256 length = positions.length;
        address[] memory allAssets = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            allAssets[i] = positions[i].balanceAsset.asset;
        }
        uniqueAssets = ArrayLib.deduplicateAddresses(allAssets);
    }

    // -------------------------------------------------------------------------
    // Meta-adapter instance registry (ADR 0010)
    // -------------------------------------------------------------------------

    /// @notice Appends instance coordinates to a meta-adapter's set (all-or-nothing). Reverts DuplicateMetaInstance
    ///         on a coordinate already present or repeated within the batch, InvalidArguments on an empty list, and
    ///         InvalidBalanceAdapter if the adapter is not registered. The running total stays in the caller wrapper.
    /// @param isAdapterRegistered Quick-lookup registration map (storage ref)
    /// @param metaInstances The per-adapter instance-set map (storage ref)
    /// @param adapter The registered meta-adapter
    /// @param instances The instance coordinates to add
    /// @return added The number of coordinates appended (== instances.length on success)
    function addMetaInstances(
        mapping(address => bool) storage isAdapterRegistered,
        mapping(address => bytes32[]) storage metaInstances,
        address adapter,
        bytes32[] memory instances
    ) external returns (uint256 added) {
        if (!isAdapterRegistered[adapter]) {
            revert IBalances.InvalidBalanceAdapter();
        }
        if (!adapter.supportsInterface(type(IMetaBalanceAdapter).interfaceId)) {
            revert IBalances.NotMetaAdapter();
        }
        if (instances.length == 0) {
            revert InvalidArguments();
        }
        added = _appendInstances(metaInstances[adapter], instances);
    }

    /// @notice Removes instance coordinates from a meta-adapter's set (all-or-nothing, swap-and-pop). Reverts
    ///         MetaInstanceNotFound on a coordinate not present (a coordinate repeated within the batch also reverts),
    ///         InvalidArguments on an empty list, InvalidBalanceAdapter if the adapter is not registered, and
    ///         NotMetaAdapter if it is not a meta-adapter.
    /// @param isAdapterRegistered Quick-lookup registration map (storage ref)
    /// @param metaInstances The per-adapter instance-set map (storage ref)
    /// @param adapter The registered meta-adapter
    /// @param instances The instance coordinates to remove
    /// @return removed The number of coordinates removed (== instances.length on success)
    function removeMetaInstances(
        mapping(address => bool) storage isAdapterRegistered,
        mapping(address => bytes32[]) storage metaInstances,
        address adapter,
        bytes32[] memory instances
    ) external returns (uint256 removed) {
        if (!isAdapterRegistered[adapter]) {
            revert IBalances.InvalidBalanceAdapter();
        }
        if (!adapter.supportsInterface(type(IMetaBalanceAdapter).interfaceId)) {
            revert IBalances.NotMetaAdapter();
        }
        removed = instances.length;
        if (removed == 0) {
            revert InvalidArguments();
        }

        bytes32[] storage set = metaInstances[adapter];
        for (uint256 i = 0; i < removed; i++) {
            bytes32 instance = instances[i];
            uint256 len = set.length;
            bool found = false;
            for (uint256 j = 0; j < len; j++) {
                if (set[j] == instance) {
                    set[j] = set[len - 1];
                    set.pop();
                    found = true;
                    break;
                }
            }
            if (!found) {
                revert IBalances.MetaInstanceNotFound();
            }
        }
    }

    // -------------------------------------------------------------------------
    // Private helpers (shared by the single / batch / meta registration paths)
    // -------------------------------------------------------------------------

    /// @notice Validates and stores one adapter in the global registry (Custom type). Reverts DuplicateBalanceAdapter
    ///         if already registered, InvalidArguments on a zero address, InvalidBalanceAdapter if it does not
    ///         implement IBalanceAdapter, and — depending on `requireMeta` — NotMetaAdapter (meta path, adapter is
    ///         not a meta-adapter) or MetaAdapterNotAllowed (plain path, adapter IS a meta-adapter). Does not emit;
    ///         the caller emits BalanceAdapterAdded so the batch path can log per-item.
    function _registerAdapter(
        mapping(address => bool) storage isAdapterRegistered,
        address[] storage globalAdapters,
        mapping(address => IBalances.AdapterType) storage adapterTypes,
        address adapter,
        bool requireMeta
    ) private {
        if (isAdapterRegistered[adapter]) {
            revert IBalances.DuplicateBalanceAdapter();
        }
        if (adapter == address(0)) revert InvalidArguments();
        if (!adapter.supportsInterface(type(IBalanceAdapter).interfaceId)) revert IBalances.InvalidBalanceAdapter();
        bool isMeta = adapter.supportsInterface(type(IMetaBalanceAdapter).interfaceId);
        if (requireMeta && !isMeta) revert IBalances.NotMetaAdapter();
        if (!requireMeta && isMeta) revert IBalances.MetaAdapterNotAllowed();

        globalAdapters.push(adapter);
        adapterTypes[adapter] = IBalances.AdapterType.Custom;
        isAdapterRegistered[adapter] = true;
    }

    /// @notice Appends `instances` to a meta-adapter's set, rejecting duplicates (DuplicateMetaInstance) against the
    ///         live set — which already includes coordinates pushed earlier in this batch, so an in-batch repeat is
    ///         caught too. Empty input is a no-op (returns 0); callers that forbid empty check before calling.
    /// @return added The number of coordinates appended (== instances.length).
    function _appendInstances(bytes32[] storage set, bytes32[] memory instances) private returns (uint256 added) {
        added = instances.length;
        for (uint256 i = 0; i < added; i++) {
            bytes32 instance = instances[i];
            uint256 len = set.length;
            for (uint256 j = 0; j < len; j++) {
                if (set[j] == instance) {
                    revert IBalances.DuplicateMetaInstance();
                }
            }
            set.push(instance);
        }
    }
}
