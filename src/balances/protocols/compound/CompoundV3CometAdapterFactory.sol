// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";
import {CompoundV3Comet} from "src/balances/protocols/compound/CompoundV3Comet.sol";

/// @title CompoundV3CometAdapterFactory
/// @author kpk
/// @notice Deploys & registers `CompoundV3Comet` adapter instances (one per Comet market).
contract CompoundV3CometAdapterFactory is BalanceAdapterFactoryBase {
    constructor(address registry, address navCalculator, address initialOwner)
        BalanceAdapterFactoryBase(keccak256("CompoundV3Comet"), registry, navCalculator, initialOwner)
    {}

    function deploy(address compoundRewards, address comet, address rewardToken, string calldata protocol, bytes32 salt)
        external
        onlyOwner
        returns (address adapter)
    {
        bytes memory initCode = abi.encodePacked(
            type(CompoundV3Comet).creationCode,
            abi.encode(compoundRewards, comet, rewardToken, protocol, NAV_CALCULATOR)
        );
        adapter = _deployCreate2(salt, initCode);
        _track(adapter, true);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterDeployed(adapter, salt);
    }

    function predict(
        address compoundRewards,
        address comet,
        address rewardToken,
        string calldata protocol,
        bytes32 salt
    ) external view returns (address) {
        bytes memory initCode = abi.encodePacked(
            type(CompoundV3Comet).creationCode,
            abi.encode(compoundRewards, comet, rewardToken, protocol, NAV_CALCULATOR)
        );
        return _predictCreate2(salt, keccak256(initCode));
    }
}
