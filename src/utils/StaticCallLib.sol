// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title StaticCallLib
/// @author kpk
/// @notice Best-effort view-call helpers for reading from possibly-noncompliant external contracts: a staticcall
///         that decodes a uint256/address only when it succeeds and returns at least 32 bytes, otherwise reports
///         failure (false / zero) instead of reverting.
/// @dev Centralizes the staticcall+decode wrappers that were copy-pasted — and had begun to drift — across
///      AuraRewardsMeta, ConvexRewardsMeta, and UniswapV2PairLib. Internal library: inlined into each caller (no
///      separate deployment, no DELEGATECALL), so this is a maintainability/consistency change, not a size one.
library StaticCallLib {
    /// @notice staticcalls `target` with `data` and decodes a uint256 on success.
    /// @return ok True iff the call succeeded and returned at least 32 bytes.
    /// @return result The decoded uint256 (0 when `!ok`).
    function safeUint(address target, bytes memory data) internal view returns (bool ok, uint256 result) {
        bytes memory ret;
        (ok, ret) = target.staticcall(data);
        if (ok && ret.length >= 32) result = abi.decode(ret, (uint256));
    }

    /// @notice staticcalls `target` with `data` and decodes an address on success.
    /// @return ok True iff the call succeeded and returned at least 32 bytes.
    /// @return result The decoded address (address(0) when `!ok`).
    function safeAddr(address target, bytes memory data) internal view returns (bool ok, address result) {
        bytes memory ret;
        (ok, ret) = target.staticcall(data);
        if (ok && ret.length >= 32) result = abi.decode(ret, (address));
    }
}
