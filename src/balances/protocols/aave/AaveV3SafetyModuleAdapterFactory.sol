// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";
import {AaveV3SafetyModuleBalanceOracle} from "src/balances/protocols/aave/AaveV3SafetyModule.sol";

/// @title AaveV3SafetyModuleAdapterFactory
/// @author kpk
/// @notice Deploys & registers a single multi-token `AaveV3SafetyModuleBalanceOracle` per chain.
/// @dev Diverges from the rest of the framework in two ways, both intentional:
///      1. Deploys ONE adapter per chain (not one per stake token); subsequent stake tokens are added
///         via `adapter.addStakeToken(...)` rather than additional factory calls.
///      2. The deployed adapter is `Ownable`. The factory passes `admin` (typically the OIV Safe) into
///         the adapter constructor so the Safe — not the factory — manages the stake-token list.
///      Rationale: `docs/decisions/0002-aave-safety-module-multi-token.md`.
contract AaveV3SafetyModuleAdapterFactory is BalanceAdapterFactoryBase {
    constructor(address registry, address navCalculator, address initialOwner)
        BalanceAdapterFactoryBase(keccak256("AaveV3SafetyModule"), registry, navCalculator, initialOwner)
    {}

    /// @notice Deploys (or reuses, if already at the predicted address) the multi-token Safety Module
    ///         adapter, tracks it on this factory, and registers it with the central registry.
    /// @param initial Initial set of stake tokens to register at construction. May be empty.
    /// @param admin Owner of the deployed adapter (manages the stake-token list).
    /// @param protocol Protocol identifier emitted on every PositionBalance (e.g. "Aave V3 Safety Module").
    /// @param salt CREATE2 salt; address depends on (initCode, salt).
    /// @return adapter The deployed adapter address.
    function deploy(
        AaveV3SafetyModuleBalanceOracle.StakeTokenInit[] calldata initial,
        address admin,
        string calldata protocol,
        bytes32 salt
    ) external onlyOwner returns (address adapter) {
        bytes memory initCode = abi.encodePacked(
            type(AaveV3SafetyModuleBalanceOracle).creationCode,
            abi.encode(initial, admin, NAV_CALCULATOR, protocol)
        );
        adapter = _deployCreate2(salt, initCode);
        _track(adapter, true);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterDeployed(adapter, salt);
    }

    /// @notice Predicts the deployed adapter address for a given configuration.
    function predict(
        AaveV3SafetyModuleBalanceOracle.StakeTokenInit[] calldata initial,
        address admin,
        string calldata protocol,
        bytes32 salt
    ) external view returns (address) {
        bytes memory initCode = abi.encodePacked(
            type(AaveV3SafetyModuleBalanceOracle).creationCode,
            abi.encode(initial, admin, NAV_CALCULATOR, protocol)
        );
        return _predictCreate2(salt, keccak256(initCode));
    }
}
