// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IBalances} from "./IBalances.sol";
import {IBalanceOracleCustom} from "./IBalanceOracleCustom.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import "src/errors.sol";

/// @title Balances
/// @author kpk
/// @notice Manages the balance oracles for different tokens and their latest balances.
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

    /// @notice Mapping from token address to balance oracles.
    mapping(address token => EnumerableMap.AddressToUintMap oracles) private _balanceOracles;

    /// @notice Total count of balance oracles.
    uint256 public balanceOracleTotalCount;

    /// @notice Global oracle registry - all oracles in the system
    address[] private _globalOracles;

    /// @notice Mapping from oracle address to oracle type
    mapping(address oracle => OracleType) private _oracleTypes;

    /// @notice Quick lookup for oracle registration
    mapping(address oracle => bool) private _isOracleRegistered;

    /// @notice Asset registry - decimals for each registered asset
    EnumerableMap.AddressToUintMap private _assetDecimals;

    /// @notice Asset registry - symbols for each registered asset
    mapping(address asset => string) private _assetSymbols;

    /// @notice ERC20Default oracle singleton (automatically registered)
    /// @dev Set during initialization by derived contract
    address public erc20DefaultOracle;

    //
    // Constructor
    //

    /// @notice Initializer for UUPS proxy
    /// @dev Derived contracts should deploy ERC20DefaultOracle and call _setErc20DefaultOracle()
    // solhint-disable-next-line func-name-mixedcase
    // forge-lint: disable-next-line(mixed-case-function)
    function __Balances_init() internal onlyInitializing {
        _nativeTokenSymbol = "ETH"; // Default value, can be overridden by derived contracts
    }

    /// @notice Internal function to set and register the ERC20Default oracle
    /// @dev Called by derived contracts after deploying ERC20DefaultOracle
    /// @param defaultOracle The address of the deployed ERC20DefaultOracle
    function _setErc20DefaultOracle(address defaultOracle) internal {
        if (erc20DefaultOracle != address(0)) {
            revert InvalidArguments(); // Already set
        }
        erc20DefaultOracle = defaultOracle;

        // Add to global oracle registry
        _globalOracles.push(erc20DefaultOracle);
        _oracleTypes[erc20DefaultOracle] = OracleType.ERC20; // ERC20Default handles both ERC20 and Native
        _isOracleRegistered[erc20DefaultOracle] = true;
    }

    //
    // IBalances
    //

    /// @inheritdoc IBalances
    function balanceOf(address underlyingAsset, uint256 idx, address account) public view returns (int256) {
        if (idx >= _balanceOracles[underlyingAsset].length()) {
            revert BalanceOracleNotSet();
        }

        (address oracleAddress, uint256 balanceTypeUInt) = _balanceOracles[underlyingAsset].at(idx);
        OracleType balanceType = OracleType(balanceTypeUInt);

        if (oracleAddress == address(0)) {
            revert BalanceOracleNotSet();
        }

        int256 balance;

        if (balanceType == OracleType.ERC20) {
            balance = ERC20(oracleAddress).balanceOf(account).toInt256();
        } else if (balanceType == OracleType.Native) {
            balance = address(account).balance.toInt256();
        } else {
            balance = IBalanceOracleCustom(oracleAddress).balanceOf(underlyingAsset, account);
        }

        return balance;
    }

    /// @inheritdoc IBalances
    function balanceOracleCountFor(address underlyingAsset) public view override returns (uint256) {
        return _balanceOracles[underlyingAsset].length();
    }

    /// @inheritdoc IBalances
    function balanceOracleAt(address underlyingAsset, uint256 idx) public view override returns (address, OracleType) {
        (address oracleAddress, uint256 balanceTypeUInt) = _balanceOracles[underlyingAsset].at(idx);
        return (oracleAddress, OracleType(balanceTypeUInt));
    }

    /// @inheritdoc IBalances
    function balanceOracles(address underlyingAsset) public view override returns (address[] memory) {
        return _balanceOracles[underlyingAsset].keys();
    }

    /// @inheritdoc IBalances
    function checkBalanceOracleSupport(address underlyingAsset, address oracle, OracleType balanceType) public view {
        if (oracle == address(0) || underlyingAsset == address(0)) revert InvalidArguments();

        if (balanceType == OracleType.Custom) {
            if (!oracle.supportsInterface(type(IBalanceOracleCustom).interfaceId)) {
                revert InvalidBalanceOracle();
            }
        } else if (balanceType == OracleType.ERC20) {
            ERC20(oracle).balanceOf(address(this));
        } else if (balanceType == OracleType.Native) {
            // Native balance oracles are always supported, added in the constructor
            revert DuplicateBalanceOracle();
        } else {
            revert InvalidBalanceOracleType();
        }

        if (_balanceOracles[underlyingAsset].contains(oracle)) {
            revert DuplicateBalanceOracle();
        }
    }

    /// @inheritdoc IBalances
    function getAllOracles() public view override returns (address[] memory) {
        return _globalOracles;
    }

    /// @inheritdoc IBalances
    function getOracleCount() public view override returns (uint256) {
        return _globalOracles.length;
    }

    /// @inheritdoc IBalances
    function isOracleRegistered(address oracle) public view override returns (bool) {
        return _isOracleRegistered[oracle];
    }

    /// @inheritdoc IBalances
    function getOracleType(address oracle) public view override returns (OracleType) {
        if (!_isOracleRegistered[oracle]) {
            revert InvalidBalanceOracle();
        }
        return _oracleTypes[oracle];
    }

    /// @inheritdoc IBalances
    function isAssetRegistered(address asset) public view override returns (bool) {
        return _assetDecimals.contains(asset);
    }

    /// @inheritdoc IBalances
    function getAssets() public view override returns (address[] memory) {
        return _assetDecimals.keys();
    }

    /// @inheritdoc IBalances
    function getAssetCount() public view override returns (uint256) {
        return _assetDecimals.length();
    }

    /// @inheritdoc IBalances
    function getAssetDecimals(address asset) public view override returns (uint8) {
        (bool contains, uint256 decimals) = _assetDecimals.tryGet(asset);
        if (!contains) {
            revert AssetNotFound();
        }
        // casting to 'uint8' is safe because ERC20 decimals are always in range 0-255
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(decimals);
    }

    /// @inheritdoc IBalances
    function getAssetSymbol(address asset) public view override returns (string memory) {
        return _assetSymbols[asset];
    }

    //
    // Internal API
    //

    /// @notice Adds a balance oracle for a given underlying asset.
    /// @param underlyingAsset The address of the token.
    /// @param oracle The address of the oracle.
    /// @param balanceType The type of the oracle.
    function _addBalanceOracle(address underlyingAsset, address oracle, OracleType balanceType) internal {
        checkBalanceOracleSupport(underlyingAsset, oracle, balanceType);

        _balanceOracles[underlyingAsset].set(oracle, uint256(balanceType));
        balanceOracleTotalCount++;

        // Add to global oracle registry if not already registered
        if (!_isOracleRegistered[oracle]) {
            _globalOracles.push(oracle);
            _oracleTypes[oracle] = balanceType;
            _isOracleRegistered[oracle] = true;
        }

        emit BalanceOracleAdded(underlyingAsset, oracle, balanceType);
    }

    /// @notice Removes the oracle for a given underlying asset.
    /// @param underlyingAsset The address of the token.
    /// @param oracle The address of the oracle.
    function _removeBalanceOracle(address underlyingAsset, address oracle) internal {
        if (underlyingAsset == NATIVE_ADDRESS && oracle == NATIVE_ADDRESS) revert InvalidArguments();

        bool removed = _balanceOracles[underlyingAsset].remove(oracle);

        if (!removed) {
            revert InvalidBalanceOracle();
        }

        balanceOracleTotalCount--;

        // Check if oracle is still used by any other asset
        // If not, remove from global registry (for now, keep it simple - don't remove from global registry)
        // In the future, we can track per-asset usage and remove only when unused

        emit BalanceOracleRemoved(underlyingAsset, oracle);
    }

    /// @notice Registers an asset in the asset registry
    /// @param asset The asset address
    /// @param decimals The number of decimals for the asset
    function _registerAsset(address asset, uint8 decimals) internal {
        if (_assetDecimals.contains(asset)) {
            revert InvalidArguments(); // Asset already registered
        }
        _assetDecimals.set(asset, decimals);
    }

    /// @notice Unregisters an asset from the asset registry
    /// @param asset The asset address
    function _unregisterAsset(address asset) internal {
        bool removed = _assetDecimals.remove(asset);
        if (!removed) {
            revert AssetNotFound();
        }
        // Clear symbol mapping
        delete _assetSymbols[asset];
    }

    /// @notice Gets asset decimals from registry
    /// @param asset The asset address
    /// @return decimals The number of decimals
    function _getAssetDecimals(address asset) internal view virtual returns (uint8) {
        (bool contains, uint256 decimals) = _assetDecimals.tryGet(asset);
        if (!contains) {
            revert AssetNotFound();
        }
        // casting to 'uint8' is safe because ERC20 decimals are always in range 0-255
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(decimals);
    }

    /// @notice Sets asset symbol in registry
    /// @param asset The asset address
    /// @param symbol The asset symbol
    function _setAssetSymbol(address asset, string memory symbol) internal {
        _assetSymbols[asset] = symbol;
    }

    /// @notice Gets asset symbol from registry
    /// @param asset The asset address
    /// @return symbol The asset symbol
    function _getAssetSymbol(address asset) internal view returns (string memory) {
        return _assetSymbols[asset];
    }

    /// @notice Gap for upgradeability
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[50] private __gap;
}
