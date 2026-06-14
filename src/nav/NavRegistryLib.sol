// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {INAVCalculator} from "./INAVCalculator.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title NavRegistryLib
/// @notice External library for NAVCalculator's registry storage mutations (the asset registry + the balance-adapter
///         registry), extracted to keep NAVCalculator under EIP-170 (mirrors the PriceFeedLib pattern).
/// @dev Functions are `external` so the library compiles as a separate artifact and is invoked via DELEGATECALL,
///      operating on the caller's own storage through the passed `storage` references. Pre-linked at a deterministic
///      CREATE2 address (see `foundry.toml`) and deployed by `01_2_DeployNAVImplementation.s.sol` before NAVCalculator.
///      Only the heavier, no-return mutations live here (register/unregister asset; add/remove adapter); the trivial
///      getters and the running counts / event emission stay inline in the caller (cheaper than crossing the boundary).
library NavRegistryLib {
    using ERC165Checker for address;

    /// @notice Native-asset sentinel (mirrors Balances.NATIVE_ADDRESS).
    address private constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

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
        if (isAdapterRegistered[adapter]) {
            revert IBalances.DuplicateBalanceAdapter();
        }
        if (adapter == address(0)) revert InvalidArguments();
        if (!adapter.supportsInterface(type(IBalanceAdapter).interfaceId)) {
            revert IBalances.InvalidBalanceAdapter();
        }

        globalAdapters.push(adapter);
        adapterTypes[adapter] = IBalances.AdapterType.Custom;
        isAdapterRegistered[adapter] = true;
    }

    /// @notice Removes an adapter from the global registry (swap-remove). Reverts on the ERC20Default singleton or an
    ///         unregistered adapter. Mirrors the storage work of the former Balances._removeBalanceAdapter; the running
    ///         count and the BalanceAdapterRemoved event stay in the caller wrapper.
    /// @param isAdapterRegistered Quick-lookup registration map (storage ref)
    /// @param globalAdapters The global adapter list (storage ref)
    /// @param adapterTypes The adapter-type map (storage ref)
    /// @param adapter The adapter to remove
    /// @param erc20DefaultAdapter The default-adapter singleton that may not be removed
    function removeBalanceAdapter(
        mapping(address => bool) storage isAdapterRegistered,
        address[] storage globalAdapters,
        mapping(address => IBalances.AdapterType) storage adapterTypes,
        address adapter,
        address erc20DefaultAdapter
    ) external {
        if (adapter == erc20DefaultAdapter) {
            revert InvalidArguments(); // Cannot remove ERC20DefaultAdapter
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
}
