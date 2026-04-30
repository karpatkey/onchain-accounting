// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";
import {SparkLendBalanceOracle} from "src/balances/protocols/spark/SparkLend.sol";

/// @title SparkLendAdapterFactory
/// @author kpk
/// @notice Deploys & registers `SparkLendBalanceOracle` instances (one per chain today —
///         currently Mainnet + Gnosis).
contract SparkLendAdapterFactory is BalanceAdapterFactoryBase {
    constructor(address registry, address navCalculator, address initialOwner)
        BalanceAdapterFactoryBase(keccak256("SparkLend"), registry, navCalculator, initialOwner)
    {}

    function deploy(address dataProvider, string calldata protocol, bytes32 salt)
        external
        onlyOwner
        returns (address adapter)
    {
        bytes memory initCode = abi.encodePacked(
            type(SparkLendBalanceOracle).creationCode, abi.encode(dataProvider, protocol, NAV_CALCULATOR)
        );
        adapter = _deployCreate2(salt, initCode);
        _track(adapter, true);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterDeployed(adapter, salt);
    }

    function predict(address dataProvider, string calldata protocol, bytes32 salt) external view returns (address) {
        bytes memory initCode = abi.encodePacked(
            type(SparkLendBalanceOracle).creationCode, abi.encode(dataProvider, protocol, NAV_CALCULATOR)
        );
        return _predictCreate2(salt, keccak256(initCode));
    }
}
