// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IBalances} from "./IBalances.sol";
import {IBalanceOracleAdapter} from "./IBalanceOracleAdapter.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
import {NavRegistryLib} from "src/nav/NavRegistryLib.sol";

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

    /// @notice Per-oracle list of meta-adapter instance coordinates to query (e.g. vault addresses widened to
    ///         bytes32). This is the governed, mutable "which instances" registry that keeps adapters immutable.
    ///         Only meta-adapters read it (via getMetaInstances(address(this))); it is inert for other oracles.
    ///         Callers of setMetaInstances must supply a deduplicated list (a duplicate would double-count NAV).
    mapping(address oracle => bytes32[] instances) private _metaInstances;

    /// @notice Running total of configured meta instances across all oracles (cheap NAV buffer sizing).
    uint256 internal _metaInstanceTotal;

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
        // Storage mutation + interface validation delegated to NavRegistryLib (external library, DELEGATECALL) to
        // keep NAVCalculator under EIP-170; the running count + event stay inline (cheaper than crossing the boundary).
        NavRegistryLib.addBalanceOracle(_isOracleRegistered, _globalOracles, _oracleTypes, oracle);
        balanceOracleTotalCount++;

        // Emit event with address(0) for underlyingAsset since oracles are global
        emit BalanceOracleAdded(address(0), oracle, OracleType.Custom);
    }

    /// @notice Removes the oracle from the global registry.
    /// @param oracle The address of the oracle.
    function _removeBalanceOracle(address oracle) internal {
        // Storage mutation + guards delegated to NavRegistryLib (see _addBalanceOracle); count + event stay inline.
        NavRegistryLib.removeBalanceOracle(
            _isOracleRegistered, _globalOracles, _oracleTypes, oracle, erc20DefaultOracle
        );
        balanceOracleTotalCount--;

        // Note: a removed oracle's configured meta-instance set (if any) is left dormant — it is no longer
        // queried since the oracle is out of the registry. _metaInstanceTotal only sizes read buffers (an
        // overestimate is harmless), and a re-registered oracle's set is reset by the next setMetaInstances.

        // Emit event with address(0) for underlyingAsset since oracles are global
        emit BalanceOracleRemoved(address(0), oracle);
    }

    //
    // Meta-oracle instance registry
    //

    /// @inheritdoc IBalances
    function getMetaInstances(address oracle) public view override returns (bytes32[] memory) {
        return _metaInstances[oracle];
    }

    /// @notice Replaces the full instance set for a meta-oracle (ADR 0010). The caller must supply a
    ///         deduplicated list; only meta-adapters read this set, so it is a no-op for other oracles. A zero
    ///         entry is harmless — the adapter's per-instance read reverts and is isolated to an empty result.
    /// @param oracle The registered oracle.
    /// @param instances The new instance coordinates.
    function _setMetaInstances(address oracle, bytes32[] memory instances) internal {
        if (!_isOracleRegistered[oracle]) {
            revert InvalidBalanceOracle();
        }

        _metaInstanceTotal = _metaInstanceTotal - _metaInstances[oracle].length + instances.length;
        _metaInstances[oracle] = instances;
    }
}
