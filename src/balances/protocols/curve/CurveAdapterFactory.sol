// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";
import {CurveBalanceOracle} from "src/balances/protocols/curve/Curve.sol";

/// @title CurveAdapterFactory
/// @author kpk
/// @notice Deploys & registers `CurveBalanceOracle` instances (one per Curve gauge).
contract CurveAdapterFactory is BalanceAdapterFactoryBase {
    constructor(address registry, address navCalculator, address initialOwner)
        BalanceAdapterFactoryBase(keccak256("Curve"), registry, navCalculator, initialOwner)
    {}

    function deploy(address gauge, string calldata protocol, string calldata positionDetail, bytes32 salt)
        external
        onlyOwner
        returns (address adapter)
    {
        bytes memory initCode = abi.encodePacked(
            type(CurveBalanceOracle).creationCode, abi.encode(gauge, protocol, positionDetail, NAV_CALCULATOR)
        );
        adapter = _deployCreate2(salt, initCode);
        _track(adapter, true);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterDeployed(adapter, salt);
    }

    function predict(address gauge, string calldata protocol, string calldata positionDetail, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes memory initCode = abi.encodePacked(
            type(CurveBalanceOracle).creationCode, abi.encode(gauge, protocol, positionDetail, NAV_CALCULATOR)
        );
        return _predictCreate2(salt, keccak256(initCode));
    }
}
