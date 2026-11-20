// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CelestiaShareProof
/// @author KPK
/// @notice Recomputes a Celestia blob's share commitment from one 512-byte share and its inclusion path, so a caller
///         can compare it with a commitment it trusts (Derive's `VerifiableApp.celestiaLastCommitment()`).
/// @dev Mirrors celestia-app `inclusion.CreateCommitment` for share version 0:
///      - the blob is split into 512-byte shares and grouped into subtrees, a mountain range of powers of two;
///      - each subtree is a namespaced Merkle tree (NMT). Leaf = `ns ‖ ns ‖ sha256(0x00 ‖ ns ‖ share)`: celestia-app
///        pushes `namespace ‖ share` into the tree, so the namespace is hashed twice. Inner node =
///        `ns ‖ ns ‖ sha256(0x01 ‖ left ‖ right)`; one blob has one namespace, so min = max = ns throughout;
///      - the commitment is the RFC 6962 Merkle root (sha256) over the 90-byte subtree roots.
///      The result was checked against real Derive batches: recomputing from the blob bytes gives exactly the
///      `newLastCommitment` the Ethereum batch recorded (derive-spike, `tools/derive_account_attest.py`).
///
///      **Position binding.** A matching root proves a share is in the blob, but the share's index is only bound if
///      the tree shape is the true one: with a wrong subtree count, an RFC 6962 path can verify the same leaf under
///      a different index (in a 3-leaf tree, leaf 2 also verifies as leaf 1 of a 2-leaf tree). So callers never pass
///      the shape. {commitmentOf} takes the blob's share count, derives the subtree layout from it, and requires the
///      NMT path to have exactly its subtree's depth; the share count itself comes from a proven first share
///      ({numSharesOf}). With the true shape, a share verifies at exactly one index.
library CelestiaShareProof {
    uint256 internal constant SHARE_SIZE = 512;
    uint256 internal constant NS_SIZE = 29;
    uint256 internal constant NODE_SIZE = 90; // min ns (29) | max ns (29) | digest (32)

    /// @dev celestia-app `SubtreeRootThreshold`.
    uint256 private constant _SUBTREE_ROOT_THRESHOLD = 64;
    /// @dev Data bytes in the first share (namespace 29, info byte 1, sequence length 4) and in the others.
    uint256 private constant _FIRST_DATA = SHARE_SIZE - 34;
    uint256 private constant _CONT_DATA = SHARE_SIZE - 30;

    error BadShareSize();
    error WrongNamespace();
    error BadNodeSize();
    error BadRfcPath();
    error NotFirstShare();
    error IndexOutOfRange(uint256 index, uint256 numShares);
    error BadNmtDepth(uint256 expected, uint256 found);

    /// @notice The number of shares in a blob, read from its first share.
    /// @dev The first share of a sequence has info byte `version << 1 | 1` (version 0 here) and a big-endian u32
    ///      sequence length after it. Only the first share of a single-blob commitment carries the start bit, so a
    ///      share that passes this and verifies at index 0 is the real first share, and the count is the real one.
    function numSharesOf(bytes memory share) internal pure returns (uint256) {
        if (share.length != SHARE_SIZE) revert BadShareSize();
        if (uint8(share[NS_SIZE]) != 1) revert NotFirstShare();
        uint256 len;
        for (uint256 i = NS_SIZE + 1; i < NS_SIZE + 5; ++i) {
            len = (len << 8) | uint8(share[i]);
        }
        return len <= _FIRST_DATA ? 1 : 1 + Math.ceilDiv(len - _FIRST_DATA, _CONT_DATA);
    }

    /// @notice Where share `index` sits in the commitment tree of a blob of `numShares` shares.
    /// @dev celestia-app `SubTreeWidth` and `MerkleMountainRangeSizes`: subtrees of `width` shares, then the
    ///      remainder as descending powers of two.
    /// @return subtree     Index of the subtree among the blob's subtrees.
    /// @return position    Index of the share inside its subtree.
    /// @return depth       NMT depth of that subtree (log2 of its size).
    /// @return numSubtrees Number of subtrees in the blob.
    function locate(uint256 index, uint256 numShares)
        internal
        pure
        returns (uint256 subtree, uint256 position, uint256 depth, uint256 numSubtrees)
    {
        if (index >= numShares) revert IndexOutOfRange(index, numShares);
        uint256 width = Math.min(
            _roundUpPow2(Math.ceilDiv(numShares, _SUBTREE_ROOT_THRESHOLD)),
            _roundUpPow2(Math.sqrt(numShares, Math.Rounding.Ceil))
        );
        uint256 full = numShares / width;
        uint256 rest = numShares - full * width;
        numSubtrees = full + _popcount(rest);
        if (index < full * width) return (index / width, index % width, Math.log2(width), numSubtrees);

        subtree = full;
        position = index - full * width;
        uint256 size = 1 << Math.log2(rest);
        while (position >= size) {
            position -= size;
            rest -= size;
            ++subtree;
            size = 1 << Math.log2(rest);
        }
        depth = Math.log2(size);
    }

    /// @param share       The 512-byte share. Its first 29 bytes are its namespace.
    /// @param ns          The namespace the share must carry.
    /// @param index       The share's index in the blob.
    /// @param numShares   The blob's share count, from a proven first share ({numSharesOf}).
    /// @param nmtSiblings 90-byte sibling nodes from the leaf to the subtree root; exactly the subtree's depth.
    /// @param rfcSiblings The RFC 6962 audit path for the subtree root, bottom-up.
    /// @return root The commitment these inputs hash to. The caller compares it with a trusted commitment.
    function commitmentOf(
        bytes memory share,
        bytes29 ns,
        uint256 index,
        uint256 numShares,
        bytes[] memory nmtSiblings,
        bytes32[] memory rfcSiblings
    ) internal pure returns (bytes32 root) {
        if (share.length != SHARE_SIZE) revert BadShareSize();
        bytes32 head;
        assembly ("memory-safe") {
            head := mload(add(share, 32))
        }
        if (bytes29(head) != ns) revert WrongNamespace();
        (uint256 subtree, uint256 position, uint256 depth, uint256 numSubtrees) = locate(index, numShares);
        if (nmtSiblings.length != depth) revert BadNmtDepth(depth, nmtSiblings.length);

        bytes memory node = abi.encodePacked(ns, ns, sha256(abi.encodePacked(bytes1(0x00), ns, share)));
        for (uint256 i; i < depth; ++i) {
            bytes memory sib = nmtSiblings[i];
            if (sib.length != NODE_SIZE) revert BadNodeSize();
            bytes32 digest = position & 1 == 0
                ? sha256(abi.encodePacked(bytes1(0x01), node, sib))
                : sha256(abi.encodePacked(bytes1(0x01), sib, node));
            node = abi.encodePacked(ns, ns, digest);
            position >>= 1;
        }

        root = _rfcRoot(sha256(abi.encodePacked(bytes1(0x00), node)), subtree, numSubtrees, rfcSiblings);
    }

    function _roundUpPow2(uint256 x) private pure returns (uint256 r) {
        r = 1;
        while (r < x) r <<= 1;
    }

    function _popcount(uint256 x) private pure returns (uint256 c) {
        while (x != 0) {
            x &= x - 1;
            ++c;
        }
    }

    /// @dev RFC 9162 section 2.1.3.2 inclusion-proof verification, returning the computed root.
    function _rfcRoot(bytes32 leafHash, uint256 index, uint256 size, bytes32[] memory path)
        private
        pure
        returns (bytes32 r)
    {
        if (index >= size) revert BadRfcPath();
        uint256 fn = index;
        uint256 sn = size - 1;
        r = leafHash;
        for (uint256 i; i < path.length; ++i) {
            if (sn == 0) revert BadRfcPath();
            if (fn & 1 == 1 || fn == sn) {
                r = sha256(abi.encodePacked(bytes1(0x01), path[i], r));
                if (fn & 1 == 0) {
                    while (fn & 1 == 0 && fn != 0) {
                        fn >>= 1;
                        sn >>= 1;
                    }
                }
            } else {
                r = sha256(abi.encodePacked(bytes1(0x01), r, path[i]));
            }
            fn >>= 1;
            sn >>= 1;
        }
        if (sn != 0) revert BadRfcPath();
    }
}
