// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {INAVCalculator} from "./INAVCalculator.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title NavRegistryLib
/// @notice External library for NAVCalculator's registry storage mutations (the asset registry + the balance-oracle
///         registry), extracted to keep NAVCalculator under EIP-170 (mirrors the PriceFeedLib pattern).
/// @dev Functions are `external` so the library compiles as a separate artifact and is invoked via DELEGATECALL,
///      operating on the caller's own storage through the passed `storage` references. Pre-linked at a deterministic
///      CREATE2 address (see `foundry.toml`) and deployed by `01_2_DeployNAVImplementation.s.sol` before NAVCalculator.
///      Only the heavier, no-return mutations live here (register/unregister asset; add/remove oracle); the trivial
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
    // Balance-oracle registry
    // -------------------------------------------------------------------------

    /// @notice Adds a balance oracle to the global registry (Custom type), after validating it supports the
    ///         IBalanceOracleAdapter interface. Mirrors the storage work of the former Balances._addBalanceOracle;
    ///         the running count and the BalanceOracleAdded event stay in the caller wrapper.
    /// @param isOracleRegistered Quick-lookup registration map (storage ref)
    /// @param globalOracles The global oracle list (storage ref)
    /// @param oracleTypes The oracle-type map (storage ref)
    /// @param oracle The oracle to add
    function addBalanceOracle(
        mapping(address => bool) storage isOracleRegistered,
        address[] storage globalOracles,
        mapping(address => IBalances.OracleType) storage oracleTypes,
        address oracle
    ) external {
        if (isOracleRegistered[oracle]) {
            revert IBalances.DuplicateBalanceOracle();
        }
        if (oracle == address(0)) revert InvalidArguments();
        if (!oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId)) {
            revert IBalances.InvalidBalanceOracle();
        }

        globalOracles.push(oracle);
        oracleTypes[oracle] = IBalances.OracleType.Custom;
        isOracleRegistered[oracle] = true;
    }

    /// @notice Removes an oracle from the global registry (swap-remove). Reverts on the ERC20Default singleton or an
    ///         unregistered oracle. Mirrors the storage work of the former Balances._removeBalanceOracle; the running
    ///         count and the BalanceOracleRemoved event stay in the caller wrapper.
    /// @param isOracleRegistered Quick-lookup registration map (storage ref)
    /// @param globalOracles The global oracle list (storage ref)
    /// @param oracleTypes The oracle-type map (storage ref)
    /// @param oracle The oracle to remove
    /// @param erc20DefaultOracle The default-oracle singleton that may not be removed
    function removeBalanceOracle(
        mapping(address => bool) storage isOracleRegistered,
        address[] storage globalOracles,
        mapping(address => IBalances.OracleType) storage oracleTypes,
        address oracle,
        address erc20DefaultOracle
    ) external {
        if (oracle == erc20DefaultOracle) {
            revert InvalidArguments(); // Cannot remove ERC20DefaultOracle
        }
        if (!isOracleRegistered[oracle]) {
            revert IBalances.InvalidBalanceOracle();
        }

        uint256 len = globalOracles.length;
        for (uint256 i = 0; i < len; i++) {
            if (globalOracles[i] == oracle) {
                globalOracles[i] = globalOracles[len - 1];
                globalOracles.pop();
                break;
            }
        }

        delete isOracleRegistered[oracle];
        delete oracleTypes[oracle];
    }
}
