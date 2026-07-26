// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {LabelLib} from "src/balances/LabelLib.sol";

/// @notice Exposes the library's internal functions as externals so a test can staticcall them and observe a revert
///         instead of aborting the test itself.
contract LabelLibHarness {
    function readName(address token, string memory fallbackStr) external view returns (string memory) {
        return LabelLib.name(token, fallbackStr);
    }

    function readSymbol(address token, string memory fallbackStr) external view returns (string memory) {
        return LabelLib.symbol(token, fallbackStr);
    }
}

/// @notice A well-behaved ERC20 metadata pair.
contract GoodToken {
    function name() external pure returns (string memory) {
        return "Good Token";
    }

    function symbol() external pure returns (string memory) {
        return "GOOD";
    }
}

/// @notice `name()`/`symbol()` return the empty string — normalised to `fallbackStr`.
contract EmptyStringToken {
    function name() external pure returns (string memory) {
        return "";
    }

    function symbol() external pure returns (string memory) {
        return "";
    }
}

/// @notice `name()`/`symbol()` revert — the only class a bare `try`/`catch` ever handled.
contract RevertingToken {
    error Nope();

    fallback() external {
        revert Nope();
    }
}

/// @notice Succeeds returning ZERO bytes — an ERC-1967 proxy whose implementation slot has no code behaves this way.
contract EmptyReturndataToken {
    fallback() external {
        assembly {
            return(0, 0)
        }
    }
}

/// @notice Returns a `bytes32` rather than a `string` — MKR-style legacy metadata.
contract Bytes32Token {
    function name() external pure returns (bytes32) {
        return "Legacy";
    }

    function symbol() external pure returns (bytes32) {
        return "LGCY";
    }
}

/// @notice Returns a hand-built ABI envelope so a test can drive the exact head/payload shape.
contract RawEnvelopeToken {
    uint256 private immutable OFFSET_WORD;
    uint256 private immutable LEN_WORD;
    bytes private payload;

    constructor(uint256 offsetWord_, uint256 lenWord_, bytes memory payload_) {
        OFFSET_WORD = offsetWord_;
        LEN_WORD = lenWord_;
        payload = payload_;
    }

    fallback() external {
        bytes memory out = abi.encodePacked(OFFSET_WORD, LEN_WORD, payload);
        assembly {
            return(add(out, 0x20), mload(out))
        }
    }
}

/// @notice Consumes whatever gas it is given, then out-of-gasses.
contract GasBurnerToken {
    uint256 public sink;

    fallback() external {
        for (uint256 i = 0; true; ++i) {
            sink = i;
        }
    }
}

/// @title LabelLib unit tests
/// @notice LabelLib must return the caller's `fallbackStr` for every failure class and NEVER revert — it is the shared
///         metadata reader behind `positionLabels` across the meta, plain and assisted adapter families, and a revert
///         there is swallowed by `NAVCalculator._safeStringArray` into an empty label array (losing the category too).
contract LabelLibTest is Test {
    LabelLibHarness internal h;

    function setUp() public {
        h = new LabelLibHarness();
    }

    /// @dev Staticcalls through the harness so a propagated revert is observable rather than fatal.
    function _tryName(address token, string memory fb) internal view returns (bool ok, string memory out) {
        bytes memory ret;
        (ok, ret) = address(h).staticcall(abi.encodeCall(LabelLibHarness.readName, (token, fb)));
        if (ok) out = abi.decode(ret, (string));
    }

    function _trySymbol(address token, string memory fb) internal view returns (bool ok, string memory out) {
        bytes memory ret;
        (ok, ret) = address(h).staticcall(abi.encodeCall(LabelLibHarness.readSymbol, (token, fb)));
        if (ok) out = abi.decode(ret, (string));
    }

    function test_goodToken_returnsMetadata() public {
        address t = address(new GoodToken());
        assertEq(h.readName(t, "?"), "Good Token");
        assertEq(h.readSymbol(t, "?"), "GOOD");
    }

    function test_noCode_returnsFallback() public view {
        assertEq(h.readName(address(0xdead), "?"), "?");
        assertEq(h.readSymbol(address(0xdead), ""), "");
    }

    function test_reverting_returnsFallback() public {
        address t = address(new RevertingToken());
        assertEq(h.readName(t, "?"), "?");
        assertEq(h.readSymbol(t, "fb"), "fb");
    }

    function test_emptyString_normalisedToFallback() public {
        address t = address(new EmptyStringToken());
        assertEq(h.readName(t, "?"), "?");
        assertEq(h.readSymbol(t, "?"), "?");
    }

    /// @notice Class 3: succeeds, returndata undecodable. This reverted before the ABI-head guard.
    function test_emptyReturndata_returnsFallback() public {
        address t = address(new EmptyReturndataToken());
        (bool okN, string memory n) = _tryName(t, "?");
        (bool okS, string memory s) = _trySymbol(t, "?");
        assertTrue(okN, "name must not revert on empty returndata");
        assertTrue(okS, "symbol must not revert on empty returndata");
        assertEq(n, "?");
        assertEq(s, "?");
    }

    /// @notice Class 3: a `bytes32` name/symbol (MKR-style) is 32 bytes, so it cannot be a `string` envelope.
    function test_bytes32Metadata_returnsFallback() public {
        address t = address(new Bytes32Token());
        (bool okN, string memory n) = _tryName(t, "?");
        (bool okS,) = _trySymbol(t, "?");
        assertTrue(okN, "name must not revert on a bytes32 return");
        assertTrue(okS, "symbol must not revert on a bytes32 return");
        assertEq(n, "?");
    }

    function test_nonCanonicalOffset_returnsFallback() public {
        address t = address(new RawEnvelopeToken(type(uint256).max, 4, "abcd"));
        (bool ok, string memory n) = _tryName(t, "?");
        assertTrue(ok, "must not revert on an absurd offset word");
        assertEq(n, "?");
    }

    /// @notice A declared length longer than the bytes actually returned — the over-read shape.
    function test_truncatedPayload_returnsFallback() public {
        address t = address(new RawEnvelopeToken(0x20, 64, hex"6161616161616161"));
        (bool ok, string memory n) = _tryName(t, "?");
        assertTrue(ok, "must not revert on a truncated payload");
        assertEq(n, "?");
    }

    /// @notice Unpadded payloads whose declared length exactly matches the tail must DECODE, not fall back — this is
    ///         the sweep proving the raw-length bound is sufficient and not over-tight.
    function test_unpaddedExactLengths_decode() public {
        for (uint256 len = 1; len <= 96; ++len) {
            bytes memory payload = new bytes(len);
            for (uint256 i; i < len; ++i) {
                payload[i] = "a";
            }
            address t = address(new RawEnvelopeToken(0x20, len, payload));
            (bool ok, string memory n) = _tryName(t, "?");
            assertTrue(ok, "must not revert on an unpadded exact-length payload");
            assertEq(bytes(n).length, len, "unpadded exact-length payload must decode verbatim");
        }
    }

    /// @notice The length cap, pinned in both directions.
    function test_lengthCapBoundary() public {
        bytes memory at = new bytes(256);
        bytes memory over = new bytes(257);
        for (uint256 i; i < 257; ++i) {
            if (i < 256) at[i] = "a";
            over[i] = "a";
        }
        address okVault = address(new RawEnvelopeToken(0x20, 256, at));
        address tooLong = address(new RawEnvelopeToken(0x20, 257, over));

        assertEq(bytes(h.readName(okVault, "?")).length, 256, "256 bytes accepted");
        assertEq(h.readName(tooLong, "?"), "?", "257 bytes rejected");
    }

    /// @notice A gas-burning metadata call must be bounded by the stipend, not consume the caller's budget.
    /// @dev Fails without `staticcall{gas: METADATA_READ_GAS}`.
    function test_gasBurner_boundedAndReturnsFallback() public {
        address t = address(new GasBurnerToken());
        uint256 before = gasleft();
        (bool ok, string memory n) = _tryName(t, "?");
        uint256 used = before - gasleft();

        assertTrue(ok, "must not revert on a gas-burning metadata call");
        assertEq(n, "?");
        assertLt(used, 400_000, "gas-burning metadata call must stay bounded by the stipend");
    }

    /// @notice The `"?"` placeholder convention used by `_joinTokenSymbols` and `"" `single-leaf collapse must both be
    ///         returned verbatim — callers depend on the distinction.
    function test_fallbackStringPassedThroughVerbatim() public {
        address t = address(new RevertingToken());
        assertEq(h.readSymbol(t, "?"), "?");
        assertEq(h.readSymbol(t, ""), "");
        assertEq(h.readSymbol(t, "custom fallback"), "custom fallback");
    }
}
