// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";
import {MorphoMarketBalanceOracle} from "src/balances/protocols/morpho/MorphoMarket.sol";

/// @title MorphoMarketAdapterFactory
/// @author kpk
/// @notice Deploys & registers `MorphoMarketBalanceOracle` instances (one per Morpho Blue market).
contract MorphoMarketAdapterFactory is BalanceAdapterFactoryBase {
    constructor(address registry, address navCalculator, address initialOwner)
        BalanceAdapterFactoryBase(keccak256("MorphoMarket"), registry, navCalculator, initialOwner)
    {}

    function deploy(address morpho, bytes32 marketId, string calldata protocol, bytes32 salt)
        external
        onlyOwner
        returns (address adapter)
    {
        bytes memory initCode = abi.encodePacked(
            type(MorphoMarketBalanceOracle).creationCode, abi.encode(morpho, marketId, protocol, NAV_CALCULATOR)
        );
        adapter = _deployCreate2(salt, initCode);
        _track(adapter, true);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterDeployed(adapter, salt);
    }

    function predict(address morpho, bytes32 marketId, string calldata protocol, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes memory initCode = abi.encodePacked(
            type(MorphoMarketBalanceOracle).creationCode, abi.encode(morpho, marketId, protocol, NAV_CALCULATOR)
        );
        return _predictCreate2(salt, keccak256(initCode));
    }
}
