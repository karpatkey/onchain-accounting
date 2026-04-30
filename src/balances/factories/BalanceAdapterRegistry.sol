// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";
import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";

/// @title BalanceAdapterRegistry
/// @author kpk
/// @notice Central registry that maps protocol keys to per-protocol balance-adapter factories
///         and aggregates every adapter ever registered across protocols.
/// @dev The registry is the *exclusive* path to `NAVCalculator.addBalanceOracle` and
///      `removeBalanceOracle` — once it holds the MANAGER role, the OIV Safe stops calling
///      NAVCalculator directly and instead routes everything through the registry's
///      `registerExternal` / `unregister` functions.
///
///      Two write paths into the registry:
///        1. `register(adapter)` — called by a protocol factory; resolves the protocol key
///           from `msg.sender`, records the adapter, and forwards to NAVCalculator.
///        2. `registerExternal(key, adapter)` — owner escape hatch; registers an adapter
///           under any key without going through a factory (for adapters whose protocol
///           factory isn't deployed yet, or one-off cases).
///
///      Both paths converge in `_register`, which idempotently calls `addBalanceOracle`
///      only when the adapter is not yet registered there. This makes migration of the
///      ~30 already-deployed adapters painless: they're already in NAV; the registry
///      just records them.
contract BalanceAdapterRegistry is Ownable, IBalanceAdapterRegistry {
    /// @notice The NAVCalculator the registry holds MANAGER on.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice protocolKey ⇒ per-protocol factory.
    mapping(bytes32 protocolKey => address) public factory;

    /// @notice Reverse lookup: factory ⇒ protocolKey. Cleared when `setFactory(key, address(0))`.
    mapping(address factoryAddr => bytes32) public factoryProtocolKey;

    /// @notice Ordered list of every protocol key that has been associated with a factory at some point.
    /// @dev Append-only; clearing a factory does not remove the key from this list.
    bytes32[] public protocolKeys;

    /// @notice Whether `protocolKeys` already contains this key (avoids double-push on re-set).
    mapping(bytes32 protocolKey => bool) internal _protocolKeySeen;

    /// @notice Append-only list of every adapter ever registered.
    /// @dev Filter by `isAdapterRegistered[adapter]` to get the live set.
    address[] internal _allAdapters;

    /// @notice adapter ⇒ protocolKey it was registered under.
    mapping(address adapter => bytes32) public adapterProtocol;

    /// @notice Whether the adapter is currently registered.
    mapping(address adapter => bool) public isAdapterRegistered;

    event FactorySet(bytes32 indexed protocolKey, address indexed previous, address indexed current);
    event AdapterRegistered(bytes32 indexed protocolKey, address indexed adapter, bool wasInNAV);
    event AdapterUnregistered(bytes32 indexed protocolKey, address indexed adapter);

    error UnknownProtocolKey();
    error FactoryNotAuthorized();
    error AdapterAlreadyRegistered();
    error AdapterNotRegistered();
    error ZeroAddress();
    error NotAnAdapter();

    constructor(address navCalculator, address initialOwner) Ownable(initialOwner) {
        if (navCalculator == address(0) || initialOwner == address(0)) revert ZeroAddress();
        NAV_CALCULATOR = INAVCalculator(navCalculator);
    }

    /// @notice Owner-only: set, replace, or unset the factory for a given protocol key.
    /// @dev Setting `newFactory == address(0)` unsets the mapping but preserves the key in
    ///      `protocolKeys` for historical lookups. Re-setting later just overwrites.
    /// @param protocolKey Stable identifier (e.g. keccak256("BalancerV3")).
    /// @param newFactory Address of the per-protocol factory; address(0) to unset.
    function setFactory(bytes32 protocolKey, address newFactory) external onlyOwner {
        if (protocolKey == bytes32(0)) revert UnknownProtocolKey();
        address prev = factory[protocolKey];
        if (prev != address(0)) {
            delete factoryProtocolKey[prev];
        }
        factory[protocolKey] = newFactory;
        if (newFactory != address(0)) {
            factoryProtocolKey[newFactory] = protocolKey;
            if (!_protocolKeySeen[protocolKey]) {
                _protocolKeySeen[protocolKey] = true;
                protocolKeys.push(protocolKey);
            }
        }
        emit FactorySet(protocolKey, prev, newFactory);
    }

    /// @inheritdoc IBalanceAdapterRegistry
    function register(address adapter) external {
        bytes32 key = factoryProtocolKey[msg.sender];
        if (key == bytes32(0)) revert FactoryNotAuthorized();
        _register(key, adapter);
    }

    /// @notice Owner-only escape hatch — register an adapter under any key without going
    ///         through a factory. Used for singletons not yet given a factory or for
    ///         absorbing adapters whose factory has been retired.
    /// @dev Skips the per-factory adapter-type check (owner-trusted).
    /// @param protocolKey Key to associate the adapter with (must be non-zero).
    /// @param adapter Address of the adapter to register.
    function registerExternal(bytes32 protocolKey, address adapter) external onlyOwner {
        if (protocolKey == bytes32(0)) revert UnknownProtocolKey();
        _register(protocolKey, adapter);
    }

    /// @notice Owner-only: remove an adapter from the registry and from NAVCalculator.
    /// @dev Calls `NAV.removeBalanceOracle(adapter)` (registry holds MANAGER) and notifies
    ///      the protocol factory (if any) via `onAdapterUnregistered` so its own list stays
    ///      consistent. The adapter stays in `_allAdapters` for historical lookup but
    ///      `isAdapterRegistered[adapter]` becomes false.
    function unregister(address adapter) external onlyOwner {
        if (!isAdapterRegistered[adapter]) revert AdapterNotRegistered();
        bytes32 key = adapterProtocol[adapter];
        isAdapterRegistered[adapter] = false;
        NAV_CALCULATOR.removeBalanceOracle(adapter);

        address f = factory[key];
        if (f != address(0)) {
            // Best-effort notify — if the factory's hook reverts, surface it to the owner.
            BalanceAdapterFactoryBase(f).onAdapterUnregistered(adapter);
        }
        emit AdapterUnregistered(key, adapter);
    }

    function _register(bytes32 protocolKey, address adapter) internal {
        if (adapter == address(0)) revert ZeroAddress();
        if (isAdapterRegistered[adapter]) revert AdapterAlreadyRegistered();
        if (!IERC165(adapter).supportsInterface(type(IBalanceOracleAdapter).interfaceId)) {
            revert NotAnAdapter();
        }

        _allAdapters.push(adapter);
        adapterProtocol[adapter] = protocolKey;
        isAdapterRegistered[adapter] = true;

        bool wasInNAV = NAV_CALCULATOR.isOracleRegistered(adapter);
        if (!wasInNAV) {
            NAV_CALCULATOR.addBalanceOracle(adapter);
        }
        emit AdapterRegistered(protocolKey, adapter, wasInNAV);
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    /// @notice Every adapter ever registered (filter by `isAdapterRegistered`).
    function getAllAdapters() external view returns (address[] memory) {
        return _allAdapters;
    }

    /// @notice Currently-registered adapters across all protocols.
    function getActiveAdapters() external view returns (address[] memory active) {
        uint256 n = _allAdapters.length;
        uint256 liveCount;
        for (uint256 i; i < n; ++i) {
            if (isAdapterRegistered[_allAdapters[i]]) liveCount++;
        }
        active = new address[](liveCount);
        uint256 j;
        for (uint256 i; i < n; ++i) {
            address a = _allAdapters[i];
            if (isAdapterRegistered[a]) {
                active[j++] = a;
            }
        }
    }

    /// @notice Currently-registered adapters for a given protocol key.
    /// @dev If a factory exists for the key, delegates to `factory.getActiveAdapters()`.
    ///      Otherwise iterates `_allAdapters` and filters.
    function getAdaptersByProtocol(bytes32 key) external view returns (address[] memory) {
        address f = factory[key];
        if (f != address(0)) {
            return BalanceAdapterFactoryBase(f).getActiveAdapters();
        }
        uint256 n = _allAdapters.length;
        uint256 liveCount;
        for (uint256 i; i < n; ++i) {
            address a = _allAdapters[i];
            if (isAdapterRegistered[a] && adapterProtocol[a] == key) liveCount++;
        }
        address[] memory result = new address[](liveCount);
        uint256 j;
        for (uint256 i; i < n; ++i) {
            address a = _allAdapters[i];
            if (isAdapterRegistered[a] && adapterProtocol[a] == key) {
                result[j++] = a;
            }
        }
        return result;
    }

    /// @notice All protocol keys that have ever been associated with a factory.
    function getProtocolKeys() external view returns (bytes32[] memory) {
        return protocolKeys;
    }

    /// @notice Total number of adapters ever registered (including currently-unregistered ones).
    function adapterCount() external view returns (uint256) {
        return _allAdapters.length;
    }
}
