// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @notice Minimal ERC20 metadata view (name/symbol) for fail-open label reads.
interface IERC20MetaView {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

/// @title LabelLib
/// @author KPK
/// @notice Fail-open ERC20 `name()` / `symbol()` reads for building human-readable position labels.
/// @dev `positionLabels` is a verbose/display-only path and MUST NOT revert. A token's metadata read can fail two
///      ways that a bare `try/catch` does NOT both cover:
///        1. the call reverts / returns garbage — caught by `try/catch`;
///        2. the address has **no code** — a high-level call reverts via Solidity's `extcodesize` precheck
///           *before* the call, which `try/catch` does NOT catch.
///      Both are handled here (explicit codesize guard + `try/catch`), so callers get the metadata or a caller-chosen
///      `fallbackStr` and never revert. Shared across the meta, plain, and assisted adapter families. Empty-string
///      returns are normalised to `fallbackStr` too. Pass `""` for the single-leaf collapse convention (drop the
///      leaf, keep the category) or `"?"` as a placeholder inside a joined multi-token leaf.
library LabelLib {
    /// @notice The token's ERC20 `name()`, or `fallbackStr` if the address has no code, the call reverts, or it
    ///         returns an empty string.
    function name(address token, string memory fallbackStr) internal view returns (string memory) {
        if (token.code.length == 0) return fallbackStr;
        try IERC20MetaView(token).name() returns (string memory s) {
            return bytes(s).length == 0 ? fallbackStr : s;
        } catch {
            return fallbackStr;
        }
    }

    /// @notice The token's ERC20 `symbol()`, or `fallbackStr` if the address has no code, the call reverts, or it
    ///         returns an empty string.
    function symbol(address token, string memory fallbackStr) internal view returns (string memory) {
        if (token.code.length == 0) return fallbackStr;
        try IERC20MetaView(token).symbol() returns (string memory s) {
            return bytes(s).length == 0 ? fallbackStr : s;
        } catch {
            return fallbackStr;
        }
    }
}
