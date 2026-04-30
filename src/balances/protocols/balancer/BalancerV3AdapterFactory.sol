// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";
import {BalancerV3PoolBalanceOracle} from "src/balances/protocols/balancer/BalancerV3.sol";

/// @title BalancerV3AdapterFactory
/// @author kpk
/// @notice Deploys & registers `BalancerV3PoolBalanceOracle` instances.
/// @dev One adapter instance per Balancer V3 pool / gauge pair. CREATE2 instance addresses are
///      cross-chain identical for matching (caller, salt, initCode) tuples.
contract BalancerV3AdapterFactory is BalanceAdapterFactoryBase {
    constructor(address registry, address navCalculator, address initialOwner)
        BalanceAdapterFactoryBase(keccak256("BalancerV3"), registry, navCalculator, initialOwner)
    {}

    function deploy(address pool, address gauge, address balancerMinter, string calldata protocol, bytes32 salt)
        external
        onlyOwner
        returns (address adapter)
    {
        bytes memory initCode = abi.encodePacked(
            type(BalancerV3PoolBalanceOracle).creationCode,
            abi.encode(pool, gauge, balancerMinter, protocol, NAV_CALCULATOR)
        );
        adapter = _deployCreate2(salt, initCode);
        _track(adapter, true);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterDeployed(adapter, salt);
    }

    function predict(address pool, address gauge, address balancerMinter, string calldata protocol, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes memory initCode = abi.encodePacked(
            type(BalancerV3PoolBalanceOracle).creationCode,
            abi.encode(pool, gauge, balancerMinter, protocol, NAV_CALCULATOR)
        );
        return _predictCreate2(salt, keccak256(initCode));
    }
}
