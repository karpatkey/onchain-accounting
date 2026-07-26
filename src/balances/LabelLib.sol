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
/// @dev `positionLabels` is a verbose/display-only path and MUST NOT revert. A token's metadata read can fail three
///      ways, and a bare `try`/`catch` covers only one of them:
///        1. the address has **no code** — a high-level call reverts via Solidity's `extcodesize` precheck *before*
///           the call, which `try`/`catch` does NOT catch;
///        2. the call **reverts** — this is the one `try`/`catch` does catch;
///        3. the call **succeeds but returns data that cannot be ABI-decoded as a string** — Solidity does NOT route
///           a return-data decode failure into the `catch` clause, so it propagates to the caller and reverts the
///           whole labels read.
///      Class 3 is not hypothetical. Reproduced on solc 0.8.34: a token returning zero bytes (an ERC-1967 proxy whose
///      implementation slot points at a code-less address — the `delegatecall` succeeds returning nothing), a `bytes32`
///      name/symbol (MKR-style legacy tokens), a bare offset word with no length word, a nonsense offset, and absurd
///      declared lengths. Every one of those used to revert `positionLabels` for every adapter reading through here.
///
///      All three classes are handled below: an explicit codesize guard, a raw `staticcall` (so a revert is a `false`
///      return rather than an exception), and **validation of the ABI head before decoding**. A canonical `string`
///      return is `[offset = 0x20][length][payload…]`, so we require two full words, an offset of exactly `0x20`, a
///      non-zero length within {MAX_METADATA_BYTES}, and a payload that fits inside the returndata. Bounding on the
///      raw length is sufficient — a memory-source `abi.decode` bounds on the declared length, not on `ceil32` of it,
///      verified by sweeping truncated and unpadded payloads.
///
///      The read is **gas-capped**, and that is load-bearing rather than defensive. The previous `try`/`catch` form
///      used a parameterless `catch {}`, which never `returndatacopy`s the revert payload; a raw staticcall assigning
///      `(bool, bytes memory)` always does. Without {METADATA_READ_GAS} this rewrite would therefore introduce a
///      griefing vector that did not exist before — a hostile address returning a multi-megabyte revert payload, or
///      simply looping, was measured burning over a billion gas and could out-of-gas a verbose NAV read.
///
///      Callers get the metadata or their chosen `fallbackStr`, and never a revert. Empty-string returns are
///      normalised to `fallbackStr` too. Pass `""` for the single-leaf collapse convention (drop the leaf, keep the
///      category) or `"?"` as a placeholder inside a joined multi-token leaf. Shared across the meta, plain, and
///      assisted adapter families.
library LabelLib {
    /// @notice Longest metadata string accepted; anything longer yields `fallbackStr`. Bounds how much a hostile
    ///         token can inflate a rendered label. Far above any real name or symbol.
    uint256 private constant MAX_METADATA_BYTES = 256;

    /// @notice Gas stipend for a metadata probe. Generous for a real (even proxied) `name()`/`symbol()`, small enough
    ///         that a hostile address can neither burn the caller's budget nor afford a griefing-sized return payload.
    uint256 private constant METADATA_READ_GAS = 100_000;

    /// @notice The token's ERC20 `name()`, or `fallbackStr` if the address has no code, the call reverts, the return
    ///         data is not a decodable string, or it returns an empty string.
    function name(address token, string memory fallbackStr) internal view returns (string memory) {
        return _readString(token, IERC20MetaView.name.selector, fallbackStr);
    }

    /// @notice The token's ERC20 `symbol()`, or `fallbackStr` if the address has no code, the call reverts, the return
    ///         data is not a decodable string, or it returns an empty string.
    function symbol(address token, string memory fallbackStr) internal view returns (string memory) {
        return _readString(token, IERC20MetaView.symbol.selector, fallbackStr);
    }

    /// @notice Shared fail-open string-metadata read behind {name} and {symbol}.
    /// @param token The contract to probe.
    /// @param selector The parameterless, string-returning selector to call.
    /// @param fallbackStr Returned unchanged on every failure path, and for an empty result.
    /// @dev See the contract-level doc for why each guard exists. Order matters: codesize first (cheapest, and the
    ///      class a high-level call cannot catch), then the capped raw call, then head validation, and only then the
    ///      decode — which is safe precisely because the head was validated.
    function _readString(address token, bytes4 selector, string memory fallbackStr)
        private
        view
        returns (string memory)
    {
        if (token.code.length == 0) return fallbackStr;

        (bool ok, bytes memory data) = token.staticcall{gas: METADATA_READ_GAS}(abi.encodeWithSelector(selector));
        // A `string` return needs at least the offset and length words; anything shorter cannot be decoded.
        if (!ok || data.length < 64) return fallbackStr;

        uint256 offset;
        uint256 len;
        assembly ("memory-safe") {
            offset := mload(add(data, 0x20))
            len := mload(add(data, 0x40))
        }
        if (offset != 0x20 || len == 0 || len > MAX_METADATA_BYTES || len > data.length - 64) return fallbackStr;

        return abi.decode(data, (string));
    }
}
