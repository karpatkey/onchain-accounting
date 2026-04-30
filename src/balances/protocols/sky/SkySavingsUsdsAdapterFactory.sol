// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";
import {SkySavingsUsdsBalanceOracle} from "src/balances/protocols/sky/SkySavingsUsds.sol";

/// @title SkySavingsUsdsAdapterFactory
/// @author kpk
/// @notice Deploys & registers `SkySavingsUsdsBalanceOracle` instances (one per chain today).
contract SkySavingsUsdsAdapterFactory is BalanceAdapterFactoryBase {
    constructor(address registry, address navCalculator, address initialOwner)
        BalanceAdapterFactoryBase(keccak256("SkySavingsUsds"), registry, navCalculator, initialOwner)
    {}

    function deploy(address savingsUsds, string calldata protocol, string calldata positionDetail, bytes32 salt)
        external
        onlyOwner
        returns (address adapter)
    {
        bytes memory initCode = abi.encodePacked(
            type(SkySavingsUsdsBalanceOracle).creationCode,
            abi.encode(savingsUsds, protocol, positionDetail, NAV_CALCULATOR)
        );
        adapter = _deployCreate2(salt, initCode);
        _track(adapter, true);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterDeployed(adapter, salt);
    }

    function predict(address savingsUsds, string calldata protocol, string calldata positionDetail, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes memory initCode = abi.encodePacked(
            type(SkySavingsUsdsBalanceOracle).creationCode,
            abi.encode(savingsUsds, protocol, positionDetail, NAV_CALCULATOR)
        );
        return _predictCreate2(salt, keccak256(initCode));
    }
}
