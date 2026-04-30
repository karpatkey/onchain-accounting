// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";
import {MorphoVaultBalanceOracle} from "src/balances/protocols/morpho/MorphoVault.sol";

/// @title MorphoVaultAdapterFactory
/// @author kpk
/// @notice Deploys & registers `MorphoVaultBalanceOracle` instances (one per ERC4626 Morpho vault).
contract MorphoVaultAdapterFactory is BalanceAdapterFactoryBase {
    constructor(address registry, address navCalculator, address initialOwner)
        BalanceAdapterFactoryBase(keccak256("MorphoVault"), registry, navCalculator, initialOwner)
    {}

    function deploy(address vault, string calldata protocol, string calldata positionDetail, bytes32 salt)
        external
        onlyOwner
        returns (address adapter)
    {
        bytes memory initCode = abi.encodePacked(
            type(MorphoVaultBalanceOracle).creationCode, abi.encode(vault, protocol, positionDetail, NAV_CALCULATOR)
        );
        adapter = _deployCreate2(salt, initCode);
        _track(adapter, true);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterDeployed(adapter, salt);
    }

    function predict(address vault, string calldata protocol, string calldata positionDetail, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes memory initCode = abi.encodePacked(
            type(MorphoVaultBalanceOracle).creationCode, abi.encode(vault, protocol, positionDetail, NAV_CALCULATOR)
        );
        return _predictCreate2(salt, keccak256(initCode));
    }
}
