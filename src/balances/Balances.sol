// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IBalances} from "./IBalances.sol";
import {IBalanceOracleAdapter} from "./IBalanceOracleAdapter.sol";
import {IMetaBalanceOracleAdapter} from "./IMetaBalanceOracleAdapter.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";

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
    using EnumerableSet for EnumerableSet.Bytes32Set;

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

    /// @notice Whether a registered oracle is a meta-adapter (implements IMetaBalanceOracleAdapter).
    /// @dev Resolved once at registration so the hot path need not re-probe ERC165 per query.
    mapping(address oracle => bool) private _isMetaOracle;

    /// @notice Per-meta-oracle set of instance coordinates to query (e.g. vault addresses widened to bytes32).
    /// @dev This is the governed, mutable "which instances" registry that keeps adapters themselves immutable.
    mapping(address oracle => EnumerableSet.Bytes32Set instances) private _metaInstances;

    /// @dev Reserved storage gap for future Balances expansions (48 slots; 2 consumed by meta-oracle registry).
    // solhint-disable-next-line var-name-mixedcase
    uint256[48] private __balancesGap;

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
        address[] memory temp = new address[](oracleCount);
        uint256 count = 0;

        for (uint256 i = 0; i < oracleCount; i++) {
            try IBalanceOracleAdapter(_globalOracles[i]).underlyingAssetsSupported() returns (
                address[] memory supportedAssets
            ) {
                for (uint256 j = 0; j < supportedAssets.length; j++) {
                    if (supportedAssets[j] == asset) {
                        temp[count++] = _globalOracles[i];
                        break;
                    }
                }
            } catch {
                continue;
            }
        }

        return ArrayLib.copySliceAddress(temp, count);
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

        // Resolve the meta flag once, here, so per-query routing is a single SLOAD (no ERC165 probe in the hot path).
        if (oracle.supportsInterface(type(IMetaBalanceOracleAdapter).interfaceId)) {
            _isMetaOracle[oracle] = true;
        }

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

        // Clear meta-oracle state (no-op for non-meta oracles).
        if (_isMetaOracle[oracle]) {
            delete _isMetaOracle[oracle];
            EnumerableSet.Bytes32Set storage set = _metaInstances[oracle];
            bytes32[] memory existing = set.values();
            for (uint256 i = 0; i < existing.length; i++) {
                set.remove(existing[i]);
            }
        }

        // Emit event with address(0) for underlyingAsset since oracles are global
        emit BalanceOracleRemoved(address(0), oracle);
    }

    //
    // Meta-oracle instance registry
    //

    /// @inheritdoc IBalances
    function isMetaOracle(address oracle) public view override returns (bool) {
        return _isMetaOracle[oracle];
    }

    /// @inheritdoc IBalances
    function getMetaInstances(address oracle) public view override returns (bytes32[] memory) {
        return _metaInstances[oracle].values();
    }

    /// @notice Replaces the full instance set for a meta-oracle.
    /// @param oracle The registered meta-oracle.
    /// @param instances The new instance coordinates (non-zero).
    function _setMetaInstances(address oracle, bytes32[] memory instances) internal {
        _requireMetaOracle(oracle);
        EnumerableSet.Bytes32Set storage set = _metaInstances[oracle];

        bytes32[] memory existing = set.values();
        for (uint256 i = 0; i < existing.length; i++) {
            set.remove(existing[i]);
        }
        for (uint256 i = 0; i < instances.length; i++) {
            if (instances[i] == bytes32(0)) revert InvalidArguments();
            set.add(instances[i]);
        }

        emit MetaInstancesUpdated(oracle, set.values());
    }

    /// @notice Adds a single instance to a meta-oracle's set (idempotent).
    function _addMetaInstance(address oracle, bytes32 instance) internal {
        _requireMetaOracle(oracle);
        if (instance == bytes32(0)) revert InvalidArguments();
        _metaInstances[oracle].add(instance);
        emit MetaInstancesUpdated(oracle, _metaInstances[oracle].values());
    }

    /// @notice Removes a single instance from a meta-oracle's set (idempotent).
    function _removeMetaInstance(address oracle, bytes32 instance) internal {
        _requireMetaOracle(oracle);
        _metaInstances[oracle].remove(instance);
        emit MetaInstancesUpdated(oracle, _metaInstances[oracle].values());
    }

    /// @notice Reverts unless `oracle` is a registered meta-oracle.
    function _requireMetaOracle(address oracle) private view {
        if (!_isOracleRegistered[oracle] || !_isMetaOracle[oracle]) {
            revert InvalidBalanceOracle();
        }
    }
}
