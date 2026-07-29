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

    function probe(address target, bytes memory data) external view returns (bool ok, bool hasWord, uint256 word) {
        return StaticCallLib.probeWord(target, data);
    }

    function probeAddrStrict(address target, bytes memory data)
        external
        view
        returns (bool ok, address result, bool malformed)
    {
        return StaticCallLib.safeAddrStrict(target, data);
    }

    /// @notice Two probes in ONE frame, returning only the second — the only way to observe whether the first
    ///         probe's reply is still resident in the shared output window when the second returns nothing.
    function probeTwice(address first, bytes memory firstData, address second, bytes memory secondData)
        external
        view
        returns (bool ok, bool hasWord, uint256 word)
    {
        StaticCallLib.probeWord(first, firstData);
        return StaticCallLib.probeWord(second, secondData);
    }

    function probeMetered(address target, bytes memory data)
        external
        view
        returns (bool ok, bool hasWord, uint256 word, bool starved, uint256 budget, uint256 consumed)
    {
        return StaticCallLib.probeWordMetered(target, data);
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

    /// @notice The strict reader REJECTS a dirty word where {safeAddr} masks it.
    /// @dev Both policies ship because the right one is per call site. Masking favours liveness; rejecting
    ///      favours a clean sentinel, and is required wherever `address(0)` is itself a meaningful answer —
    ///      Euler's `EVC()` ("cannot classify") and Uniswap V2's `feeTo()` ("no protocol fee", which drops the
    ///      dilution term and RAISES the reported LP share). Swap `safeAddrStrict` for `safeAddr` at either site
    ///      and the caller silently manufactures that sentinel out of garbage.
    function test_safeAddrStrict_dirtyUpperBits_rejected() public {
        address embedded = address(0xCAFE);
        replier.stageReturn(RawReplyLib.dirtyAddress(embedded));

        (bool ok, address result, bool malformed) =
            harness.probeAddrStrict(address(replier), abi.encodeWithSignature("anything()"));
        assertTrue(ok, "the call itself succeeded");
        assertTrue(malformed, "a full word with dirty upper bits is BROKEN, not absent");
        assertEq(result, address(0), "a rejected word yields no address");

        // The masking reader, same payload, deliberately disagrees.
        (, address masked) = harness.probeAddr(address(replier), abi.encodeWithSignature("anything()"));
        assertEq(masked, embedded, "safeAddr still masks - the two policies must stay distinguishable");
    }

    /// @notice A clean word is accepted identically by both readers.
    function test_safeAddrStrict_cleanWord_accepted() public {
        address expected = address(0xBEEF);
        replier.stageReturn(abi.encode(expected));

        (bool ok, address result, bool malformed) =
            harness.probeAddrStrict(address(replier), abi.encodeWithSignature("anything()"));
        assertTrue(ok, "clean address should succeed");
        assertFalse(malformed, "a clean word is not malformed");
        assertEq(result, expected, "clean address decodes");
    }

    /// @notice `malformed` separates "broken" from "absent" — and a genuine zero from a failed read.
    /// @dev The three outcomes a strict caller must tell apart, all of which yield `result == address(0)`:
    ///      a callee genuinely answering `address(0)` (ok, not malformed), a callee that reverted or answered
    ///      short (not ok / ok-but-no-word, NOT malformed — absent, so callers treat the getter as missing), and
    ///      a callee that answered with a full non-address word (malformed — genuinely broken). Collapsing the
    ///      middle case into `malformed` is the mistake this test exists to prevent: it makes Uniswap V2 drop a
    ///      whole LP position over a code-less factory.
    function test_safeAddrStrict_realZero_distinguishableFromFailure() public {
        replier.stageReturn(abi.encode(address(0)));
        (bool zeroOk, address zeroResult, bool zeroMalformed) =
            harness.probeAddrStrict(address(replier), abi.encodeWithSignature("anything()"));
        assertTrue(zeroOk, "a genuine zero is a successful read");
        assertFalse(zeroMalformed, "a genuine zero is not malformed");
        assertEq(zeroResult, address(0), "and its value is zero");

        replier.stageRevert(0);
        (bool failOk, address failResult, bool failMalformed) =
            harness.probeAddrStrict(address(replier), abi.encodeWithSignature("anything()"));
        assertFalse(failOk, "a revert is not a successful read");
        assertFalse(failMalformed, "a revert is ABSENT, not broken - callers must not drop over it");
        assertEq(failResult, address(0), "same value, different meaning");
    }

    /// @notice A short reply carries no address, however its bytes happen to land.
    function test_safeAddrStrict_shortReply_rejected() public {
        replier.stageReturn(hex"00112233");
        (bool ok, address result, bool malformed) =
            harness.probeAddrStrict(address(replier), abi.encodeWithSignature("anything()"));
        assertTrue(ok, "a short reply is still a successful call");
        assertFalse(malformed, "a short reply is ABSENT, not broken - see the note on safeAddrStrict");
        assertEq(result, address(0), "short reply yields no address");
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
    ///
    ///      The marker assertion is what keeps this test honest. A gas ceiling alone passes VACUOUSLY the moment
    ///      the callee can no longer afford to emit the reply — lower `PROBE_GAS` below the ~57k this reply costs
    ///      and `returndatasize()` collapses to 0, `used` drops to roughly the stipend, and the ceiling still
    ///      holds while the output window under test is never exercised. Asserting the marker arrived means the
    ///      reply must genuinely have been produced AND discarded.
    function test_safeUint_hugeSuccessReply_isNotCopied() public {
        replier.stageBigReturn(BIG_REPLY_BYTES);
        (bool ok, uint256 result) = harness.probeUint(address(replier), abi.encodeWithSignature("anything()"));
        assertTrue(ok, "the big reply must actually have been produced");
        assertEq(result, replier.BIG_RETURN_MARKER(), "the big reply must have reached the reader's first word");

        uint256 used = harness.gasForUint(address(replier), abi.encodeWithSignature("anything()"));
        assertLt(used, COPY_CEILING, "reply size must not reach the caller's memory");
    }

    function test_safeAddr_hugeSuccessReply_isNotCopied() public {
        replier.stageBigReturn(BIG_REPLY_BYTES);
        (bool ok, address result) = harness.probeAddr(address(replier), abi.encodeWithSignature("anything()"));
        assertTrue(ok, "the big reply must actually have been produced");
        assertEq(result, address(uint160(replier.BIG_RETURN_MARKER())), "the big reply must have reached the reader");

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

    /// @dev `ok` is the raw success flag and does NOT fold in the length check — Convex's `_lpTokenOf` gates on
    ///      `hasWord` precisely because of this.
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

    /// @dev A callee ATTEMPTING a huge revert payload is bounded by the same stipend, from the callee side.
    ///      Note precisely what this does and does not prove: 3 MB of revert data needs ~17.4M gas of callee
    ///      memory expansion, so under `PROBE_GAS` the callee MemoryOOGs before emitting anything and
    ///      `returndatasize()` is 0. So this pins the stipend, NOT the output window — nothing is ever copied.
    ///      Revert-payload handling proper is covered by {test_revertWithFullWord_isNotMistakenForAValue}, which
    ///      stages a payload small enough for the callee to actually emit.
    function test_revertBomb_isGasCapped() public {
        replier.stageRevert(3_000_000);
        uint256 used = harness.gasForUint{gas: 5_000_000}(address(replier), abi.encodeWithSignature("anything()"));
        assertLt(used, BURN_CEILING, "a revert bomb must not escape the stipend");
    }

    /// @notice A revert carrying ≥ 32 bytes must never be mistaken for a returned value.
    /// @dev This is the load-bearing test for the `ok &&` conjunct in `hasWord`, and the one case the rest of the
    ///      suite structurally cannot reach: every other failure staging here yields `returndatasize() == 0`
    ///      (a zero-byte revert, or a callee that OOGs before emitting), so `size >= 32` is already false and
    ///      `ok` never has to carry the check. Delete `ok &&` and the whole suite stays green without this test.
    ///
    ///      The scenario is ordinary, not exotic: any callee reverting with a standard `Error(string)` produces
    ///      100+ bytes, which the EVM copies into the output window exactly as a successful reply would. Convex's
    ///      `_lpTokenOf` DISCARDS `ok` and gates solely on `hasWord`, so if `ok` ever stopped being folded in, the
    ///      first word of a revert payload would be handed to `Booster.poolInfo(pid)` as a pool id.
    function test_revertWithFullWord_isNotMistakenForAValue() public {
        // A plausible-looking pid plus filler, mimicking an `Error(string)` head. Small enough that the callee
        // can genuinely emit it under the stipend — a bomb would OOG and prove nothing.
        replier.stageRevertWith(abi.encodePacked(uint256(42), uint256(1), uint256(0)));

        (bool ok, bool hasWord, uint256 word) = harness.probe(address(replier), abi.encodeWithSignature("anything()"));
        assertFalse(ok, "a reverting callee reports failure");
        assertFalse(hasWord, "revert data is not a returned word");
        assertEq(word, 0, "a revert payload must never surface as a value");

        (bool okU, uint256 u) = harness.probeUint(address(replier), abi.encodeWithSignature("anything()"));
        assertFalse(okU, "a reverting callee reports failure");
        assertEq(u, 0, "revert payload must not decode as a uint");

        (bool okA, address a) = harness.probeAddr(address(replier), abi.encodeWithSignature("anything()"));
        assertFalse(okA, "a reverting callee reports failure");
        assertEq(a, address(0), "revert payload must not decode as an address");
    }

    /// @notice `word` is zeroed when `!hasWord`, so an empty reply cannot surface the PREVIOUS probe's value.
    /// @dev The output window at 0x00 is not cleared between probes: on an empty reply the EVM writes nothing,
    ///      leaving the prior probe's word in place. Within one `getAdapterPositions` sweep that residue is the
    ///      preceding instance's real value — a plausible-looking wrong answer rather than obvious garbage.
    ///      Drop the `if (hasWord)` assignment in the library and this fails with the marker still resident.
    function test_emptyReply_doesNotLeakPreviousProbesWord() public {
        replier.stageReturn(abi.encode(uint256(0xC0FFEE)));
        (, bool firstHasWord, uint256 firstWord) = harness.probe(address(replier), abi.encodeWithSignature("a()"));
        assertTrue(firstHasWord, "control: the first probe must land a word");
        assertEq(firstWord, 0xC0FFEE, "control: the first probe's word");

        // Same frame, same scratch slot — a code-less target succeeds with zero returndata and writes nothing.
        (bool ok, bool hasWord, uint256 word) = harness.probeTwice(
            address(replier), abi.encodeWithSignature("a()"), address(0xDEAD), abi.encodeWithSignature("b()")
        );
        assertTrue(ok, "staticcall to a code-less address succeeds");
        assertFalse(hasWord, "an empty reply carries no word");
        assertEq(word, 0, "residue from the previous probe must not surface");
    }

    // ---------------------------------------------------------------------------------------------------------
    // probeWordMetered — the accounting-read helper, which does NOT share the three properties above.
    // ---------------------------------------------------------------------------------------------------------

    /// @notice A starved callee is reported `starved`, separately from `ok`.
    /// @dev The distinction the helper exists for: {safeUint} folds "reverted" and "ran out of gas" into one
    ///      `false`, and they deserve opposite treatment at an accounting call site.
    function test_probeWordMetered_starvedCallee_reportsStarvedNotJustFailure() public {
        replier.stageBurnGas();
        (bool ok, bool hasWord,, bool starved,,) =
            harness.probeMetered{gas: 2_000_000}(address(replier), abi.encodeWithSignature("anything()"));
        assertFalse(ok, "a starved callee did not answer");
        assertFalse(hasWord, "and carries no word");
        assertTrue(starved, "and must be distinguishable from a revert");
    }

    /// @notice The reported `budget` is the calling FRAME, not the 63/64 slice that was forwarded.
    /// @dev Pins the OPERANDS, which is a weaker property than it first looks, and the distinction is worth
    ///      stating because an earlier version of this docstring claimed the stronger one. `budget`/`consumed`
    ///      are surfaced to a consumer in `EulerVaultsMetaBalanceAdapter.DebtReadGasExhausted`, so a reader
    ///      diagnosing a starved instance needs them to describe the frame rather than a slice of it. Mutating
    ///      the library to report `stipend` here turns this red.
    ///
    ///      It does NOT pin the classification. Measured, not argued: changing the library to
    ///      `exhausted(stipend, consumed)` — the actual silent-drop regression — leaves this test and every
    ///      other test in this file GREEN, because a callee that burns its whole stipend is classified starved
    ///      either way. Only `EulerVaultsMetaBalanceAdapter.test_debtOf_burnInsideTheReopenedBand_keepsItsLeg`
    ///      catches that, because the band it opens is reachable only through the nesting the adapter provides
    ///      and cannot be observed from a single library frame. Do not treat this file as covering it.
    ///
    ///      The ratio arithmetic, for the operand property: a callee that burns everything it was given
    ///      consumes the whole stipend, so `consumed/budget` is ~63/64 = 0.984 when `budget` is the frame and
    ///      ~1.0 when it is the stipend. Testing below 0.99 separates the two.
    function test_probeWordMetered_budgetIsTheFrameNotTheForwardedStipend() public {
        replier.stageBurnGas();
        (,,, bool starved, uint256 budget, uint256 consumed) =
            harness.probeMetered{gas: 2_000_000}(address(replier), abi.encodeWithSignature("anything()"));
        assertTrue(starved, "control: the callee must actually have been starved");
        assertLt(consumed, budget, "the frame always exceeds what the call could consume");
        assertLt(consumed * 1000, budget * 990, "budget must be the FRAME (ratio ~0.984), not the stipend (~1.0)");
    }

    /// @notice A cheap genuine revert is NOT starvation, however loudly it fails.
    /// @dev The EulerEarn case, and the reason `starved` cannot simply be `!ok`. If this goes red the live
    ///      mainnet configuration — aggregators with no `debtOf` — starts reverting instead of failing open.
    function test_probeWordMetered_cheapRevert_isNotStarved() public {
        replier.stageRevert(0);
        (bool ok,,, bool starved,,) =
            harness.probeMetered{gas: 2_000_000}(address(replier), abi.encodeWithSignature("anything()"));
        assertFalse(ok, "a reverting callee reports failure");
        assertFalse(starved, "but it ANSWERED, so it must not be called starved");
    }

    /// @notice The success path is unchanged from {probeWord}: a full word is returned and nothing is starved.
    function test_probeWordMetered_successfulWord_isReturnedAndNotStarved() public {
        replier.stageReturn(abi.encode(uint256(0xC0FFEE)));
        (bool ok, bool hasWord, uint256 word, bool starved,,) =
            harness.probeMetered{gas: 2_000_000}(address(replier), abi.encodeWithSignature("anything()"));
        assertTrue(ok, "a well-formed reply succeeds");
        assertTrue(hasWord, "and carries a full word");
        assertEq(word, 0xC0FFEE, "which is the value");
        assertFalse(starved, "a successful call is never starved");
    }

    /// @notice A short successful reply yields no word and is not starvation either.
    /// @dev Pins the deliberate second policy: this route to a missing debt leg stays fail-open, because a
    ///      callee's returndata size is not evidence of anything the way its gas cost is.
    function test_probeWordMetered_shortReply_hasNoWordAndIsNotStarved() public {
        replier.stageReturn(abi.encodePacked(uint128(1)));
        (bool ok, bool hasWord, uint256 word, bool starved,,) =
            harness.probeMetered{gas: 2_000_000}(address(replier), abi.encodeWithSignature("anything()"));
        assertTrue(ok, "a short reply still succeeds");
        assertFalse(hasWord, "but carries no full word");
        assertEq(word, 0, "and yields no value");
        assertFalse(starved, "and is not starvation");
    }
}
