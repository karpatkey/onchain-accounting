// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";
import {AaveV3InstanceBalanceOracle} from "src/balances/protocols/aave/AaveV3Instance.sol";

/// @title AaveV3InstanceAdapterFactory
/// @author kpk
/// @notice Deploys & registers `AaveV3InstanceBalanceOracle` instances (one per Aave V3 market —
///         e.g. Mainnet has Core, Prime, Lido, EtherFi, Horizon variants).
contract AaveV3InstanceAdapterFactory is BalanceAdapterFactoryBase {
    constructor(address registry, address navCalculator, address initialOwner)
        BalanceAdapterFactoryBase(keccak256("AaveV3Instance"), registry, navCalculator, initialOwner)
    {}

    function deploy(address dataProvider, string calldata protocol, bytes32 salt)
        external
        onlyOwner
        returns (address adapter)
    {
        bytes memory initCode = abi.encodePacked(
            type(AaveV3InstanceBalanceOracle).creationCode, abi.encode(dataProvider, protocol, NAV_CALCULATOR)
        );
        adapter = _deployCreate2(salt, initCode);
        _track(adapter, true);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterDeployed(adapter, salt);
    }

    function predict(address dataProvider, string calldata protocol, bytes32 salt) external view returns (address) {
        bytes memory initCode = abi.encodePacked(
            type(AaveV3InstanceBalanceOracle).creationCode, abi.encode(dataProvider, protocol, NAV_CALCULATOR)
        );
        return _predictCreate2(salt, keccak256(initCode));
    }
}
