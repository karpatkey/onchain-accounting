// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {SafeOverrides, ISafeMinimal} from "test/utils/SafeOverrides.sol";

/// @notice Zodiac Roles v2 modifier — the minimal surface these fork tests use.
/// @dev `ExecutionOptions` mirrors Zodiac `Core.ExecutionOptions` (None/Send/DelegateCall/Both); `Operation` mirrors
///      the Safe `Enum.Operation` (Call/DelegateCall). Role keys are `bytes32`.
interface IRolesMod {
    enum ExecutionOptions {
        None,
        Send,
        DelegateCall,
        Both
    }

    enum Operation {
        Call,
        DelegateCall
    }

    /// @notice Whitelist an entire target for `roleKey` with the given execution options (owner-only).
    function allowTarget(bytes32 roleKey, address targetAddress, ExecutionOptions options) external;
    /// @notice Grant/revoke `roleKeys` membership for `module` (owner-only).
    function assignRoles(address module, bytes32[] calldata roleKeys, bool[] calldata memberOf) external;
    /// @notice Execute `to`/`value`/`data`/`operation` on the avatar under `roleKey`; caller must be a role member.
    function execTransactionWithRole(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation,
        bytes32 roleKey,
        bool shouldRevert
    ) external returns (bool success);
}

/// @title AssistantSafeRolesForkBase
/// @author KPK
/// @notice Shared fork harness that exercises an assisted-adapter **assistant** through the real karpatkey ops stack:
///         a production **avatar Safe** with a **Zodiac Roles modifier** enabled, and a **manager Safe** that holds a
///         role. It reproduces the intended production flow end-to-end:
///           1. the funds (eETH / NXM / vault shares) sit in the **avatar Safe**;
///           2. the Roles modifier grants a role permission to **DELEGATECALL** a whitelisted assistant;
///           3. the **manager Safe** (a member of that role) calls `execTransactionWithRole`;
///           4. the Roles modifier makes the **avatar Safe delegatecall the assistant** — so the assistant runs in the
///              avatar's context (`address(this) == avatar`), the protocol sees `msg.sender = avatar`, and the
///              permissionless adapter records the resulting position against the avatar.
/// @dev Forks mainnet against the LIVE karpatkey stack (no Safe/Zodiac deployment or dependency needed): the Roles
///      modifier's owner is the avatar Safe, so the harness pranks the avatar to `allowTarget` a freshly-deployed
///      assistant and `assignRoles` the manager Safe. The manager Safe is storage-patched to a single owner
///      (via {SafeOverrides}) so the test can sign its `execTransaction`. Concrete tests set the fork block, deploy the
///      adapter + assistant, fund the avatar, then call {_managerDelegatecall}.
abstract contract AssistantSafeRolesForkBase is BalanceAdapterTestBase, SafeOverrides {
    /// @notice karpatkey production avatar Safe (holds the funds; is the Roles modifier's owner/avatar/target).
    address internal constant AVATAR_SAFE = 0xdE53bCdA6527D2aa15Ec733352C8d393C2E0eC99;
    /// @notice karpatkey production manager Safe (assigned the test role; signs `execTransactionWithRole`).
    address internal constant MANAGER_SAFE = 0x9953f65e00cE71D7aA5A3f7889f63FEE0f1BA63c;
    /// @notice karpatkey production Zodiac Roles modifier enabled on the avatar Safe.
    address internal constant ROLES_MODIFIER = 0xCEE06943E829367ff1Bd6B4670cb4a1148636d26;

    /// @notice A fresh, test-only role key (distinct from any live role) scoped to exactly the assistant under test.
    bytes32 internal constant TEST_ROLE = bytes32("ASSISTANT_FORK_TEST");

    /// @notice ERC-7528 native-ETH sentinel (the underlying for the ether.fi / StakeWise ETH-settled queues).
    address internal constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice The single patched owner of the manager Safe used to sign `execTransaction`.
    address internal managerOwner;

    /// @dev A fresh Balances harness with the native-ETH sentinel registered — used as the adapter's NAVCalculator.
    ///      `_deployBalancesForAdapter` can't be used here: it reads `decimals()` on the asset, which reverts on the
    ///      non-contract native sentinel.
    function _balancesForNativeEth() internal returns (BalancesHarnessForFork b) {
        b = new BalancesHarnessForFork();
        b.registerAssetForTest(NATIVE_ETH, 18, "ETH");
    }

    /// @dev Patch the manager Safe to a single owner we can sign for. Call once in a concrete test's `setUp`.
    function _initManagerSafe() internal {
        managerOwner = makeAddr("managerSafeOwner");
        patchThresholdAndMakeSingleOwner(MANAGER_SAFE, managerOwner);
    }

    /// @dev Whitelist `assistant` for {TEST_ROLE} with DELEGATECALL permitted, and make the manager Safe a member —
    ///      done by pranking the Roles modifier owner (the avatar Safe). Exactly the production admin path.
    function _permitDelegatecall(address assistant) internal {
        bytes32[] memory roleKeys = new bytes32[](1);
        roleKeys[0] = TEST_ROLE;
        bool[] memory memberOf = new bool[](1);
        memberOf[0] = true;

        vm.startPrank(AVATAR_SAFE); // the Roles modifier's owner
        IRolesMod(ROLES_MODIFIER).allowTarget(TEST_ROLE, assistant, IRolesMod.ExecutionOptions.DelegateCall);
        IRolesMod(ROLES_MODIFIER).assignRoles(MANAGER_SAFE, roleKeys, memberOf);
        vm.stopPrank();
    }

    /// @dev Full ops path: the manager Safe (single-owner) `execTransaction`s a plain `Call` to the Roles modifier's
    ///      `execTransactionWithRole`, which in turn makes the avatar Safe **DELEGATECALL** `assistant` with `data`.
    function _managerDelegatecall(address assistant, bytes memory data) internal {
        bytes memory rolesCall = abi.encodeCall(
            IRolesMod.execTransactionWithRole, (assistant, 0, data, IRolesMod.Operation.DelegateCall, TEST_ROLE, true)
        );
        vm.prank(managerOwner);
        ISafeMinimal(MANAGER_SAFE)
            .execTransaction(
                ROLES_MODIFIER,
                0,
                rolesCall,
                ISafeMinimal.Operation.Call,
                0,
                0,
                0,
                address(0),
                payable(address(0)),
                buildPrevalidatedSignature(managerOwner)
            );
    }
}
