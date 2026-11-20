// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

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
library CelestiaShareProof {
    uint256 internal constant SHARE_SIZE = 512;
    uint256 internal constant NS_SIZE = 29;
    uint256 internal constant NODE_SIZE = 90; // min ns (29) | max ns (29) | digest (32)

    error BadShareSize();
    error WrongNamespace();
    error BadNodeSize();
    error BadRfcPath();

    /// @param share       The 512-byte share. Its first 29 bytes are its namespace.
    /// @param ns          The namespace the share must carry.
    /// @param position    The share's index inside its subtree.
    /// @param nmtSiblings 90-byte sibling nodes from the leaf to the subtree root.
    /// @param subtree     The subtree's index among the blob's subtrees.
    /// @param numSubtrees The number of subtrees in the blob. It only steers left/right choices on the RFC path, so
    ///                    a wrong count that yields the same choices still reaches the true root. The root binds the
    ///                    share's position, so such a count is accepted and harmless.
    /// @param rfcSiblings The RFC 6962 audit path for the subtree root, bottom-up.
    /// @return root The commitment these inputs hash to. The caller compares it with a trusted commitment.
    function commitmentOf(
        bytes memory share,
        bytes29 ns,
        uint256 position,
        bytes[] memory nmtSiblings,
        uint256 subtree,
        uint256 numSubtrees,
        bytes32[] memory rfcSiblings
    ) internal pure returns (bytes32 root) {
        if (share.length != SHARE_SIZE) revert BadShareSize();
        bytes32 head;
        assembly ("memory-safe") {
            head := mload(add(share, 32))
        }
        if (bytes29(head) != ns) revert WrongNamespace();

        bytes memory node = abi.encodePacked(ns, ns, sha256(abi.encodePacked(bytes1(0x00), ns, share)));
        for (uint256 i; i < nmtSiblings.length; ++i) {
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
