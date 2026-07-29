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

    /// @notice `n` reads inside ONE frame — the shape `_joinTokenSymbols` / `CurvePoolLib.coinSymbols` actually use.
    /// @dev The amplification only appears in-frame: memory grows monotonically across the reads. Calling the
    ///      single-read entry point N times from a test gives N fresh frames and hides the vector entirely.
    function readSymbolsInOneFrame(address token, uint256 n) external view returns (uint256) {
        for (uint256 i; i < n; ++i) {
            LabelLib.symbol(token, "?");
        }
        return n;
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

/// @notice Burns gas by pure COMPUTATION until out-of-gas — runs happily under `STATICCALL`.
/// @dev Deliberately computation-only. An earlier version looped on `sink = i`, but an `SSTORE` inside a `STATICCALL`
///      is a write-protection violation, so the callee aborted on its FIRST store and never executed the loop. That
///      still consumed all forwarded gas (an exceptional halt does), so the assertion held — but by a different
///      mechanism than the fixture claimed, and it left the actual run-until-OOG path untested. See
///      {WriteProtectionToken} for the abort shape, kept separately because it is a real and distinct token behaviour.
contract GasBurnerToken {
    fallback() external {
        assembly {
            for {} 1 {} { mstore(0x00, keccak256(0x00, 0x20)) }
        }
    }
}

/// @notice Attempts a state write inside the (static) metadata call — an exceptional halt that eats all forwarded gas.
contract WriteProtectionToken {
    uint256 public sink;

    fallback() external {
        sink = 1;
    }
}

/// @notice Returns 200 KB of SUCCESSFUL returndata — the caller-side amplification vector.
/// @dev A gas stipend alone does not bound this: the callee's own memory expansion for ~200 KB costs it about 95k, so
///      it fits inside the stipend, while the CALLER pays `returndatacopy` plus its own growing memory outside it.
contract BigReturnToken {
    fallback() external {
        assembly {
            return(0, 200000)
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
        (bool okS, string memory sy) = _trySymbol(t, "?");
        assertTrue(okN, "name must not revert on a bytes32 return");
        assertTrue(okS, "symbol must not revert on a bytes32 return");
        assertEq(n, "?");
        assertEq(sy, "?");
    }

    /// @notice Caller-side cost must be BOUNDED and LINEAR in the number of reads, whatever the token returns.
    /// @dev The regression guard for the vector a gas stipend alone does not cover. With the stipend but no explicit
    ///      `staticcall` output size, a token returning 200 KB of successful returndata cost 210,190 gas for one read
    ///      and 14,518,293 across eight sequential reads in one frame — quadratic, because the caller's memory grows
    ///      monotonically while the callee's expansion is paid from the stipend. A multi-token leaf does exactly these
    ///      sequential reads (`_joinTokenSymbols` over a Balancer pool, `CurvePoolLib.coinSymbols` over an 8-coin
    ///      pool), so this could starve a verbose NAV read. Bounding the copied returndata makes it flat.
    ///      Fails if the explicit output size is dropped from the `staticcall`.
    function test_oversizedReturndata_costIsBoundedAndLinear() public {
        address t = address(new BigReturnToken());

        uint256 g0 = gasleft();
        h.readSymbolsInOneFrame(t, 1);
        uint256 one = g0 - gasleft();

        uint256 g1 = gasleft();
        h.readSymbolsInOneFrame(t, 8);
        uint256 eight = g1 - gasleft();

        emit log_named_uint("1 read  in-frame", one);
        emit log_named_uint("8 reads in-frame", eight);

        assertEq(h.readSymbol(t, "?"), "?", "an oversized reply must fail open");
        // Linear, not quadratic. Unbounded this was 14.5M for 8 in-frame reads against ~210k for one; bounded it is
        // ~8x the single read. The 12x allowance leaves slack for the loop itself without admitting quadratic growth.
        assertLt(eight, one * 12, "cost must scale linearly in the number of in-frame reads");
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

    /// @notice A reply carrying a large zero-padded tail BEHIND a valid, in-cap string must still decode.
    /// @dev This is a REAL token shape, not a synthetic one. Curve's USD-metapool factory
    ///      (`0xB9fC157394Af804a3578134A6585C0dc9cc990d4`) deploys Vyper LP tokens whose `name()`/`symbol()` return a
    ///      fixed 4096-byte buffer behind a canonical head — FRAX3CRV-f, MIM-3LP3CRV-f, alUSD3CRV-f, LUSD3CRV-f, 12 of
    ///      the first 80 pools — carrying strings of 10-57 bytes. `abi.decode` accepts them and so did both of
    ///      LabelLib's predecessors; an earlier revision of this PR rejected them on their PADDING via a
    ///      `returndatasize()`-keyed check. Bounding on the copied extent instead fixes it.
    ///      Fails if the accept window is keyed on `size` again.
    function test_curveStyleOversizedCanonicalReply_stillDecodes() public {
        // Mirrors the real reply: canonical head, a 10-byte symbol, zero-padded out to a 4096-byte total.
        bytes memory tail = new bytes(4096 - 64);
        bytes memory sym = "FRAX3CRV-f";
        for (uint256 i; i < sym.length; ++i) {
            tail[i] = sym[i];
        }
        address t = address(new RawEnvelopeToken(0x20, sym.length, tail));
        (bool ok, string memory got) = _trySymbol(t, "?");
        assertTrue(ok, "must not revert on a 4096-byte canonical reply");
        assertEq(got, "FRAX3CRV-f", "an in-cap string must decode despite a large zero-padded tail");
    }

    /// @notice The cap boundary, and the MECHANISM that enforces it.
    /// @dev 256 is accepted because its payload lands exactly on the copy window (64 + 256 == MAX_RETURN_BYTES); 257 is
    ///      rejected because 64 + 257 exceeds it. There is deliberately no separate `len > MAX_METADATA_BYTES` clause —
    ///      it would be unreachable — so this test is what pins the cap.
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

    /// @notice A write-protection abort consumes everything forwarded, so the stipend must bound it too.
    function test_writeProtectionAbort_boundedAndReturnsFallback() public {
        address t = address(new WriteProtectionToken());
        uint256 before = gasleft();
        (bool ok, string memory n) = _tryName(t, "?");
        uint256 used = before - gasleft();

        assertTrue(ok, "must not revert when the callee aborts on a state write");
        assertEq(n, "?");
        assertLt(used, 400_000, "a write-protection abort must stay bounded by the stipend");
    }

    /// @notice A metadata call that burns gas by computation until OOG must be bounded by the stipend.
    /// @dev Fails without `staticcall{gas: METADATA_READ_GAS}` — this is the run-until-OOG path, which a storage-write
    ///      burner never reaches under `STATICCALL`.
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
