// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {DeployTimelockController} from "script/deploy/11_DeployTimelockController.s.sol";
import {SafeTxBuilder} from "script/utils/SafeTxBuilder.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MANAGER, DEFAULT_ADMIN_ROLE} from "src/constants.sol";

/// @dev Pins the ordered role-handover batch `11_DeployTimelockController.buildHandoffBatch` emits — the batch that
///      revokes every direct NAV admin/manager. Pure builder, so no live NAV/env/fork is needed (Copilot).
contract DeployTimelockControllerBatchTest is Test {
    DeployTimelockController internal s;

    address internal constant NAV = address(0xA7);
    address internal constant TL = address(0x7111); // predicted timelock
    address internal constant DEP = address(0xDE9); // deployer EOA
    address internal constant SAFE = address(0x5AFE); // council Safe
    address internal constant OPS = address(0x0C5); // throwaway ops Safe

    function setUp() public {
        s = new DeployTimelockController();
    }

    function _grant(bytes32 role, address who) internal pure returns (bytes memory) {
        return abi.encodeCall(IAccessControl.grantRole, (role, who));
    }

    function _revoke(bytes32 role, address who) internal pure returns (bytes memory) {
        return abi.encodeCall(IAccessControl.revokeRole, (role, who));
    }

    function _assertEntry(SafeTxBuilder.Transaction memory t, bytes memory expected) internal {
        assertEq(t.to, NAV, "to");
        assertEq(t.value, 0, "value");
        assertEq(uint256(t.operation), 0, "operation must be Call, never DelegateCall");
        assertEq(t.data, expected, "calldata");
    }

    /// @dev Grants (timelock) then deployer revokes are entries 0-3 in EVERY combo.
    function _assertBase(SafeTxBuilder.Transaction[] memory b) internal {
        _assertEntry(b[0], _grant(DEFAULT_ADMIN_ROLE, TL));
        _assertEntry(b[1], _grant(MANAGER, TL));
        _assertEntry(b[2], _revoke(MANAGER, DEP));
        _assertEntry(b[3], _revoke(DEFAULT_ADMIN_ROLE, DEP));
    }

    function test_safeRetains_noOps() public {
        SafeTxBuilder.Transaction[] memory b = s.buildHandoffBatch(NAV, TL, DEP, SAFE, address(0), true, false, false);
        assertEq(b.length, 4);
        _assertBase(b);
    }

    function test_safeRetains_opsBoth() public {
        SafeTxBuilder.Transaction[] memory b = s.buildHandoffBatch(NAV, TL, DEP, SAFE, OPS, true, true, true);
        assertEq(b.length, 6);
        _assertBase(b);
        _assertEntry(b[4], _revoke(MANAGER, OPS));
        _assertEntry(b[5], _revoke(DEFAULT_ADMIN_ROLE, OPS));
    }

    function test_safeRevoked_noOps() public {
        SafeTxBuilder.Transaction[] memory b = s.buildHandoffBatch(NAV, TL, DEP, SAFE, address(0), false, false, false);
        assertEq(b.length, 6);
        _assertBase(b);
        _assertEntry(b[4], _revoke(MANAGER, SAFE));
        _assertEntry(b[5], _revoke(DEFAULT_ADMIN_ROLE, SAFE));
    }

    /// @dev The load-bearing invariant: ops-Safe revokes land STRICTLY BEFORE the Safe's own self-revoke, so an
    ///      account that still holds DEFAULT_ADMIN_ROLE authorizes them.
    function test_safeRevoked_opsBoth_opsBeforeSafe() public {
        SafeTxBuilder.Transaction[] memory b = s.buildHandoffBatch(NAV, TL, DEP, SAFE, OPS, false, true, true);
        assertEq(b.length, 8);
        _assertBase(b);
        _assertEntry(b[4], _revoke(MANAGER, OPS));
        _assertEntry(b[5], _revoke(DEFAULT_ADMIN_ROLE, OPS));
        _assertEntry(b[6], _revoke(MANAGER, SAFE));
        _assertEntry(b[7], _revoke(DEFAULT_ADMIN_ROLE, SAFE));
    }

    function test_opsManagerOnly() public {
        SafeTxBuilder.Transaction[] memory b = s.buildHandoffBatch(NAV, TL, DEP, SAFE, OPS, true, true, false);
        assertEq(b.length, 5);
        _assertBase(b);
        _assertEntry(b[4], _revoke(MANAGER, OPS));
    }

    function test_opsAdminOnly() public {
        SafeTxBuilder.Transaction[] memory b = s.buildHandoffBatch(NAV, TL, DEP, SAFE, OPS, true, false, true);
        assertEq(b.length, 5);
        _assertBase(b);
        _assertEntry(b[4], _revoke(DEFAULT_ADMIN_ROLE, OPS));
    }
}
