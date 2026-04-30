// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";
import {StakeWiseV3VaultBalanceOracle} from "src/balances/protocols/stakewise/StakeWiseV3Vault.sol";

/// @title StakeWiseV3VaultAdapterFactory
/// @author kpk
/// @notice Deploys & registers `StakeWiseV3VaultBalanceOracle` instances (one per StakeWise vault).
contract StakeWiseV3VaultAdapterFactory is BalanceAdapterFactoryBase {
    constructor(address registry, address navCalculator, address initialOwner)
        BalanceAdapterFactoryBase(keccak256("StakeWiseV3Vault"), registry, navCalculator, initialOwner)
    {}

    function deploy(
        address underlyingToken,
        address vault,
        string calldata protocol,
        string calldata positionDetail,
        bytes32 salt
    ) external onlyOwner returns (address adapter) {
        bytes memory initCode = abi.encodePacked(
            type(StakeWiseV3VaultBalanceOracle).creationCode,
            abi.encode(underlyingToken, vault, protocol, positionDetail, NAV_CALCULATOR)
        );
        adapter = _deployCreate2(salt, initCode);
        _track(adapter, true);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterDeployed(adapter, salt);
    }

    function predict(
        address underlyingToken,
        address vault,
        string calldata protocol,
        string calldata positionDetail,
        bytes32 salt
    ) external view returns (address) {
        bytes memory initCode = abi.encodePacked(
            type(StakeWiseV3VaultBalanceOracle).creationCode,
            abi.encode(underlyingToken, vault, protocol, positionDetail, NAV_CALCULATOR)
        );
        return _predictCreate2(salt, keccak256(initCode));
    }
}
