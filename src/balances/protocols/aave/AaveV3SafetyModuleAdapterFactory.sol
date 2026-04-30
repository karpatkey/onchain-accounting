// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";
import {AaveV3SafetyModuleBalanceOracle} from "src/balances/protocols/aave/AaveV3SafetyModule.sol";

/// @title AaveV3SafetyModuleAdapterFactory
/// @author kpk
/// @notice Deploys & registers `AaveV3SafetyModuleBalanceOracle` instances (one per stake token).
contract AaveV3SafetyModuleAdapterFactory is BalanceAdapterFactoryBase {
    constructor(address registry, address navCalculator, address initialOwner)
        BalanceAdapterFactoryBase(keccak256("AaveV3SafetyModule"), registry, navCalculator, initialOwner)
    {}

    function deploy(address stakeToken, string calldata protocol, string calldata positionDetail, bytes32 salt)
        external
        onlyOwner
        returns (address adapter)
    {
        bytes memory initCode = abi.encodePacked(
            type(AaveV3SafetyModuleBalanceOracle).creationCode,
            abi.encode(stakeToken, protocol, positionDetail, NAV_CALCULATOR)
        );
        adapter = _deployCreate2(salt, initCode);
        _track(adapter, true);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterDeployed(adapter, salt);
    }

    function predict(address stakeToken, string calldata protocol, string calldata positionDetail, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes memory initCode = abi.encodePacked(
            type(AaveV3SafetyModuleBalanceOracle).creationCode,
            abi.encode(stakeToken, protocol, positionDetail, NAV_CALCULATOR)
        );
        return _predictCreate2(salt, keccak256(initCode));
    }
}
