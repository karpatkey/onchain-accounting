// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {StaticCallLib} from "src/utils/StaticCallLib.sol";
import {RawReplier, RawReplyLib} from "test/mocks/RawReplier.sol";

/// @notice Calls the library from a fresh external frame so `gasleft()` deltas measure the probe and nothing else.
contract StaticCallHarness {
    function probeUint(address target, bytes memory data) external view returns (bool ok, uint256 result) {
        return StaticCallLib.safeUint(target, data);
    }

    function probeAddr(address target, bytes memory data) external view returns (bool ok, address result) {
        return StaticCallLib.safeAddr(target, data);
    }

    /// @notice Gas consumed by one {StaticCallLib.safeUint}, measured from inside the calling frame.
    function gasForUint(address target, bytes memory data) external view returns (uint256 used) {
        uint256 before = gasleft();
        StaticCallLib.safeUint(target, data);
        used = before - gasleft();
    }

    /// @notice Gas consumed by one {StaticCallLib.safeAddr}, measured from inside the calling frame.
    function gasForAddr(address target, bytes memory data) external view returns (uint256 used) {
        uint256 before = gasleft();
        StaticCallLib.safeAddr(target, data);
        used = before - gasleft();
    }
}

/// @title StaticCallLibTest
/// @notice Pins the three properties that make {StaticCallLib}'s "never reverts" claim true — a bounded gas
///         stipend, a fixed 32-byte output window, and mask-don't-decode — plus the legacy `ok`/short-return
///         semantics the two live call sites depend on.
/// @dev Every guard here is load-bearing: reverting it in the library makes the matching test fail. The two gas
///      ceilings are deliberately far below what the unguarded shapes cost (see the comment on each) and far
///      above what the guarded shape actually spends, so they discriminate without being flaky.
contract StaticCallLibTest is Test {
    StaticCallHarness internal harness;
    RawReplier internal replier;

    /// @dev Ceiling for a probe whose callee loops forever. Without `{gas: PROBE_GAS}` the callee takes 63/64 of
    ///      everything the caller holds, which in this test is millions.
    uint256 internal constant BURN_CEILING = 200_000;

    /// @dev Ceiling for a probe whose callee replies with {BIG_REPLY_BYTES}. Without the fixed 32-byte output
    ///      window the caller pays a second, quadratic memory expansion to `returndatacopy` the whole reply.
    uint256 internal constant COPY_CEILING = 90_000;

    /// @dev Big enough that copying it is unmistakable in the gas trace, small enough that the callee can still
    ///      afford to produce it inside `PROBE_GAS`.
    uint256 internal constant BIG_REPLY_BYTES = 150_000;

    function setUp() public {
        harness = new StaticCallHarness();
        replier = new RawReplier();
    }

    // ---------------------------------------------------------------------------------------------------------
    // Control cases — a compliant callee must keep decoding exactly as before.
    // ---------------------------------------------------------------------------------------------------------

    function test_safeUint_canonicalWord_decodes() public {
        replier.stageReturn(abi.encode(uint256(12_345)));
        (bool ok, uint256 result) = harness.probeUint(address(replier), abi.encodeWithSignature("anything()"));
        assertTrue(ok, "canonical uint should succeed");
        assertEq(result, 12_345, "canonical uint should decode");
    }

    function test_safeAddr_canonicalWord_decodes() public {
        address expected = address(0xBEEF);
        replier.stageReturn(abi.encode(expected));
        (bool ok, address result) = harness.probeAddr(address(replier), abi.encodeWithSignature("anything()"));
        assertTrue(ok, "canonical address should succeed");
        assertEq(result, expected, "canonical address should decode");
    }

    // ---------------------------------------------------------------------------------------------------------
    // Property 3 — mask, don't `abi.decode`.
    // ---------------------------------------------------------------------------------------------------------

    /// @dev The load-bearing case for `safeAddr`. `abi.decode(ret, (address))` emits a validator that reverts on
    ///      bits above 160, in the CALLING frame, so no `try`/`catch` upstream can absorb it. Restore the
    ///      `abi.decode` form in the library and this test reverts instead of returning.
    function test_safeAddr_dirtyUpperBits_masksInsteadOfReverting() public {
        address expected = address(0xCAFE);
        replier.stageReturn(RawReplyLib.dirtyAddress(expected));
        (bool ok, address result) = harness.probeAddr(address(replier), abi.encodeWithSignature("anything()"));
        assertTrue(ok, "dirty address must not fail the call");
        assertEq(result, expected, "dirty upper bits must be masked off, not decoded");
    }

    /// @dev Same payload through `safeUint`: nothing is masked there, so the full word survives. Proves the two
    ///      readers share a probe but not a decode.
    function test_safeUint_dirtyUpperBits_keepsFullWord() public {
        address embedded = address(0xCAFE);
        replier.stageReturn(RawReplyLib.dirtyAddress(embedded));
        (bool ok, uint256 result) = harness.probeUint(address(replier), abi.encodeWithSignature("anything()"));
        assertTrue(ok, "dirty word must not fail the call");
        assertEq(result, uint256(uint160(embedded)) | (uint256(1) << 200), "uint reader must not mask");
    }

    // ---------------------------------------------------------------------------------------------------------
    // Property 1 — the gas stipend.
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Drop `{gas: PROBE_GAS}` from the library and this fails: the infinite loop consumes 63/64 of the
    ///      millions of gas the test frame holds, which is precisely how one broken instance starves the reads
    ///      that come after it.
    function test_safeUint_infiniteLoopCallee_isGasCapped() public {
        replier.stageBurnGas();
        uint256 used = harness.gasForUint{gas: 5_000_000}(address(replier), abi.encodeWithSignature("anything()"));
        assertLt(used, BURN_CEILING, "probe must not forward more than its stipend");
    }

    function test_safeAddr_infiniteLoopCallee_isGasCapped() public {
        replier.stageBurnGas();
        uint256 used = harness.gasForAddr{gas: 5_000_000}(address(replier), abi.encodeWithSignature("anything()"));
        assertLt(used, BURN_CEILING, "probe must not forward more than its stipend");
    }

    /// @dev A starved callee is a failed read, not a reverting one — the whole point of the helper.
    function test_safeUint_infiniteLoopCallee_failsOpen() public {
        replier.stageBurnGas();
        (bool ok, uint256 result) = harness.probeUint(address(replier), abi.encodeWithSignature("anything()"));
        assertFalse(ok, "a starved callee reports failure");
        assertEq(result, 0, "a starved callee yields no value");
    }

    // ---------------------------------------------------------------------------------------------------------
    // Property 2 — the fixed 32-byte output window.
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Restore the `(bool ok, bytes memory ret)` assignment in the library and this fails: solc
    ///      `returndatacopy`s all {BIG_REPLY_BYTES} into fresh memory, and the caller pays a second quadratic
    ///      memory expansion on top of what the callee already spent. Staged on the SUCCESS path deliberately —
    ///      a revert bomb of the same size out-of-gasses inside the callee once the stipend is capped, leaving
    ///      `returndatasize() == 0` and nothing to copy.
    function test_safeUint_hugeSuccessReply_isNotCopied() public {
        replier.stageBigReturn(BIG_REPLY_BYTES);
        uint256 used = harness.gasForUint(address(replier), abi.encodeWithSignature("anything()"));
        assertLt(used, COPY_CEILING, "reply size must not reach the caller's memory");
    }

    function test_safeAddr_hugeSuccessReply_isNotCopied() public {
        replier.stageBigReturn(BIG_REPLY_BYTES);
        uint256 used = harness.gasForAddr(address(replier), abi.encodeWithSignature("anything()"));
        assertLt(used, COPY_CEILING, "reply size must not reach the caller's memory");
    }

    /// @dev An oversized reply still decodes from its first word, so the cheap path is not a silent drop.
    function test_safeUint_oversizedReply_decodesFirstWord() public {
        replier.stageReturn(abi.encodePacked(uint256(777), uint256(888), uint256(999)));
        (bool ok, uint256 result) = harness.probeUint(address(replier), abi.encodeWithSignature("anything()"));
        assertTrue(ok, "oversized reply should still succeed");
        assertEq(result, 777, "first word is the value");
    }

    // ---------------------------------------------------------------------------------------------------------
    // Legacy semantics the two live call sites rely on.
    // ---------------------------------------------------------------------------------------------------------

    /// @dev `ok` is the raw success flag and does NOT fold in the length check — Convex's `_pidLpToken` reads the
    ///      word itself precisely because of this.
    function test_shortReply_reportsOkWithZeroValue() public {
        replier.stageReturn(hex"00112233");
        (bool okU, uint256 u) = harness.probeUint(address(replier), abi.encodeWithSignature("anything()"));
        assertTrue(okU, "a short reply is still a successful call");
        assertEq(u, 0, "a short reply yields no uint");

        (bool okA, address a) = harness.probeAddr(address(replier), abi.encodeWithSignature("anything()"));
        assertTrue(okA, "a short reply is still a successful call");
        assertEq(a, address(0), "a short reply yields no address");
    }

    /// @dev A raw staticcall has no `extcodesize` precheck, so a code-less target succeeds with empty
    ///      returndata. This is why a `code.length` guard in front of these helpers would be dead code.
    function test_codelessTarget_succeedsWithNoValue() public view {
        address codeless = address(0xDEAD);
        assertEq(codeless.code.length, 0, "target must have no code");

        (bool okU, uint256 u) = harness.probeUint(codeless, abi.encodeWithSignature("anything()"));
        assertTrue(okU, "staticcall to a code-less address succeeds");
        assertEq(u, 0, "code-less target yields no uint");

        (bool okA, address a) = harness.probeAddr(codeless, abi.encodeWithSignature("anything()"));
        assertTrue(okA, "staticcall to a code-less address succeeds");
        assertEq(a, address(0), "code-less target yields no address");
    }

    /// @dev A plain revert is reported, not propagated.
    function test_revertingCallee_failsOpen() public {
        replier.stageRevert(0);
        (bool okU, uint256 u) = harness.probeUint(address(replier), abi.encodeWithSignature("anything()"));
        assertFalse(okU, "a reverting callee reports failure");
        assertEq(u, 0, "a reverting callee yields no uint");

        (bool okA, address a) = harness.probeAddr(address(replier), abi.encodeWithSignature("anything()"));
        assertFalse(okA, "a reverting callee reports failure");
        assertEq(a, address(0), "a reverting callee yields no address");
    }

    /// @dev A revert payload large enough to matter is bounded by the same stipend, from the callee side.
    function test_revertBomb_isGasCapped() public {
        replier.stageRevert(3_000_000);
        uint256 used = harness.gasForUint{gas: 5_000_000}(address(replier), abi.encodeWithSignature("anything()"));
        assertLt(used, BURN_CEILING, "a revert bomb must not escape the stipend");
    }
}
