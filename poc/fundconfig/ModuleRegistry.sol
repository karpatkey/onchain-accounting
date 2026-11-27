// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IPositionModule} from "poc/fundconfig/IPositionModule.sol";

/// @notice Owner-curated set of position modules. A module id can be registered once and is never replaced.
contract ModuleRegistry {
    error NotOwner();
    error ModuleAlreadyRegistered(bytes32 moduleId);
    error UnknownModule(bytes32 moduleId);

    /// @notice Emitted when a module is registered.
    event ModuleRegistered(bytes32 indexed moduleId, address module);

    /// @notice Registry owner allowed to register modules.
    address public immutable owner;

    mapping(bytes32 => IPositionModule) private _modules;

    constructor(address owner_) {
        owner = owner_;
    }

    /// @notice Registers `module` under its own `moduleId()`.
    function register(IPositionModule module) external {
        if (msg.sender != owner) revert NotOwner();
        bytes32 id = module.moduleId();
        if (address(_modules[id]) != address(0)) revert ModuleAlreadyRegistered(id);
        _modules[id] = module;
        emit ModuleRegistered(id, address(module));
    }

    /// @notice Returns the module registered under `moduleId`, reverting if none is.
    function moduleOf(bytes32 moduleId) external view returns (IPositionModule module) {
        module = _modules[moduleId];
        if (address(module) == address(0)) revert UnknownModule(moduleId);
    }
}
