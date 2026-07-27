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
    /// @dev This is a NEW global constraint: the `try`/`catch` form this replaced returned any successfully-decoded
    ///      string regardless of length, and none of the call sites previously asked for a cap. Deliberate — an
    ///      unbounded label is an unbounded cost for every downstream renderer — but it does mean a token with an
    ///      absurdly long name now renders as the caller's fallback rather than in full.
    uint256 private constant MAX_METADATA_BYTES = 256;

    /// @notice Hard ceiling on returndata **copied into this contract's memory**: the two ABI head words plus
    ///         {MAX_METADATA_BYTES} of payload (64 + 256 = 320). Written as a literal because inline assembly accepts
    ///         only direct number constants.
    /// @dev **This constant is where {MAX_METADATA_BYTES} is actually enforced.** The payload-fits check bounds `len`
    ///      by `copied - 64`, and `copied <= MAX_RETURN_BYTES`, so the cap follows structurally — which is why there is
    ///      no separate `len > MAX_METADATA_BYTES` clause (it would be provably unreachable). Keep the two constants in
    ///      lockstep: `MAX_RETURN_BYTES == 64 + MAX_METADATA_BYTES`.
    ///
    ///      **Bound on what was COPIED, never on `returndatasize()`.** An earlier revision rejected any reply larger
    ///      than this constant, on the stated assumption that a canonical reply for an in-cap string never exceeds it.
    ///      That assumption is **wrong**, and the counterexamples are ordinary mainnet tokens: the Vyper LP tokens from
    ///      Curve's USD-metapool factory (`0xB9fC157394Af804a3578134A6585C0dc9cc990d4`) return a fixed **4096-byte**
    ///      buffer behind a perfectly canonical head — FRAX3CRV-f, MIM-3LP3CRV-f, alUSD3CRV-f and LUSD3CRV-f among
    ///      them, 12 of the first 80 pools in that factory — carrying strings of only 10-57 bytes. `abi.decode`
    ///      accepts those, as did both predecessors; only a size-keyed reject discarded them, and on their padding
    ///      rather than their content. None is a configured instance today, but the Curve/Convex roadmap makes it a
    ///      live trap. Hence `copied = min(size, MAX_RETURN_BYTES)` and a payload bound against `copied`.
    ///
    ///      This, not the gas stipend, is what bounds caller-side cost. A gas stipend alone does NOT: a hostile token
    ///      can `return(0, 200_000)` — the callee's own memory expansion for ~200 KB costs it about 95k, so it fits
    ///      inside {METADATA_READ_GAS} — while the *caller* pays `returndatacopy` plus its own monotonically growing
    ///      memory, charged outside the stipend and quadratic in total. Measured on the stipend-only version: 210,190
    ///      gas for one read and 14.5M across eight sequential reads in one frame, which a multi-token leaf
    ///      (`_joinTokenSymbols` over a Balancer pool, `CurvePoolLib.coinSymbols` over an 8-coin pool) does. Passing an
    ///      explicit output size to `staticcall` copies at most this many bytes no matter what the callee returns, so
    ///      the cost is flat. `returndatasize()` still reports the true size, so an oversized reply is rejected rather
    ///      than silently truncated.
    uint256 private constant MAX_RETURN_BYTES = 320;

    /// @notice Gas stipend for a metadata probe. Generous for a real (even proxied) `name()`/`symbol()`, and it bounds
    ///         the callee's own execution — including a write-protection abort, which consumes everything forwarded.
    /// @dev Necessary but NOT sufficient on its own; see {MAX_RETURN_BYTES} for the caller-side bound.
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
        // Cheap short-circuit only. A raw `staticcall` to a code-less address succeeds with empty returndata, which the
        // length check below already rejects — unlike the high-level call this replaced, where `extcodesize` reverted
        // before the call and made this guard load-bearing.
        if (token.code.length == 0) return fallbackStr;

        bytes memory data = new bytes(MAX_RETURN_BYTES);
        bool ok;
        uint256 size;
        assembly ("memory-safe") {
            // Selector into scratch space; `bytes4` is left-aligned in its word, so the first 4 bytes are the selector.
            mstore(0x00, selector)
            // The explicit output size is the point: at most MAX_RETURN_BYTES is copied into our memory, whatever the
            // callee returns. `returndatasize()` still reports the untruncated size.
            ok := staticcall(METADATA_READ_GAS, token, 0x00, 0x04, add(data, 0x20), MAX_RETURN_BYTES)
            size := returndatasize()
        }
        // A `string` return needs at least the offset and length words.
        if (!ok || size < 64) return fallbackStr;

        // Only the first MAX_RETURN_BYTES were copied; `size` may be larger. Bound on what we actually HAVE, not on
        // what the callee claimed to send. Keying the accept window on `size` instead would reject a reply whose
        // string sits entirely inside the copied window but which carries trailing or over-padded bytes behind it —
        // a narrowing versus both predecessors (the high-level typed call and StakeWise's `_safeVaultName`), and one
        // no real string needs. `copied >= 64` because `size >= 64` and MAX_RETURN_BYTES far exceeds 64.
        uint256 copied = size < MAX_RETURN_BYTES ? size : MAX_RETURN_BYTES;

        // Shrink to the copied extent so `abi.decode`'s own bound matches the bytes we hold.
        assembly ("memory-safe") {
            mstore(data, copied)
        }

        uint256 offset;
        uint256 len;
        assembly ("memory-safe") {
            offset := mload(add(data, 0x20))
            len := mload(add(data, 0x40))
        }
        // `len > copied - 64` is the payload-fits check, written as a subtraction on the LEFT so an attacker-supplied
        // `len` near 2^256 cannot overflow `64 + len`. It also enforces {MAX_METADATA_BYTES} structurally: `copied` is
        // at most `MAX_RETURN_BYTES` = 64 + MAX_METADATA_BYTES, so any accepted `len` is at most MAX_METADATA_BYTES.
        // An explicit `len > MAX_METADATA_BYTES` clause here would be dead code — mutation-testable to nothing — so the
        // cap lives in the MAX_RETURN_BYTES definition instead. Change one of those two constants and you must change
        // the other.
        if (offset != 0x20 || len == 0 || len > copied - 64) return fallbackStr;

        return abi.decode(data, (string));
    }
}
