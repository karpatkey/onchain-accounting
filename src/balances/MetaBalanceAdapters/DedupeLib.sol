// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @title DedupeLib
/// @author KPK
/// @notice Membership test for the incremental address de-duplication that several meta-adapters do while building a
///         token set (Compound V3 collateral + base + reward enumeration; Convex CRV + CVX + extra rewards). Each
///         appends a candidate only if it is not already in the partially-filled array — {contains} is that scan.
/// @dev `internal pure`, inlined (not a linked/pinned external library). A length-bounded scan (`len`, not
///      `arr.length`) so callers can pass an over-allocated buffer they fill in place.
library DedupeLib {
    /// @notice True if `value` appears in the first `len` entries of `arr`.
    /// @param arr   The (possibly over-allocated) array to scan.
    /// @param len   The number of filled entries to consider.
    /// @param value The address to look for.
    function contains(address[] memory arr, uint256 len, address value) internal pure returns (bool) {
        for (uint256 j = 0; j < len; j++) {
            if (arr[j] == value) return true;
        }
        return false;
    }
}
