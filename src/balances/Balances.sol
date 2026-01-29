// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IBalances} from "./IBalances.sol";
import {IBalanceOracleAdapter} from "./IBalanceOracleAdapter.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {InvalidArguments} from "src/errors.sol";

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
        _nativeTokenSymbol = "ETH"; // Default value; override via _setNativeTokenSymbol in derived init
    }

    /// @notice Sets the native token symbol (e.g. "ETH", "xDAI"). Call from derived contract's initializer.
    /// @param symbol The native token symbol
    function _setNativeTokenSymbol(string memory symbol) internal {
        _nativeTokenSymbol = symbol;
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
        _oracleTypes[erc20DefaultOracle] = OracleType.Default; // ERC20Default handles both ERC20 and Native
        _isOracleRegistered[erc20DefaultOracle] = true;
    }

    //
    // IBalances
    //

    /// @inheritdoc IBalances
    function checkBalanceOracleSupport(address oracle) public view {
        if (oracle == address(0)) revert InvalidArguments();

        if (!oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId)) {
            revert InvalidBalanceOracle();
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
    function getOraclesForAsset(address asset) public view override returns (address[] memory) {
        uint256 oracleCount = _globalOracles.length;
        bool[] memory supportsAsset = new bool[](oracleCount);
        uint256 count = 0;

        // Single pass: check which oracles support this asset
        for (uint256 i = 0; i < oracleCount; i++) {
            address oracle = _globalOracles[i];
            try IBalanceOracleAdapter(oracle).underlyingAssetsSupported() returns (address[] memory supportedAssets) {
                // Check if asset is in the supported assets list
                for (uint256 j = 0; j < supportedAssets.length; j++) {
                    if (supportedAssets[j] == asset) {
                        supportsAsset[i] = true;
                        count++;
                        break; // Found it, move to next oracle
                    }
                }
            } catch {
                // If the call fails, skip this oracle (supportsAsset[i] remains false)
                continue;
            }
        }

        // Create array with the correct length and populate with supporting oracles
        address[] memory supportingOracles = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < oracleCount; i++) {
            if (supportsAsset[i]) {
                supportingOracles[index] = _globalOracles[i];
                index++;
            }
        }

        return supportingOracles;
    }

    //
    // Internal API
    //

    /// @notice Adds a balance oracle globally.
    /// @param oracle The address of the oracle.
    function _addBalanceOracle(address oracle) internal {
        // Check if oracle is already registered globally
        if (_isOracleRegistered[oracle]) {
            revert DuplicateBalanceOracle();
        }

        OracleType balanceType = OracleType.Custom;
        checkBalanceOracleSupport(oracle);

        // Add to global oracle registry
        _globalOracles.push(oracle);
        _oracleTypes[oracle] = balanceType;
        _isOracleRegistered[oracle] = true;
        balanceOracleTotalCount++;

        // Emit event with address(0) for underlyingAsset since oracles are global
        emit BalanceOracleAdded(address(0), oracle, balanceType);
    }

    /// @notice Removes the oracle from the global registry.
    /// @param oracle The address of the oracle.
    function _removeBalanceOracle(address oracle) internal {
        if (oracle == erc20DefaultOracle) {
            revert InvalidArguments(); // Cannot remove ERC20DefaultOracle
        }

        if (!_isOracleRegistered[oracle]) {
            revert InvalidBalanceOracle();
        }

        // Remove from global registry
        uint256 oracleIndex = _globalOracles.length;
        for (uint256 i = 0; i < _globalOracles.length; i++) {
            if (_globalOracles[i] == oracle) {
                oracleIndex = i;
                break;
            }
        }

        if (oracleIndex < _globalOracles.length) {
            // Move last element to the position of the element to delete
            _globalOracles[oracleIndex] = _globalOracles[_globalOracles.length - 1];
            _globalOracles.pop();
        }

        delete _isOracleRegistered[oracle];
        delete _oracleTypes[oracle];
        balanceOracleTotalCount--;

        // Emit event with address(0) for underlyingAsset since oracles are global
        emit BalanceOracleRemoved(address(0), oracle);
    }

    /// @notice Gap for upgradeability
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[50] private __gap;
}
