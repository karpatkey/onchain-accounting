// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";
import {DaiDsrBalanceOracle} from "src/balances/protocols/maker/DaiDsr.sol";

/// @title DaiDsrAdapterFactory
/// @author kpk
/// @notice Deploys & registers `DaiDsrBalanceOracle` instances (one per DSR manager — Mainnet only today).
contract DaiDsrAdapterFactory is BalanceAdapterFactoryBase {
    constructor(address registry, address navCalculator, address initialOwner)
        BalanceAdapterFactoryBase(keccak256("DaiDsr"), registry, navCalculator, initialOwner)
    {}

    function deploy(
        address dai,
        address dsrManager,
        string calldata protocol,
        string calldata positionDetail,
        bytes32 salt
    ) external onlyOwner returns (address adapter) {
        bytes memory initCode = abi.encodePacked(
            type(DaiDsrBalanceOracle).creationCode,
            abi.encode(dai, dsrManager, protocol, positionDetail, NAV_CALCULATOR)
        );
        adapter = _deployCreate2(salt, initCode);
        _track(adapter, true);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterDeployed(adapter, salt);
    }

    function predict(
        address dai,
        address dsrManager,
        string calldata protocol,
        string calldata positionDetail,
        bytes32 salt
    ) external view returns (address) {
        bytes memory initCode = abi.encodePacked(
            type(DaiDsrBalanceOracle).creationCode,
            abi.encode(dai, dsrManager, protocol, positionDetail, NAV_CALCULATOR)
        );
        return _predictCreate2(salt, keccak256(initCode));
    }
}
