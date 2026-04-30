// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";
import {CapBalanceOracle} from "src/balances/protocols/cap/Cap.sol";

/// @title CapAdapterFactory
/// @author kpk
/// @notice Deploys & registers `CapBalanceOracle` instances (one per chain today).
contract CapAdapterFactory is BalanceAdapterFactoryBase {
    constructor(address registry, address navCalculator, address initialOwner)
        BalanceAdapterFactoryBase(keccak256("Cap"), registry, navCalculator, initialOwner)
    {}

    function deploy(
        address cUsd,
        address stcUsd,
        address usdc,
        string calldata protocol,
        string calldata positionDetail,
        bytes32 salt
    ) external onlyOwner returns (address adapter) {
        bytes memory initCode = abi.encodePacked(
            type(CapBalanceOracle).creationCode,
            abi.encode(cUsd, stcUsd, usdc, protocol, positionDetail, NAV_CALCULATOR)
        );
        adapter = _deployCreate2(salt, initCode);
        _track(adapter, true);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterDeployed(adapter, salt);
    }

    function predict(
        address cUsd,
        address stcUsd,
        address usdc,
        string calldata protocol,
        string calldata positionDetail,
        bytes32 salt
    ) external view returns (address) {
        bytes memory initCode = abi.encodePacked(
            type(CapBalanceOracle).creationCode,
            abi.encode(cUsd, stcUsd, usdc, protocol, positionDetail, NAV_CALCULATOR)
        );
        return _predictCreate2(salt, keccak256(initCode));
    }
}
