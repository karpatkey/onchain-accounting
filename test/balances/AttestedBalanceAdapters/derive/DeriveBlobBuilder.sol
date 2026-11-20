// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {
    DeriveCelestiaAttestedBalanceAdapter
} from "src/balances/AttestedBalanceAdapters/DeriveCelestiaAttestedBalanceAdapter.sol";

/// @notice Builds small synthetic Derive blobs and their Celestia share proofs, so unit tests can exercise every
///         acceptance rule with chosen owners, assets and balances.
/// @dev Test-only and deliberately small: under 64 shares the celestia-app subtree width is 1, so every share is
///      its own subtree, the NMT paths are empty, and the commitment is the RFC 6962 root over per-share leaves.
///      The NMT path itself is exercised by the real-batch fixtures (subtree width 16), which were checked against
///      commitments recorded on Ethereum, so this builder sharing code paths with the verifier cannot hide a bug in
///      the hashing.
library DeriveBlobBuilder {
    bytes29 internal constant NS = bytes29(hex"0000000000000000000000000000000000000046023b2bfb8ba6dc6fdc");
    uint256 internal constant FIRST_DATA = 512 - 34;
    uint256 internal constant CONT_DATA = 512 - 30;

    struct Coll {
        address asset;
        int256 balance; // 12-decimal fixed point
    }

    struct Rec {
        uint256 id;
        address owner;
        Coll[] coll;
        uint256 perps;
        uint256 options;
    }

    struct Blob {
        bytes data;
        uint256[] starts; // record start offsets in `data`
        uint256[] ends;
        bytes32 commitment;
        bytes[] shares;
    }

    // ─────────────────────────────────────────────────────────────── encoding

    function varint(uint256 v) internal pure returns (bytes memory) {
        if (v < 251) return abi.encodePacked(uint8(v));
        if (v < 1 << 16) return abi.encodePacked(uint8(0xfb), _le(v, 2));
        if (v < 1 << 32) return abi.encodePacked(uint8(0xfc), _le(v, 4));
        if (v < 1 << 64) return abi.encodePacked(uint8(0xfd), _le(v, 8));
        return abi.encodePacked(uint8(0xfe), _le(v, 16));
    }

    function zigzag(int256 v) internal pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return v >= 0 ? uint256(v) << 1 : (uint256(-v) << 1) - 1;
    }

    function record(Rec memory r) internal pure returns (bytes memory out) {
        out = abi.encodePacked(varint(r.id), uint8(1), varint(r.id), uint8(0), uint8(2), r.owner);
        out = abi.encodePacked(out, varint(r.perps));
        for (uint256 i; i < r.perps; ++i) {
            out = abi.encodePacked(out, address(0xBEEF), uint8(0), varint(zigzag(10e12)), uint8(0), uint8(0));
        }
        out = abi.encodePacked(out, varint(r.coll.length));
        for (uint256 i; i < r.coll.length; ++i) {
            out = abi.encodePacked(out, r.coll[i].asset, uint8(0), varint(zigzag(r.coll[i].balance)), varint(1e12));
        }
        out = abi.encodePacked(out, varint(r.options));
        for (uint256 i; i < r.options; ++i) {
            out = abi.encodePacked(out, address(0xCAFE), varint(uint256(1) << 120), varint(zigzag(5e12)));
        }
        out = abi.encodePacked(out, uint8(0), uint8(0), uint8(0), uint8(0));
    }

    /// @notice A blob: previous commitment, the record count, the sorted records, then the start of the next
    ///         section (a count and an address), as in real blobs.
    function build(Rec[] memory recs) internal pure returns (Blob memory b) {
        b.starts = new uint256[](recs.length);
        b.ends = new uint256[](recs.length);
        b.data = abi.encodePacked(bytes32(0), varint(recs.length));
        for (uint256 i; i < recs.length; ++i) {
            b.starts[i] = b.data.length;
            b.data = abi.encodePacked(b.data, record(recs[i]));
            b.ends[i] = b.data.length;
        }
        b.data = abi.encodePacked(b.data, uint8(0x35), uint8(2), address(0x1234));
        b.shares = _shares(b.data);
        b.commitment = _rfcRoot(_leaves(b.shares));
    }

    // ─────────────────────────────────────────────────────────────── proofs

    /// @notice Proof for record `k`, framed by the next record's head, or by the previous record if `usePrevious`.
    function proof(Blob memory b, uint256 k, uint256 id, bool usePrevious)
        internal
        pure
        returns (DeriveCelestiaAttestedBalanceAdapter.SubaccountProof memory p)
    {
        uint256 from = usePrevious ? b.starts[k - 1] : b.starts[k];
        uint256 to = usePrevious ? b.ends[k] : b.ends[k] + 12;
        if (to > b.data.length) to = b.data.length;
        uint256 s0 = _shareOf(from);
        uint256 s1 = _shareOf(to - 1);

        p.subaccountId = id;
        p.numSubtrees = b.shares.length;
        p.recordOffset = b.starts[k] - _dataStart(s0);
        p.usePrevious = usePrevious;
        p.prevOffset = usePrevious ? b.starts[k - 1] - _dataStart(s0) : 0;

        bytes32[] memory leaves = _leaves(b.shares);
        p.shares = new DeriveCelestiaAttestedBalanceAdapter.ShareProof[](s1 - s0 + 1);
        for (uint256 i = s0; i <= s1; ++i) {
            DeriveCelestiaAttestedBalanceAdapter.ShareProof memory s = p.shares[i - s0];
            s.index = i;
            s.share = b.shares[i];
            s.subtree = i;
            s.position = 0;
            s.nmtSiblings = new bytes[](0);
            s.rfcSiblings = _rfcPath(leaves, i);
        }
    }

    function payload(DeriveCelestiaAttestedBalanceAdapter.SubaccountProof memory p)
        internal
        pure
        returns (bytes memory)
    {
        DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[] memory ps =
            new DeriveCelestiaAttestedBalanceAdapter.SubaccountProof[](1);
        ps[0] = p;
        return abi.encode(ps);
    }

    // ─────────────────────────────────────────────────────────────── internals

    function _shares(bytes memory data) private pure returns (bytes[] memory out) {
        uint256 n = data.length <= FIRST_DATA ? 1 : 1 + (data.length - FIRST_DATA + CONT_DATA - 1) / CONT_DATA;
        out = new bytes[](n);
        uint256 off;
        for (uint256 i; i < n; ++i) {
            bytes memory head =
                i == 0 ? abi.encodePacked(NS, uint8(1), uint32(data.length)) : abi.encodePacked(NS, uint8(0));
            uint256 room = 512 - head.length;
            bytes memory chunk = new bytes(room);
            for (uint256 j; j < room && off < data.length; ++j) {
                chunk[j] = data[off++];
            }
            out[i] = abi.encodePacked(head, chunk);
        }
    }

    function _leaves(bytes[] memory shares) private pure returns (bytes32[] memory out) {
        out = new bytes32[](shares.length);
        for (uint256 i; i < shares.length; ++i) {
            bytes memory node = abi.encodePacked(NS, NS, sha256(abi.encodePacked(bytes1(0x00), NS, shares[i])));
            out[i] = sha256(abi.encodePacked(bytes1(0x00), node));
        }
    }

    function _split(uint256 n) private pure returns (uint256 k) {
        k = 1;
        while (k << 1 < n) k <<= 1;
    }

    function _rfcRoot(bytes32[] memory leaves) private pure returns (bytes32) {
        return _root(leaves, 0, leaves.length);
    }

    function _root(bytes32[] memory l, uint256 from, uint256 n) private pure returns (bytes32) {
        if (n == 1) return l[from];
        uint256 k = _split(n);
        return sha256(abi.encodePacked(bytes1(0x01), _root(l, from, k), _root(l, from + k, n - k)));
    }

    function _rfcPath(bytes32[] memory l, uint256 m) private pure returns (bytes32[] memory) {
        bytes32[] memory tmp = new bytes32[](64);
        uint256 len = _path(l, 0, l.length, m, tmp, 0);
        bytes32[] memory out = new bytes32[](len);
        for (uint256 i; i < len; ++i) {
            out[i] = tmp[i];
        }
        return out;
    }

    /// @dev Writes the audit path bottom-up into `out` starting at `at`; returns the new length.
    function _path(bytes32[] memory l, uint256 from, uint256 n, uint256 m, bytes32[] memory out, uint256 at)
        private
        pure
        returns (uint256)
    {
        if (n == 1) return at;
        uint256 k = _split(n);
        if (m < k) {
            at = _path(l, from, k, m, out, at);
            out[at] = _root(l, from + k, n - k);
        } else {
            at = _path(l, from + k, n - k, m - k, out, at);
            out[at] = _root(l, from, k);
        }
        return at + 1;
    }

    function _dataStart(uint256 i) private pure returns (uint256) {
        return i == 0 ? 0 : FIRST_DATA + (i - 1) * CONT_DATA;
    }

    function _shareOf(uint256 p) private pure returns (uint256) {
        return p < FIRST_DATA ? 0 : 1 + (p - FIRST_DATA) / CONT_DATA;
    }

    function _le(uint256 v, uint256 n) private pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = bytes1(uint8(v >> (8 * i)));
        }
    }
}
