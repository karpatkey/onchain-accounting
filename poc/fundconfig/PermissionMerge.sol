// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ConditionFlat, ParameterType, Op} from "poc/fundconfig/vendor/RolesV2.sol";

/// @notice Builders for Roles v2 condition trees.
/// @dev A condition tree is a flat, BFS-ordered array with the root at index 0 (`parent == 0`). Every helper here
///      emits trees that satisfy Roles v2 `Integrity.enforce`.
library Cond {
    /// @notice Pass-through argument: any value.
    function pass() internal pure returns (ConditionFlat memory) {
        return ConditionFlat(0, ParameterType.Static, Op.PASS, "");
    }

    /// @notice Argument must equal the given address.
    function equalTo(address a) internal pure returns (ConditionFlat memory) {
        return ConditionFlat(0, ParameterType.Static, Op.EQUAL_TO, abi.encode(a));
    }

    /// @notice Argument must equal the fund Safe (the Roles avatar).
    function equalToAvatar() internal pure returns (ConditionFlat memory) {
        return ConditionFlat(0, ParameterType.Static, Op.EQUAL_TO_AVATAR, "");
    }

    /// @notice Calldata-matching tree with one argument condition per parameter, in parameter order.
    function t1(ConditionFlat memory a) internal pure returns (ConditionFlat[] memory out) {
        out = _args(1);
        out[1] = a;
    }

    function t2(ConditionFlat memory a, ConditionFlat memory b) internal pure returns (ConditionFlat[] memory out) {
        out = _args(2);
        out[1] = a;
        out[2] = b;
    }

    function t3(ConditionFlat memory a, ConditionFlat memory b, ConditionFlat memory c)
        internal
        pure
        returns (ConditionFlat[] memory out)
    {
        out = _args(3);
        out[1] = a;
        out[2] = b;
        out[3] = c;
    }

    function t4(ConditionFlat memory a, ConditionFlat memory b, ConditionFlat memory c, ConditionFlat memory d)
        internal
        pure
        returns (ConditionFlat[] memory out)
    {
        out = _args(4);
        out[1] = a;
        out[2] = b;
        out[3] = c;
        out[4] = d;
    }

    function _args(uint256 n) private pure returns (ConditionFlat[] memory out) {
        out = new ConditionFlat[](n + 1);
        out[0] = ConditionFlat(0, ParameterType.Calldata, Op.MATCHES, "");
    }
}

/// @notice Disjunction of condition trees for one `(target, selector)` key.
library PermissionMerge {
    /// @notice Returns one BFS-ordered tree that passes when any input tree passes.
    /// @dev Output root is an `Or` node; each input root becomes a child of it. Children of input nodes are appended
    ///      in queue order, so `parent` indices in the output are non-decreasing as Roles v2 requires. Input trees
    ///      must each be non-empty and have a root at index 0.
    /// @param trees Non-empty list of condition trees to OR together.
    /// @return out The merged tree.
    function orOf(ConditionFlat[][] memory trees) internal pure returns (ConditionFlat[] memory out) {
        uint256 total = 1;
        for (uint256 t; t < trees.length; ++t) {
            total += trees[t].length;
        }

        out = new ConditionFlat[](total);
        out[0] = ConditionFlat(0, ParameterType.None, Op.OR, "");

        // Queue of (tree, source node, output index) still to expand.
        uint256[] memory qTree = new uint256[](total);
        uint256[] memory qNode = new uint256[](total);
        uint256[] memory qOut = new uint256[](total);
        uint256 head;
        uint256 tail;
        uint256 next = 1;

        for (uint256 t; t < trees.length; ++t) {
            ConditionFlat memory root = trees[t][0];
            out[next] = ConditionFlat(0, root.paramType, root.operator, root.compValue);
            qTree[tail] = t;
            qNode[tail] = 0;
            qOut[tail] = next;
            ++tail;
            ++next;
        }

        while (head < tail) {
            uint256 t = qTree[head];
            uint256 node = qNode[head];
            uint256 parentOut = qOut[head];
            ++head;

            ConditionFlat[] memory src = trees[t];
            for (uint256 j = 1; j < src.length; ++j) {
                if (uint256(src[j].parent) != node) continue;
                out[next] = ConditionFlat(uint8(parentOut), src[j].paramType, src[j].operator, src[j].compValue);
                qTree[tail] = t;
                qNode[tail] = j;
                qOut[tail] = next;
                ++tail;
                ++next;
            }
        }

        require(next == total, "PermissionMerge: size");
    }
}
