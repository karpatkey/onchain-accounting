// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ConditionFlat, ExecutionOptions} from "poc/fundconfig/vendor/RolesV2.sol";

/// @notice One Roles v2 permission contributed by a position: `(target, selector)` callable under `conditions`.
struct PermissionLeaf {
    address target;
    bytes4 selector;
    ConditionFlat[] conditions;
    ExecutionOptions options;
}

/// @notice How a declared position is valued through the repo's balance adapters.
/// @dev `isMeta` selects `getAdapterPositionsForInstances(account, [coordinate], assetFilter)` on a meta adapter;
///      otherwise `getAdapterPositions(account, assetFilter)` on a plain adapter (`coordinate` unused).
struct Accounting {
    address adapter;
    bool isMeta;
    bytes32 coordinate;
    address assetFilter;
}

/// @notice A protocol module: maps one declared fund position to Roles permissions, valuation and wallet assets.
/// @dev Modules are stateless and immutable. Each `instance` is a bytes32 coordinate interpreted by the module.
interface IPositionModule {
    /// @notice Stable identifier used to register and declare the module.
    function moduleId() external view returns (bytes32);

    /// @notice Reverts unless `instance` is a valid coordinate for this module.
    function validate(bytes32 instance) external view;

    /// @notice Every Roles permission the position needs, expressed as `(target, selector, conditions, options)`.
    function permissions(bytes32 instance) external view returns (PermissionLeaf[] memory);

    /// @notice Valuation route for the position through the balance adapters.
    function accounting(bytes32 instance) external view returns (Accounting memory);

    /// @notice Underlying tokens the position can hold, counted as wallet balances of the fund Safe.
    function assets(bytes32 instance) external view returns (address[] memory);
}
