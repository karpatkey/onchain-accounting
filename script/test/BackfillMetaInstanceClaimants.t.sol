// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {BackfillMetaInstanceClaimants} from "script/manage/BackfillMetaInstanceClaimants.s.sol";

/// @title BackfillMetaInstanceClaimants — recovery-set truth table
/// @author KPK
/// @notice Pins `missingFrom`, the predicate the whole recovery path turns on.
/// @dev This file exists because the hardening plan's S3 ("extract script predicates; pure functions with
///      truth-table tests") landed only its `vm.readCallers()` half, and the un-tested half then shipped two
///      defects that an audit found rather than CI:
///
///        1. `lost` was computed as `want.length - have.length`. A set refilled with DIFFERENT coordinates —
///           snapshot `[c1,c2,c3]` against an on-chain `[c4,c5,c6]` — reported ZERO lost, so the script deleted
///           its own recovery snapshot and reported "every governed coordinate is claimed" while c1..c3 were
///           gone from NAV for good.
///        2. The restore array was SIZED `want.length - have.length`, which equals `|want \ have|` only when
///           `have` is a subset of `want`. Otherwise the fill ran past the end and panicked `0x32`, with no
///           named error and no way to recover short of hand-editing the snapshot.
///
///      Both are cardinality-vs-membership confusions, and both are cases in the table below. The equal-length
///      and superset rows are the ones that were actually broken; the rest bound the predicate around them.
contract BackfillMissingFromTest is Test {
    BackfillMetaInstanceClaimants internal s;

    bytes32 internal constant C1 = bytes32(uint256(1));
    bytes32 internal constant C2 = bytes32(uint256(2));
    bytes32 internal constant C3 = bytes32(uint256(3));
    bytes32 internal constant C4 = bytes32(uint256(4));

    function setUp() public {
        s = new BackfillMetaInstanceClaimants();
    }

    function _a(bytes32 x) internal pure returns (bytes32[] memory o) {
        o = new bytes32[](1);
        o[0] = x;
    }

    function _a(bytes32 x, bytes32 y) internal pure returns (bytes32[] memory o) {
        o = new bytes32[](2);
        o[0] = x;
        o[1] = y;
    }

    function _a(bytes32 x, bytes32 y, bytes32 z) internal pure returns (bytes32[] memory o) {
        o = new bytes32[](3);
        o[0] = x;
        o[1] = y;
        o[2] = z;
    }

    function _a(bytes32 w, bytes32 x, bytes32 y, bytes32 z) internal pure returns (bytes32[] memory o) {
        o = new bytes32[](4);
        o[0] = w;
        o[1] = x;
        o[2] = y;
        o[3] = z;
    }

    function _empty() internal pure returns (bytes32[] memory o) {
        o = new bytes32[](0);
    }

    /// @notice Nothing lost when the chain still holds everything the snapshot recorded.
    function test_identicalSets_nothingMissing() public view {
        assertEq(s.missingFrom(_a(C1, C2, C3), _a(C1, C2, C3)).length, 0);
    }

    /// @notice Order is irrelevant — the on-chain set is swap-and-pop ordered, so it will not match.
    function test_reorderedSet_nothingMissing() public view {
        assertEq(s.missingFrom(_a(C1, C2, C3), _a(C3, C1, C2)).length, 0);
    }

    /// @notice Total loss: the removal landed and the re-add did not.
    function test_totalLoss_allMissing() public view {
        bytes32[] memory m = s.missingFrom(_a(C1, C2, C3), _empty());
        assertEq(m.length, 3);
        assertEq(m[0], C1);
        assertEq(m[2], C3);
    }

    /// @notice DEFECT 1: equal lengths, different members. A cardinality check reported zero.
    /// @dev The dangerous case, because zero lost also meant zero pending, which made the caller delete the
    ///      recovery snapshot and report success.
    function test_equalLengthsDifferentMembers_allMissing() public view {
        bytes32[] memory m = s.missingFrom(_a(C1, C2, C3), _a(C4, C4, C4));
        assertEq(m.length, 3, "a refilled set of the same size is total loss, not zero loss");
    }

    /// @notice DEFECT 2: `have` carries a member `want` does not. Sizing by difference panicked here.
    function test_haveNotASubsetOfWant_doesNotOverrun() public view {
        bytes32[] memory m = s.missingFrom(_a(C1, C2, C3), _a(C1, C4));
        assertEq(m.length, 2, "|want \\ have| is 2 even though the lengths differ by 1");
        assertEq(m[0], C2);
        assertEq(m[1], C3);
    }

    /// @notice A superset on chain loses nothing — an operator legitimately added coordinates after the snapshot.
    function test_haveSupersetOfWant_nothingMissing() public view {
        assertEq(s.missingFrom(_a(C1, C2), _a(C1, C2, C3, C4)).length, 0);
    }

    /// @notice Empty snapshot: nothing to restore, whatever is on chain.
    function test_emptyWant_nothingMissing() public view {
        assertEq(s.missingFrom(_empty(), _a(C1, C2)).length, 0);
        assertEq(s.missingFrom(_empty(), _empty()).length, 0);
    }

    /// @notice A duplicated snapshot entry is reported once per occurrence, not collapsed.
    /// @dev Not a case the script can produce — `_claim` rejects a within-adapter duplicate — but pinned so the
    ///      predicate's behaviour is defined rather than incidental if that ever changes.
    function test_duplicatedWantEntry_reportedPerOccurrence() public view {
        assertEq(s.missingFrom(_a(C1, C1), _empty()).length, 2);
    }
}
