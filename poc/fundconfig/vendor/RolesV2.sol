// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @notice Minimal Zodiac Roles v2 surface used by the FundConfig POC.
/// @dev Vendored from gnosisguild/zodiac-modifier-roles@f55d00de507428cd3841975e7d85310c900c7b09
///      (packages/evm/contracts/Types.sol, PermissionBuilder.sol, Roles.sol). Values match the mastercopy at
///      0x9646fDAD06d3e24444381f44362a3B0eB343D337. Roles v2 operator codes are sparse (Pass=0, Matches=5,
///      EqualTo=16, ...), so they are carried as `uint8` constants in {Op}; the ABI encoding is identical to the
///      upstream enum.

enum ParameterType {
    None,
    Static,
    Dynamic,
    Tuple,
    Array,
    Calldata,
    AbiEncoded
}

enum ExecutionOptions {
    None,
    Send,
    DelegateCall,
    Both
}

struct ConditionFlat {
    uint8 parent;
    ParameterType paramType;
    uint8 operator;
    bytes compValue;
}

/// @dev Roles v2 operator codes used by this POC.
library Op {
    uint8 internal constant PASS = 0;
    uint8 internal constant OR = 2;
    uint8 internal constant MATCHES = 5;
    uint8 internal constant EQUAL_TO_AVATAR = 15;
    uint8 internal constant EQUAL_TO = 16;
}

/// @notice Owner API and member entrypoint of a Roles v2 modifier clone.
interface IRolesV2 {
    function owner() external view returns (address);

    function setUp(bytes memory initParams) external;

    function assignRoles(address module, bytes32[] calldata roleKeys, bool[] calldata memberOf) external;

    function scopeTarget(bytes32 roleKey, address targetAddress) external;

    function revokeTarget(bytes32 roleKey, address targetAddress) external;

    function allowFunction(bytes32 roleKey, address targetAddress, bytes4 selector, ExecutionOptions options)
        external;

    function revokeFunction(bytes32 roleKey, address targetAddress, bytes4 selector) external;

    function scopeFunction(
        bytes32 roleKey,
        address targetAddress,
        bytes4 selector,
        ConditionFlat[] memory conditions,
        ExecutionOptions options
    ) external;

    function execTransactionWithRole(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        bytes32 roleKey,
        bool shouldRevert
    ) external returns (bool success);
}

/// @notice Zodiac ModuleProxyFactory (CREATE2 minimal proxies).
interface IModuleProxyFactory {
    function deployModule(address masterCopy, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}
