// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";
import {ConvexBalanceOracle} from "src/balances/protocols/convex/Convex.sol";

/// @title ConvexAdapterFactory
/// @author kpk
/// @notice Deploys & registers `ConvexBalanceOracle` instances (one per Curve-pool wrapper on Convex).
contract ConvexAdapterFactory is BalanceAdapterFactoryBase {
    constructor(address registry, address navCalculator, address initialOwner)
        BalanceAdapterFactoryBase(keccak256("Convex"), registry, navCalculator, initialOwner)
    {}

    function deploy(
        address convexRewards,
        address lpToken,
        string calldata protocol,
        string calldata positionDetail,
        bytes32 salt
    ) external onlyOwner returns (address adapter) {
        bytes memory initCode = abi.encodePacked(
            type(ConvexBalanceOracle).creationCode,
            abi.encode(convexRewards, lpToken, protocol, positionDetail, NAV_CALCULATOR)
        );
        adapter = _deployCreate2(salt, initCode);
        _track(adapter, true);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterDeployed(adapter, salt);
    }

    function predict(
        address convexRewards,
        address lpToken,
        string calldata protocol,
        string calldata positionDetail,
        bytes32 salt
    ) external view returns (address) {
        bytes memory initCode = abi.encodePacked(
            type(ConvexBalanceOracle).creationCode,
            abi.encode(convexRewards, lpToken, protocol, positionDetail, NAV_CALCULATOR)
        );
        return _predictCreate2(salt, keccak256(initCode));
    }
}
