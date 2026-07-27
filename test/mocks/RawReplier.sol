// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title RawReplier
/// @notice A contract that answers **any** call with a caller-staged raw byte string, or reverts, or burns every
///         unit of gas it is given.
/// @dev Exists to reproduce the failure classes a Solidity `try`/`catch` does NOT cover. `try` only catches a
///      *revert*; it does not catch the `extcodesize` precheck that fires before a high-level call to a code-less
///      address, and — the subtle one — it does not catch a **return-data decode failure**, because the decoder runs
///      in the *calling* frame after the call has already returned successfully. Staging returndata that is not
///      decodable as the declared type is therefore the only way to exercise that path, and a normal Solidity mock
///      cannot express it: its return value is always well-formed by construction.
///
///      Every reply is produced from the `fallback`, so a single instance stands in for any interface. Reads storage
///      only, so it works under `staticcall`.
contract RawReplier {
    /// @notice What the next call gets back. `Return` replies with {payload} verbatim.
    enum Mode {
        Return,
        Revert,
        BurnGas,
        BigReturn,
        RevertWith
    }

    /// @notice First word of a {Mode.BigReturn} reply, so a test can assert the big reply actually ARRIVED
    ///         rather than only that the caller stayed cheap.
    /// @dev Without a recognisable marker, a huge-reply test passes vacuously the moment the callee can no
    ///      longer afford to produce the reply: `returndatasize()` collapses to 0, the caller's gas drops, and
    ///      an upper-bound-only assertion still holds while the property under test is no longer exercised.
    uint256 public constant BIG_RETURN_MARKER = 0x5BADC0DE;

    Mode public mode;

    /// @notice Raw bytes returned verbatim in {Mode.Return} — canonical or deliberately malformed.
    bytes public payload;

    /// @notice Size of the revert payload in {Mode.Revert}. Large values make the *callee* pay for the memory
    ///         expansion, which is exactly what a gas stipend is meant to stop.
    uint256 public revertBytes;

    /// @notice Size of the SUCCESS-path reply in {Mode.BigReturn}.
    uint256 public returnBytes;

    /// @notice Reply to every call with `data`, byte for byte.
    function stageReturn(bytes memory data) external {
        mode = Mode.Return;
        payload = data;
    }

    /// @notice Revert on every call, with a `size`-byte revert payload.
    /// @dev A raw `staticcall` assigning `(bool, bytes memory)` always `returndatacopy`s this, unlike a
    ///      parameterless `catch {}` — which is why the reader under test must cap both gas and the copied size.
    function stageRevert(uint256 size) external {
        mode = Mode.Revert;
        revertBytes = size;
    }

    /// @notice Consume all forwarded gas and never return.
    function stageBurnGas() external {
        mode = Mode.BurnGas;
    }

    /// @notice Reply **successfully** with `size` bytes, the first word being {BIG_RETURN_MARKER}.
    /// @dev The success path is the only way to test a reader's returndata-copy cost. A revert bomb proves
    ///      nothing about it: a big `revert(0, size)` out-of-gasses inside the callee's own memory expansion once
    ///      the reader caps the stipend, so `returndatasize()` collapses to 0 and the caller never copies
    ///      anything. `return(0, size)` costs the callee the same memory expansion but leaves a genuinely large
    ///      reply for the caller to (not) copy — and the marker lets the test prove the reply arrived.
    function stageBigReturn(uint256 size) external {
        mode = Mode.BigReturn;
        returnBytes = size;
    }

    /// @notice Revert with `data` verbatim.
    /// @dev Distinct from {stageRevert}, which reverts with `size` zero bytes out of untouched memory. A reader
    ///      that gates only on `returndatasize()` and not on the success flag cannot tell this from a real reply,
    ///      so staging a revert payload with recognisable CONTENT is the only way to exercise that distinction —
    ///      and it must be small enough that the callee can afford to emit it under the reader's stipend.
    function stageRevertWith(bytes memory data) external {
        mode = Mode.RevertWith;
        payload = data;
    }

    fallback() external {
        Mode m = mode;
        if (m == Mode.Revert) {
            uint256 size = revertBytes;
            assembly {
                revert(0, size)
            }
        }
        if (m == Mode.RevertWith) {
            bytes memory r = payload;
            assembly {
                revert(add(r, 0x20), mload(r))
            }
        }
        if (m == Mode.BigReturn) {
            uint256 size = returnBytes;
            assembly {
                mstore(0x00, BIG_RETURN_MARKER)
                return(0, size)
            }
        }
        if (m == Mode.BurnGas) {
            assembly {
                // Hash the same word forever: no memory growth, so this burns the stipend steadily rather than
                // out-of-gassing early on memory expansion.
                for {} 1 {} { mstore(0x00, keccak256(0x00, 0x20)) }
            }
        }
        bytes memory p = payload;
        assembly {
            return(add(p, 0x20), mload(p))
        }
    }
}

/// @title RawReplyLib
/// @notice Builders for the malformed `string`-return shapes {RawReplier} stages.
/// @dev A canonical ABI `string` return is `[offset = 0x20][length][padded payload]`. Each helper below breaks
///      exactly one part of that, so a test can name the shape it is exercising.
library RawReplyLib {
    /// @notice A well-formed `string` return — the control case.
    function canonicalString(string memory s) internal pure returns (bytes memory) {
        return abi.encode(s);
    }

    /// @notice A single 32-byte word, the way MKR-era tokens return a `bytes32` "string".
    function bytes32String(bytes32 word) internal pure returns (bytes memory) {
        return abi.encodePacked(word);
    }

    /// @notice The offset word and nothing else — a dynamic-type head with no length word.
    function offsetOnly() internal pure returns (bytes memory) {
        return abi.encodePacked(uint256(0x20));
    }

    /// @notice A head whose offset points somewhere other than 0x20.
    function badOffset(uint256 offset, string memory s) internal pure returns (bytes memory) {
        return abi.encodePacked(offset, bytes(s).length, bytes(s));
    }

    /// @notice A head declaring `len` bytes of payload but carrying `s` — truncated when `len > bytes(s).length`.
    function declaredLength(uint256 len, string memory s) internal pure returns (bytes memory) {
        return abi.encodePacked(uint256(0x20), len, bytes(s));
    }

    /// @notice A canonical head plus `n` bytes of payload, for probing the length cap and the returndata-size cap.
    function stringOfLength(uint256 n) internal pure returns (bytes memory) {
        bytes memory body = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            body[i] = "x";
        }
        return abi.encode(string(body));
    }

    /// @notice A 32-byte word with non-zero bits above bit 160 — decodable as `uint256`, NOT as `address`.
    function dirtyAddress(address a) internal pure returns (bytes memory) {
        return abi.encodePacked(uint256(uint160(a)) | (uint256(1) << 200));
    }
}
