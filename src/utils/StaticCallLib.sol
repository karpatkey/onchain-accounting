// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title StaticCallLib
/// @author kpk
/// @notice Best-effort view-call helpers for reading from possibly-noncompliant external contracts: a staticcall
///         that decodes a uint256/address and never reverts on a failed/short call.
/// @dev Centralizes the staticcall+decode wrappers that were copy-pasted — and had begun to drift — across
///      AuraRewardsMeta, ConvexRewardsMeta, and UniswapV2PairLib. Internal library: inlined into each caller (no
///      separate deployment, no DELEGATECALL), so this is a maintainability/consistency change, not a size one.
///      IMPORTANT: `ok` is the raw `staticcall` success flag only — it does NOT incorporate the returndata-length
///      check. A call can return `ok == true` with `result == 0` if the callee returned fewer than 32 bytes
///      (decoding is skipped in that case). Callers that must distinguish "call succeeded but gave no usable
///      value" from "returned zero" should check `result`, not rely on `ok` alone. (This mirrors the exact
///      semantics of the per-adapter helpers this library replaced.)
library StaticCallLib {
    /// @notice staticcalls `target` with `data`, decoding a uint256 only if the call returned ≥ 32 bytes.
    /// @return ok The raw staticcall success flag (true even when fewer than 32 bytes were returned).
    /// @return result The decoded uint256; 0 if the call reverted OR returned fewer than 32 bytes.
    function safeUint(address target, bytes memory data) internal view returns (bool ok, uint256 result) {
        bytes memory ret;
        (ok, ret) = target.staticcall(data);
        if (ok && ret.length >= 32) result = abi.decode(ret, (uint256));
    }

    /// @notice staticcalls `target` with `data`, decoding an address only if the call returned ≥ 32 bytes.
    /// @return ok The raw staticcall success flag (true even when fewer than 32 bytes were returned).
    /// @return result The decoded address; address(0) if the call reverted OR returned fewer than 32 bytes.
    function safeAddr(address target, bytes memory data) internal view returns (bool ok, address result) {
        bytes memory ret;
        (ok, ret) = target.staticcall(data);
        if (ok && ret.length >= 32) result = abi.decode(ret, (address));
    }
}
