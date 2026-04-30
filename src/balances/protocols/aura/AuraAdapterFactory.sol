// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";
import {Aura} from "src/balances/protocols/aura/Aura.sol";

/// @title AuraAdapterFactory
/// @author kpk
/// @notice Deploys & registers `Aura` adapter instances (one per Aura-wrapped Balancer pool).
contract AuraAdapterFactory is BalanceAdapterFactoryBase {
    constructor(address registry, address navCalculator, address initialOwner)
        BalanceAdapterFactoryBase(keccak256("Aura"), registry, navCalculator, initialOwner)
    {}

    function deploy(
        address pool,
        address gauge,
        address booster,
        uint256 pid,
        string calldata protocol,
        string calldata positionDetail,
        bytes32 salt
    ) external onlyOwner returns (address adapter) {
        bytes memory initCode = abi.encodePacked(
            type(Aura).creationCode, abi.encode(pool, gauge, booster, pid, protocol, positionDetail, NAV_CALCULATOR)
        );
        adapter = _deployCreate2(salt, initCode);
        _track(adapter, true);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterDeployed(adapter, salt);
    }

    function predict(
        address pool,
        address gauge,
        address booster,
        uint256 pid,
        string calldata protocol,
        string calldata positionDetail,
        bytes32 salt
    ) external view returns (address) {
        bytes memory initCode = abi.encodePacked(
            type(Aura).creationCode, abi.encode(pool, gauge, booster, pid, protocol, positionDetail, NAV_CALCULATOR)
        );
        return _predictCreate2(salt, keccak256(initCode));
    }
}
