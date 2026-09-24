// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {INAVCalculator} from "./INAVCalculator.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
import {ERC20DefaultBalanceAdapter} from "src/balances/BalanceAdapters/ERC20DefaultBalanceAdapter.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import {GasStipendLib} from "src/utils/GasStipendLib.sol";
import "src/errors.sol";

/// @title NAVRegistryLib
/// @notice External library for NAVCalculator's registry storage mutations (the asset registry + the balance-adapter
///         registry), extracted to keep NAVCalculator under EIP-170 (mirrors the PriceFeedLib pattern).
/// @dev Functions are `external` so the library compiles as a separate artifact and is invoked via DELEGATECALL,
///      operating on the caller's own storage through the passed `storage` references. Pre-linked at a deterministic
///      CREATE2 address (see `foundry.toml`) and deployed by `01_2_DeployNAVImplementation.s.sol` before NAVCalculator.
///      The heavier registry work lives here: the ERC20Default factory, asset register/unregister, single + batch
///      adapter add/remove, meta-adapter registration, and meta-instance add/remove (several return a per-call count),
///      plus one read helper (getAdaptersForAsset). The running totals stay inline in the caller,
///      as do the trivial getters and the single add/remove paths' event emission (the batch and meta paths emit their
///      events here) — keeping that work in the caller is cheaper than crossing the DELEGATECALL boundary.
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
    /// @dev Reverts InvalidArguments if `asset` is already registered. Otherwise fetches decimals and symbol: for
    ///      NATIVE_ADDRESS uses 18 and `nativeTokenSymbol`; for any other asset requires ERC20-compatibility (both
    ///      decimals() and symbol() must succeed) and reverts InvalidArguments if either call fails. Mirrors the
    ///      former NAVCalculator._registerAsset.
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
    /// @dev Reverts AssetNotFound if `asset` is not registered. Mirrors the former NAVCalculator._unregisterAsset.
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
    ///         registered, InvalidArguments on a zero adapter, InvalidBalanceAdapter / NotMetaAdapter on the interface
    ///         checks, and DuplicateMetaInstance on a repeated coordinate. An empty instance list is allowed (registers the meta-adapter with no
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
        mapping(bytes32 => address) storage claimant,
        address adapter,
        bytes32[] memory instances,
        address erc20DefaultBalanceAdapter
    ) external returns (uint256 added) {
        _registerAdapter(isAdapterRegistered, globalAdapters, adapterTypes, adapter, true);
        emit IBalances.BalanceAdapterAdded(address(0), adapter, IBalances.AdapterType.Custom);

        // REGISTRATION IMPLIES AN EMPTY SET. Wiping here makes residue revival UNREPRESENTABLE rather than
        // merely detected: there is no state in which a freshly registered adapter carries coordinates nobody
        // asked it to carry.
        //
        // The guard this replaces scanned the incoming batch, so an EMPTY list skipped it entirely — and an
        // empty list is exactly how issue #335 residue revives: addMetaBalanceAdapter(superseded, []) brings
        // back dormant coordinates written by the PRE-UPGRADE implementation, which this PR clearing cannot
        // reach retroactively. Measured against mainnet 2026-09-24 with `residue_audit.py`: the RESIDUE
        // 0x59039882... this was originally written about is now CLEARED, but ELEVEN other deregistered
        // adapters still carry dormant sets totalling 51 coordinates, and EVERY ONE of those coordinates is
        // also held by a live registered adapter — so each would double-count if its stale address were ever
        // re-registered. This wipe is what closes that, fleet-wide, without needing them cleaned first.
        // A scan could only reject a CONFLICTING residue; an unconflicting dormant set still revived silently.
        //
        // Releasing first keeps the default adapter honest: a wiped coordinate that is a registered asset goes
        // back to ERC20DefaultBalanceAdapter rather than being reported by nobody.
        _releaseInstances(claimant, metaInstances, adapter, erc20DefaultBalanceAdapter);
        added = _appendInstances(claimant, metaInstances, adapter, instances, erc20DefaultBalanceAdapter);
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
        mapping(address => bytes32[]) storage metaInstances,
        mapping(bytes32 => address) storage claimant,
        address adapter,
        address erc20DefaultBalanceAdapter
    ) external returns (uint256 clearedInstances) {
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

        // REMOVAL CLEARS THE META-INSTANCE SET. Leaving it populated was the defect behind issue #335: a
        // deregistered adapter kept advertising its coordinates, and `addMetaBalanceAdapter` APPENDS and
        // accepts an empty list — so one re-registration of a superseded address revived the whole set
        // alongside the live successor and NAV summed both (+$11,375.92 measured on ACCOUNT_11, with no
        // health flag because both readings are well-formed). The residue was also unreachable without
        // first re-registering the adapter, which is the very act that double-counts; that circularity is
        // what forced a five-transaction cleanup dance. Clearing here removes the state at the only moment
        // it is both reachable and safe to touch.
        //
        // `clearedInstances` is returned for callers that want it; `Balances` deliberately DISCARDS it.
        // `_metaInstanceTotal` is RETIRED — it had no consumer (every `PriceFeedLib` signature taking it left
        // the parameter unused), so its arithmetic is gone and its value stays 0; only its slot and label
        // survive, because a live UUPS proxy's layout is pinned. Do not wire a subtraction back in: see the
        // declaration of `_metaInstanceTotal` in `Balances`, and the test that pins it at zero.
        clearedInstances = _releaseInstances(claimant, metaInstances, adapter, erc20DefaultBalanceAdapter);

        delete isAdapterRegistered[adapter];
        delete adapterTypes[adapter];
    }

    /// @notice Batch-registers non-meta balance adapters (the whole `addBalanceAdapters` body), emitting
    ///         BalanceAdapterAdded per adapter. Events emitted here surface from the caller's address (DELEGATECALL).
    ///         Reverts InvalidArguments (empty list / zero adapter), DuplicateBalanceAdapter, InvalidBalanceAdapter,
    ///         or MetaAdapterNotAllowed (a meta-adapter must use addMetaBalanceAdapter). All-or-nothing.
    /// @param isAdapterRegistered Quick-lookup registration map (storage ref)
    /// @param globalAdapters The global adapter list (storage ref)
    /// @param adapterTypes The adapter-type map (storage ref)
    /// @param adapters The non-meta adapters to add
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
    /// @param isAdapterRegistered Quick-lookup registration map (storage ref)
    /// @param globalAdapters The global adapter list (storage ref)
    /// @param adapterTypes The adapter-type map (storage ref)
    /// @param erc20DefaultBalanceAdapter The default-adapter singleton that may not be removed
    /// @param adapters The adapters to remove
    /// @return count Number of adapters removed (== adapters.length).
    function removeBalanceAdapters(
        mapping(address => bool) storage isAdapterRegistered,
        address[] storage globalAdapters,
        mapping(address => IBalances.AdapterType) storage adapterTypes,
        mapping(address => bytes32[]) storage metaInstances,
        mapping(bytes32 => address) storage claimant,
        address erc20DefaultBalanceAdapter,
        address[] calldata adapters
    ) external returns (uint256 count, uint256 clearedInstances) {
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
            // Clear the meta-instance set here too (issue #335). This is the path 06_Configure and
            // SwapMetaAdapter actually take, so a fix that only covered the singular variant would have
            // left the real deregistration route still leaking dormant coordinates.
            clearedInstances += _releaseInstances(claimant, metaInstances, adapter, erc20DefaultBalanceAdapter);
            emit IBalances.BalanceAdapterRemoved(address(0), adapter);
        }
    }

    /// @notice Returns every registered adapter that lists `asset` in its `underlyingAssetsSupported()`. A faulty
    ///         adapter (reverting that call) is skipped. Mirrors the storage work of the former
    ///         Balances.getAdaptersForAsset; extracted here to keep NAVCalculator under EIP-170.
    /// @param globalAdapters The global adapter list (storage ref)
    /// @param asset The asset to match
    /// @return The registered adapters whose underlyingAssetsSupported() lists `asset` (faulty adapters skipped)
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

    // -------------------------------------------------------------------------
    // Meta-adapter instance registry (ADR 0010)
    // -------------------------------------------------------------------------

    /// @notice Appends instance coordinates to a meta-adapter's set (all-or-nothing). Reverts DuplicateMetaInstance
    ///         on a coordinate already present or repeated within the batch, InvalidArguments on an empty list,
    ///         InvalidBalanceAdapter if the adapter is not registered, and NotMetaAdapter if it is not a meta-adapter.
    ///         The running total stays in the caller wrapper.
    /// @param isAdapterRegistered Quick-lookup registration map (storage ref)
    /// @param metaInstances The per-adapter instance-set map (storage ref)
    /// @param adapter The registered meta-adapter
    /// @param instances The instance coordinates to add
    /// @return added The number of coordinates appended (== instances.length on success)
    function addMetaInstances(
        mapping(address => bool) storage isAdapterRegistered,
        mapping(address => bytes32[]) storage metaInstances,
        mapping(bytes32 => address) storage claimant,
        address adapter,
        bytes32[] memory instances,
        address erc20DefaultBalanceAdapter
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
        added = _appendInstances(claimant, metaInstances, adapter, instances, erc20DefaultBalanceAdapter);
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
        mapping(bytes32 => address) storage claimant,
        address adapter,
        bytes32[] memory instances,
        address erc20DefaultBalanceAdapter
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
                    _release(claimant, adapter, instance, erc20DefaultBalanceAdapter);
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

    /// @dev Takes ownership of `instance` for `adapter`: the only writer that adds a coordinate, to BOTH
    ///      stores — it sets the claim and pushes onto `metaInstances`, so the two cannot diverge on add.
    /// @dev One SLOAD plus a scan of this adapter's OWN set — see the body for why the SLOAD alone is not
    ///      enough on an upgraded proxy. `DuplicateMetaInstance` when
    ///      this adapter already holds it (a within-adapter duplicate is a real over-report —
    ///      `MetaBalanceAdapter` does not dedupe on read); `MetaInstanceClaimedByAnotherAdapter` naming the
    ///      holder otherwise, because "already yours" and "already someone else's" are different operator
    ///      problems. Taking a coordinate also DISARMS the default adapter, which is the half that kept going
    ///      missing: release re-arms it, so take must disarm it or release-then-re-add ends with two reporters.
    function _claim(
        mapping(bytes32 => address) storage claimant,
        mapping(address => bytes32[]) storage metaInstances,
        address adapter,
        bytes32 instance,
        address erc20DefaultBalanceAdapter
    ) private {
        address holder = claimant[instance];
        if (holder != address(0)) {
            if (holder == adapter) revert IBalances.DuplicateMetaInstance();
            revert IBalances.MetaInstanceClaimedByAnotherAdapter(instance, holder);
        }

        // AND the adapter's own set, because the claim map alone is not sufficient on an UPGRADED proxy.
        // `_claimant` is new storage: it starts EMPTY while `_metaInstances` is already full, so
        // `claimant[instance] == 0` does NOT prove this adapter is not already holding the coordinate. The
        // scan this map replaced read `_metaInstances` directly and so covered that case; without this loop,
        // re-adding a coordinate an adapter already holds would PUSH A SECOND COPY instead of reverting, and
        // `MetaBalanceAdapter._positionsForInstances` iterates the raw array without de-duplicating — an
        // immediate double-count, the #335 species, in a window the backfill script is the only other guard
        // against. Cheap enough to be unconditional: O(one adapter's set), not the O(adapters x instances)
        // the map exists to delete.
        bytes32[] storage own = metaInstances[adapter];
        uint256 ownLen = own.length;
        for (uint256 i; i < ownLen; ++i) {
            if (own[i] == instance) revert IBalances.DuplicateMetaInstance();
        }

        claimant[instance] = adapter;
        metaInstances[adapter].push(instance);
        _excludeIfAsset(erc20DefaultBalanceAdapter, instance);
    }

    /// @dev Gives up `instance`: the only writer that clears a coordinate's CLAIM. It does NOT remove the
    ///      coordinate from `metaInstances` — the caller owns that, by swap-and-pop in `removeMetaInstances` or
    ///      by `delete` in `_releaseInstances` — so the two must stay in step. Re-arms the default adapter so a
    ///      released registered asset is reported by somebody rather than nobody.
    function _release(
        mapping(bytes32 => address) storage claimant,
        address adapter,
        bytes32 instance,
        address erc20DefaultBalanceAdapter
    ) private {
        // OWNERSHIP GATE. Releasing used to be unconditional, which let one adapter delete another's claim
        // and re-arm the default adapter for a coordinate somebody else was still reporting — two reporters,
        // no health flag, the +$11,375.92 shape this PR exists to close, reintroduced through the release
        // side. The registration WIPE made it reachable in one MANAGER call: `addMetaBalanceAdapter(residue,
        // [])` wipes a dormant pre-#335 array, and every coordinate that array still lists gets released —
        // including coordinates the LIVE adapter owns and is still reporting.
        //
        // THE CONDITION IS "WE OWN IT", and an earlier version of this comment argued the opposite — that
        // skipping only a claim held by a DIFFERENT adapter was load-bearing, because on an upgraded proxy
        // `_claimant` is empty and requiring `== adapter` would stop release re-arming the default adapter.
        // That reasoning traded the wrong way round. In the un-backfilled window `holder == 0` for every
        // pre-existing coordinate, so the weaker gate did not fire at all: wiping a dormant residue array
        // re-armed the default adapter for coordinates a LIVE adapter was still reporting, and
        // `addSupportedAsset` succeeds for a registered asset — two reporters, no health flag.
        //
        // Both options lose something in that window; they do not lose the same KIND of thing. The weaker
        // gate risks an OVER-report, which this repo never licenses. This one declines to re-arm a coordinate
        // whose ownership it cannot prove, which is an under-report — licensed everywhere here, and repaired
        // by `BackfillMetaInstanceClaimants` populating the map. On a backfilled or freshly deployed proxy
        // `holder == adapter` for every legitimately held coordinate, so nothing is lost at all.
        address holder = claimant[instance];
        if (holder != adapter) return;

        delete claimant[instance];
        _reincludeIfAsset(claimant, erc20DefaultBalanceAdapter, instance);
    }

    /// @dev Appends `instances` to `adapter`'s set via `_claim`, which is the only writer that adds.
    /// @return added The number of coordinates appended (== instances.length).
    function _appendInstances(
        mapping(bytes32 => address) storage claimant,
        mapping(address => bytes32[]) storage metaInstances,
        address adapter,
        bytes32[] memory instances,
        address erc20DefaultBalanceAdapter
    ) private returns (uint256 added) {
        added = instances.length;
        for (uint256 i = 0; i < added; i++) {
            _claim(claimant, metaInstances, adapter, instances[i], erc20DefaultBalanceAdapter);
        }
    }

    /// @dev Hands a released coordinate back to `ERC20DefaultBalanceAdapter` when it is a registered asset.
    ///
    ///      Without this, releasing a coordinate left the token held by NOBODY: excluded from the default
    ///      adapter and governed by no meta adapter, so `getAccountNav` returned a clean, wrong, smaller number
    ///      with no health flag — the `NAV` struct carries only price-side fields. `includeAssetInDefaultAdapter`
    ///      existed as the manual repair but had ZERO non-test callers, so nothing prompted anyone to run it.
    ///
    ///      Self-limiting by construction, which is why it is safe to apply to EVERY released coordinate rather
    ///      than only the wallet-yield family's. `addSupportedAsset` reverts `AssetNotFound` unless the address
    ///      is a registered NAV asset, so a Morpho vault address or a truncated Balancer poolId simply fails and
    ///      is skipped; and `EnumerableSet.add` is idempotent, so re-including an asset that never left is a
    ///      no-op. The `catch` is the filter, not an error path.
    ///
    ///      Deliberate consequence, decided by the repo owner: retirement no longer means deletion. An operator
    ///      removing an adapter to stop reporting a token will find it reported by the default adapter again.
    ///      "Remove this from NAV entirely" is `unregisterAsset`, a separate and explicit operation. The trade is
    ///      a visible, correct value from an unexpected reporter instead of an invisible, wrong one from none.
    ///      CLAIM-GATED, because the truncation below is not injective. `instance` is narrowed to an address by
    ///      dropping its top 12 bytes, so a coordinate that is NOT address-shaped — a Morpho marketId, a Balancer
    ///      V2 poolId — can narrow onto a real token `T` that a DIFFERENT meta adapter governs under the
    ///      address-shaped coordinate `bytes32(T)`. Releasing that coordinate would then re-arm the default
    ///      adapter for a token somebody else is still reporting: two reporters, no health flag, which is the
    ///      exact shape this PR exists to close, arriving through the release side instead of the claim side.
    ///      Its inclusion twin {includeAssetIfUnclaimed} has always consulted `claimant`; this one did not, and
    ///      the asymmetry was the gap. One SLOAD closes it.
    ///
    ///      The address-shaped case — `instance == bytes32(T)`, the overwhelming majority — is unaffected:
    ///      `_release` has already `delete`d that key before calling here, so the lookup reads zero and the
    ///      re-arm proceeds exactly as before. Only a coordinate narrowing onto a key somebody ELSE holds is
    ///      skipped, and skipping is an under-report, which this repo licenses.
    function _reincludeIfAsset(
        mapping(bytes32 => address) storage claimant,
        address erc20DefaultBalanceAdapter,
        bytes32 instance
    ) private {
        if (erc20DefaultBalanceAdapter == address(0)) return;
        address token = address(uint160(uint256(instance)));
        if (token == address(0)) return;

        // Decline to re-arm a token whose address-shaped coordinate another adapter still claims.
        if (claimant[bytes32(uint256(uint160(token)))] != address(0)) return;

        // METERED, because the fail-open here had no way to tell a starved call from an expected one.
        // `addSupportedAsset` is a full external call that itself calls back into the proxy
        // (`isAssetRegistered`), so the bare `catch {}` this replaces treated an out-of-gas identically to the
        // expected `AssetNotFound`. On `removeBalanceAdapters` over a large set, a coordinate late in the loop
        // gets a dwindling frame: the call failed, the catch swallowed it, the outer transaction still
        // succeeded, and the token ended up released from the meta adapter AND not re-armed on the default one
        // — governed by nobody, no health flag. That is the outcome this function exists to prevent, and the
        // direction being merely an under-report is not a reason to leave it undetectable.
        //
        // Same single-sample discipline as `MetaBalanceAdapter._positionsForInstances`: read `available` ONCE
        // before the call, forward `stipendFrom(available)`, and classify `available - gasleft()` against it.
        // Re-sampling nearer the call inverts the slack and a real exhaustion reads as a benign revert.
        uint256 available = gasleft();
        uint256 stipend = GasStipendLib.stipendFrom(available);
        try ERC20DefaultBalanceAdapter(erc20DefaultBalanceAdapter).addSupportedAsset{gas: stipend}(token) {}
        catch {
            uint256 consumed = available - gasleft();
            if (GasStipendLib.exhausted(stipend, consumed)) {
                revert IBalances.DefaultAdapterReincludeGasExhausted(token, stipend, consumed);
            }
            // Otherwise it is the expected refusal — the coordinate is not a registered asset — which is
            // exactly what this fail-open is for.
        }
    }

    /// @notice Arms the default adapter for `asset`, refusing if a meta adapter already governs it — i.e. the
    ///         single gate through which a token may become a wallet-reported holding.
    /// @dev One SLOAD decides it, replacing an O(adapters x instances) scan; that collapse is what let the
    ///      guard fit the calculator's byte budget at all. Guards BOTH inclusion entry points:
    ///      `includeAssetInDefaultAdapter`, and `registerAsset`, which included unconditionally and so turned
    ///      claim-then-register into two reporters.
    ///
    ///      The check and the `addSupportedAsset` it guards live in ONE library function rather than two
    ///      statements in the caller, for two reasons. Bytes: `NAVCalculator` was 60 over EIP-170 with them
    ///      split, because each call site paid for an external-call encoding on top of the DELEGATECALL, and
    ///      the libraries have four-figure headroom while the calculator has none. Correctness: a guard that
    ///      the caller must remember to place before a separate call is exactly the seven-writers shape this
    ///      PR exists to remove — fused, there is no way to reach the inclusion without passing the gate.
    ///
    ///      NOT fail-open, unlike {_reincludeIfAsset}: this runs where the asset is known-registered, so a
    ///      revert from `addSupportedAsset` is a real fault and must reach the MANAGER rather than be
    ///      swallowed.
    /// @dev `revertIfClaimed` splits the two callers, and collapsing them was a trap.
    ///
    ///      `includeAssetInDefaultAdapter` is an operator ASKING for a second reporter, so refusing loudly is
    ///      the right answer: true.
    ///
    ///      `registerAsset` is not asking for anything — arming the default adapter is an incidental
    ///      convenience on the way to registering an asset. Reverting there made a claimed token permanently
    ///      UN-RE-REGISTERABLE: `unregisterAsset` does not release the claim, so the documented
    ///      unregister-then-register repair for a wrong feed died on the second half, and `RegisterAssets`
    ///      planned it for any unregistered asset with no claimant check — so a whole chain's Safe MultiSend
    ///      reverted at execution, after the batch file had been written. With `false` the asset registers and
    ///      simply is not armed, which is the correct end state anyway: its meta adapter reports it.
    function includeAssetIfUnclaimed(
        mapping(bytes32 => address) storage claimant,
        address erc20DefaultBalanceAdapter,
        address asset,
        bool revertIfClaimed
    ) external {
        bytes32 coord = bytes32(uint256(uint160(asset)));
        address holder = claimant[coord];
        if (holder != address(0)) {
            if (revertIfClaimed) revert IBalances.MetaInstanceClaimedByAnotherAdapter(coord, holder);
            return; // already governed: registering the asset is fine, arming the default adapter is not
        }
        ERC20DefaultBalanceAdapter(erc20DefaultBalanceAdapter).addSupportedAsset(asset);
    }

    /// @dev Removes a taken coordinate from the default adapter's inclusion list — the mirror of
    ///      {_reincludeIfAsset}, and self-limiting the same way: `removeSupportedAsset` is idempotent and
    ///      unguarded on membership, so a coordinate that is not a registered asset is simply absent and the
    ///      call is a no-op.
    function _excludeIfAsset(address erc20DefaultBalanceAdapter, bytes32 instance) private {
        if (erc20DefaultBalanceAdapter == address(0)) return;
        address token = address(uint160(uint256(instance)));
        if (token == address(0)) return;
        // NOT fail-open, unlike {_reincludeIfAsset}, and the asymmetry is deliberate. `addSupportedAsset`
        // genuinely reverts `AssetNotFound` for a coordinate that is not a registered asset, so swallowing
        // that is correct. `removeSupportedAsset` has no such case: it reverts only for a caller that is not
        // its pinned `NAV_CALCULATOR`, which cannot happen for a correctly deployed pair — the library runs by
        // DELEGATECALL so `msg.sender` is the proxy, the adapter pins its NAV in an immutable, and
        // `_setErc20DefaultBalanceAdapter` is set-once, so the pairing is fixed at deploy — and
        // `EnumerableSet.remove` is unguarded on membership, so a non-asset coordinate is simply a no-op.
        // A catch here could therefore absorb nothing legitimate and only a real fault, leaving the token
        // STILL ARMED on the default adapter while a meta adapter claims it: two reporters, no health flag.
        // Failing loudly is the safe polarity on the exclude side.
        ERC20DefaultBalanceAdapter(erc20DefaultBalanceAdapter).removeSupportedAsset(token);
    }

    /// @dev Releases every coordinate in `adapter`'s set back to the default adapter, then clears the array.
    ///      Registration wipes too, so a dormant residue can never ride back in on a re-registration.
    function _releaseInstances(
        mapping(bytes32 => address) storage claimant,
        mapping(address => bytes32[]) storage metaInstances,
        address adapter,
        address erc20DefaultBalanceAdapter
    ) private returns (uint256 cleared) {
        bytes32[] storage set = metaInstances[adapter];
        cleared = set.length;
        for (uint256 i = 0; i < cleared; i++) {
            _release(claimant, adapter, set[i], erc20DefaultBalanceAdapter);
        }
        if (cleared != 0) delete metaInstances[adapter];
    }
}
