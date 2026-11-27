// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @title DeriveRecord
/// @author KPK
/// @notice Decodes one subaccount record from the subaccount section of a Derive v3 Celestia batch blob.
/// @dev **The format is reverse-engineered, not published by Derive** (evidence: derive-spike
///      `docs/research/derive-v3-l1-verification.md`, addenda of 2026-11-20). Integers are Rust bincode varints: a
///      value below 251 is the byte itself; `0xfb`/`0xfc`/`0xfd`/`0xfe` prefix a little-endian u16/u32/u64/u128.
///      Signed amounts are zigzag-encoded with 12 decimals. One record is:
///
///          id, 1, id, 0, managerId, owner[20],
///          perps       count × (asset[20], subId, amount, v2, v3)
///          collateral  count × (asset[20], subId, balance, interestIndex)
///          options     count × (asset[20], subId, amount)
///          tail        4 varints
///
///      An option's `subId` packs its series: expiry (unix seconds) in bits 0-31, strike (8-decimal USD) in bits
///      32-94, and 1 in bit 95 for a call. Checked against Derive's API on 252 of 252 options of one subaccount.
///
///      Records are sorted by id with no gaps. A record holds the subaccount's full state after the batch, and only
///      subaccounts that changed in the batch appear. Perp fields are skipped by their tag width rather than
///      decoded (only their count is returned); a misaligned skip shows up in the caller's framing check.
library DeriveRecord {
    struct Collateral {
        address asset; // Derive's protocol asset id, not the ERC-20
        uint256 subId;
        int256 balance; // 12-decimal fixed point
    }

    struct Option {
        address asset; // Derive's option asset id, one per underlying
        uint256 subId; // expiry | strike << 32 | isCall << 95
        int256 amount; // 12-decimal fixed point; negative = short
    }

    struct Record {
        uint256 subaccountId;
        uint256 managerId;
        address owner;
        Collateral[] collateral;
        uint256 perpCount;
        Option[] options;
        uint256 end; // offset just past the record
    }

    error NotARecord();
    error Truncated();
    error BadVarint();

    /// @notice Decode the record starting at `d[i]`.
    function decode(bytes memory d, uint256 i) internal pure returns (Record memory r) {
        uint256 id2;
        uint256 flag;
        (r.subaccountId, i) = varint(d, i);
        if (_byte(d, i) != 1) revert NotARecord();
        (id2, i) = varint(d, i + 1);
        (flag, i) = varint(d, i);
        if (id2 != r.subaccountId || flag != 0) revert NotARecord();
        (r.managerId, i) = varint(d, i);
        (r.owner, i) = _addr(d, i);

        (r.perpCount, i) = varint(d, i);
        for (uint256 k; k < r.perpCount; ++k) {
            i = _skipVarints(d, i + 20, 4); // subId, amount, v2, v3
        }

        uint256 n;
        (n, i) = varint(d, i);
        r.collateral = new Collateral[](n);
        for (uint256 k; k < n; ++k) {
            Collateral memory c = r.collateral[k];
            uint256 raw;
            (c.asset, i) = _addr(d, i);
            (c.subId, i) = varint(d, i);
            (raw, i) = varint(d, i);
            c.balance = zigzag(raw);
            i = _skipVarints(d, i, 1); // interest index
        }

        (n, i) = varint(d, i);
        r.options = new Option[](n);
        for (uint256 k; k < n; ++k) {
            Option memory o = r.options[k];
            uint256 raw;
            (o.asset, i) = _addr(d, i);
            (o.subId, i) = varint(d, i);
            (raw, i) = varint(d, i);
            o.amount = zigzag(raw);
        }
        r.end = _skipVarints(d, i, 4);
    }

    /// @notice True if `d[i:]` starts a record head `id, 1, id` with an id above `prevId`.
    /// @dev Records are sorted with no gaps, so this is the framing check right after a record.
    function isHeadAfter(bytes memory d, uint256 i, uint256 prevId) internal pure returns (bool) {
        (uint256 a, uint256 j) = varint(d, i);
        if (_byte(d, j) != 1) return false;
        (uint256 b,) = varint(d, j + 1);
        return a == b && a > prevId;
    }

    function varint(bytes memory d, uint256 i) internal pure returns (uint256 v, uint256 next) {
        uint8 t = _byte(d, i);
        if (t < 251) return (t, i + 1);
        uint256 n = _width(t);
        if (i + 1 + n > d.length) revert Truncated();
        for (uint256 k; k < n; ++k) {
            v |= uint256(uint8(d[i + 1 + k])) << (8 * k);
        }
        next = i + 1 + n;
    }

    /// @dev Zigzag decode. Values come from at most 16 bytes, so `v >> 1` fits in int256.
    function zigzag(uint256 v) internal pure returns (int256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return v & 1 == 0 ? int256(v >> 1) : -int256((v + 1) >> 1);
    }

    /// @dev Advances past `count` varints from their tag bytes alone.
    function _skipVarints(bytes memory d, uint256 i, uint256 count) private pure returns (uint256) {
        for (uint256 k; k < count; ++k) {
            uint8 t = _byte(d, i);
            i += t < 251 ? 1 : 1 + _width(t);
        }
        if (i > d.length) revert Truncated();
        return i;
    }

    function _width(uint8 t) private pure returns (uint256) {
        if (t == 0xfb) return 2;
        if (t == 0xfc) return 4;
        if (t == 0xfd) return 8;
        if (t == 0xfe) return 16;
        revert BadVarint();
    }

    function _addr(bytes memory d, uint256 i) private pure returns (address a, uint256 next) {
        if (i + 20 > d.length) revert Truncated();
        assembly ("memory-safe") {
            a := shr(96, mload(add(add(d, 32), i)))
        }
        next = i + 20;
    }

    function _byte(bytes memory d, uint256 i) private pure returns (uint8) {
        if (i >= d.length) revert Truncated();
        return uint8(d[i]);
    }
}
