// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";
import {StakeWiseV3OsTokenBalanceOracle} from "src/balances/protocols/stakewise/StakeWiseV3OsToken.sol";

/// @title StakeWiseV3OsTokenAdapterFactory
/// @author kpk
/// @notice Deploys & registers `StakeWiseV3OsTokenBalanceOracle` instances (one per osToken/underlying pair).
contract StakeWiseV3OsTokenAdapterFactory is BalanceAdapterFactoryBase {
    constructor(address registry, address navCalculator, address initialOwner)
        BalanceAdapterFactoryBase(keccak256("StakeWiseV3OsToken"), registry, navCalculator, initialOwner)
    {}

    function deploy(
        address osToken,
        address underlyingToken,
        address osTokenVaultController,
        string calldata protocol,
        string calldata positionDetail,
        bytes32 salt
    ) external onlyOwner returns (address adapter) {
        bytes memory initCode = abi.encodePacked(
            type(StakeWiseV3OsTokenBalanceOracle).creationCode,
            abi.encode(osToken, underlyingToken, osTokenVaultController, protocol, positionDetail, NAV_CALCULATOR)
        );
        adapter = _deployCreate2(salt, initCode);
        _track(adapter, true);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterDeployed(adapter, salt);
    }

    function predict(
        address osToken,
        address underlyingToken,
        address osTokenVaultController,
        string calldata protocol,
        string calldata positionDetail,
        bytes32 salt
    ) external view returns (address) {
        bytes memory initCode = abi.encodePacked(
            type(StakeWiseV3OsTokenBalanceOracle).creationCode,
            abi.encode(osToken, underlyingToken, osTokenVaultController, protocol, positionDetail, NAV_CALCULATOR)
        );
        return _predictCreate2(salt, keccak256(initCode));
    }
}
