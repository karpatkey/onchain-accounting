// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";

/// @title BalanceAdapterFactoryBase
/// @author kpk
/// @notice Abstract base for per-protocol balance-adapter factories.
/// @dev Each factory:
///      1. Pins a `PROTOCOL_KEY` (set by the child constructor; immutable after deploy).
///      2. Owns the per-protocol list of deployed/registered adapters.
///      3. Deploys adapter instances via the canonical CREATE2 deployer (cross-chain identical
///         instance addresses for matching constructor args + salt).
///      4. Reports each new adapter to the central `BalanceAdapterRegistry`, which holds the
///         MANAGER role on NAVCalculator and forwards to `addBalanceOracle`.
///
///      Authorization: `deploy(...)` and `registerExternal(...)` are owner-only — same authority
///      that today calls `NAVCalculator.addBalanceOracle` directly. Factories don't expand
///      permissions; they bundle deploy + register.
abstract contract BalanceAdapterFactoryBase is Ownable {
    /// @notice Canonical Foundry / CreateX CREATE2 deployer (same address on every EVM chain).
    address public constant CANONICAL_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Stable identifier for this factory's protocol (e.g. keccak256("BalancerV3")).
    bytes32 public immutable PROTOCOL_KEY;

    /// @notice The NAVCalculator that adapter instances will report balances to.
    address public immutable NAV_CALCULATOR;

    /// @notice The central registry; owns the MANAGER role on NAVCalculator.
    address public immutable REGISTRY;

    /// @dev Append-only list of every adapter tracked by this factory (deployed or registered).
    address[] internal _adapters;

    /// @notice Whether the adapter was deployed by `deploy(...)` (true) or added via `registerExternal` (false).
    mapping(address adapter => bool) public isFromFactory;

    /// @notice Whether the adapter is tracked in `_adapters` at all.
    mapping(address adapter => bool) public isTracked;

    /// @notice Emitted when a new adapter instance is deployed via `deploy(...)`.
    event AdapterDeployed(address indexed adapter, bytes32 indexed salt);

    /// @notice Emitted when an externally-deployed adapter is registered via `registerExternal(...)`.
    event AdapterRegisteredExternal(address indexed adapter);

    /// @notice Emitted when an adapter is dropped from this factory's list (via the registry's unregister hook).
    event AdapterRemoved(address indexed adapter);

    error AdapterAlreadyTracked();
    error AdapterNotTracked();
    error NotAnAdapter();
    error WrongAdapterType();
    error ZeroAddress();
    error Create2DeployFailed();
    error OnlyRegistry();

    constructor(bytes32 protocolKey, address registry, address navCalculator, address initialOwner)
        Ownable(initialOwner)
    {
        if (protocolKey == bytes32(0)) revert ZeroAddress();
        if (registry == address(0) || navCalculator == address(0) || initialOwner == address(0)) {
            revert ZeroAddress();
        }
        PROTOCOL_KEY = protocolKey;
        REGISTRY = registry;
        NAV_CALCULATOR = navCalculator;
    }

    /// @notice Owner-only: register an externally-deployed adapter as belonging to this factory's protocol.
    ///         Used to absorb pre-existing adapters that were deployed before the factory existed.
    /// @dev Verifies the adapter is an `IBalanceOracleAdapter` (ERC165) and that its runtime bytecode
    ///      matches the expected concrete type (per `_validateAdapterType`). Also forwards to the
    ///      central registry, which handles NAV registration idempotently.
    /// @param adapter Address of the adapter to register.
    function registerExternal(address adapter) external onlyOwner {
        _track(adapter, false);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterRegisteredExternal(adapter);
    }

    /// @notice Hook called by the registry on `Registry.unregister(adapter)` so this factory
    ///         can drop the adapter from its own list.
    /// @dev Only the central registry may call this. The adapter is marked untracked but
    ///      stays in `_adapters` (lookup helpers should consult `isTracked`).
    function onAdapterUnregistered(address adapter) external {
        if (msg.sender != REGISTRY) revert OnlyRegistry();
        if (!isTracked[adapter]) revert AdapterNotTracked();
        isTracked[adapter] = false;
        emit AdapterRemoved(adapter);
    }

    /// @notice Returns every adapter ever tracked by this factory (including unregistered ones).
    /// @dev Filter on `isTracked[adapter]` to get the live set.
    function getAdapters() external view returns (address[] memory) {
        return _adapters;
    }

    /// @notice Number of entries in the historical `_adapters` list.
    function adapterCount() external view returns (uint256) {
        return _adapters.length;
    }

    /// @notice Returns only the currently-tracked adapters (excludes ones that were unregistered).
    function getActiveAdapters() external view returns (address[] memory active) {
        uint256 n = _adapters.length;
        uint256 liveCount;
        for (uint256 i; i < n; ++i) {
            if (isTracked[_adapters[i]]) liveCount++;
        }
        active = new address[](liveCount);
        uint256 j;
        for (uint256 i; i < n; ++i) {
            address a = _adapters[i];
            if (isTracked[a]) {
                active[j++] = a;
            }
        }
    }

    /// @dev Generic adapter validation: ERC165 check + optional per-factory type pin.
    ///      `deploy(...)` ensures correct typing intrinsically (CREATE2 over the adapter's
    ///      own creation code). For `registerExternal(...)` the owner is trusted; if a
    ///      stronger on-chain check is desired, children may override `_validateAdapterType`.
    function _track(address adapter, bool fromFactory) internal {
        if (adapter == address(0)) revert ZeroAddress();
        if (isTracked[adapter]) revert AdapterAlreadyTracked();
        if (!IERC165(adapter).supportsInterface(type(IBalanceOracleAdapter).interfaceId)) {
            revert NotAnAdapter();
        }
        _validateAdapterType(adapter);
        _adapters.push(adapter);
        isTracked[adapter] = true;
        isFromFactory[adapter] = fromFactory;
    }

    /// @dev Optional per-factory adapter-type check, called from `_track`. Default: no-op.
    ///      A robust check at this level is awkward — runtime bytecode hashes diverge between
    ///      `type(C).runtimeCode` (with zero-immutables) and a deployed contract's `.code`
    ///      (with immutables baked in). For instances we deployed via this factory the
    ///      typing is intrinsic (CREATE2 of our own initCode); for `registerExternal` the
    ///      owner is trusted. Children may override to call a protocol-specific view that
    ///      only the expected adapter implements.
    function _validateAdapterType(address adapter) internal view virtual {
        // Intentionally empty.
    }

    /// @dev CREATE2 deploy via the canonical deployer at `CANONICAL_CREATE2_DEPLOYER`.
    ///      Reverts if the deployer call fails or returns zero-length data.
    /// @param salt User-chosen salt; address depends on (deployer, salt, initCode hash).
    /// @param initCode `abi.encodePacked(creationCode, abi.encode(constructorArgs))`.
    /// @return deployed The deployed contract address (also predictable via `_predictCreate2`).
    function _deployCreate2(bytes32 salt, bytes memory initCode) internal returns (address deployed) {
        deployed = _predictCreate2(salt, keccak256(initCode));
        // Idempotent: if code is already there, treat as success.
        if (deployed.code.length > 0) return deployed;

        bytes memory payload = abi.encodePacked(salt, initCode);
        (bool ok, bytes memory ret) = CANONICAL_CREATE2_DEPLOYER.call(payload);
        if (!ok || deployed.code.length == 0) revert Create2DeployFailed();
        // Some CREATE2 deployers return the deployed address; cross-check if so.
        if (ret.length == 32) {
            address fromReturn = abi.decode(ret, (address));
            if (fromReturn != deployed) revert Create2DeployFailed();
        }
    }

    /// @notice Predict the CREATE2 address for a deployment with the given salt + init code.
    function _predictCreate2(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CANONICAL_CREATE2_DEPLOYER, salt, initCodeHash))))
        );
    }
}
