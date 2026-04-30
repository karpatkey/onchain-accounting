// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";
import {GearboxMarketBalanceOracle} from "src/balances/protocols/gearbox/GearboxMarket.sol";

/// @title GearboxMarketAdapterFactory
/// @author kpk
/// @notice Deploys & registers `GearboxMarketBalanceOracle` instances (one per Gearbox market).
contract GearboxMarketAdapterFactory is BalanceAdapterFactoryBase {
    constructor(address registry, address navCalculator, address initialOwner)
        BalanceAdapterFactoryBase(keccak256("GearboxMarket"), registry, navCalculator, initialOwner)
    {}

    function deploy(address market, string calldata protocol, string calldata positionDetail, bytes32 salt)
        external
        onlyOwner
        returns (address adapter)
    {
        bytes memory initCode = abi.encodePacked(
            type(GearboxMarketBalanceOracle).creationCode, abi.encode(market, protocol, positionDetail, NAV_CALCULATOR)
        );
        adapter = _deployCreate2(salt, initCode);
        _track(adapter, true);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterDeployed(adapter, salt);
    }

    function predict(address market, string calldata protocol, string calldata positionDetail, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes memory initCode = abi.encodePacked(
            type(GearboxMarketBalanceOracle).creationCode, abi.encode(market, protocol, positionDetail, NAV_CALCULATOR)
        );
        return _predictCreate2(salt, keccak256(initCode));
    }
}
