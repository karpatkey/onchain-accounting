// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @title GasStipendLib
/// @author KPK
/// @notice The single definition of "did this call run out of gas, or did it answer?" — the stipend a fan-out
///         forwards to one child, and the test that separates an out-of-gas from a revert afterwards.
/// @dev Exists because that question is asked in two places, one frame apart, and the two must give the same
///      answer: `PriceFeedLib._getAdapterPositions` asks it of a balance adapter, and `MetaBalanceAdapter`
///      asks it of one governed instance. Both sit on a `try`/`catch` that cannot tell the two failures apart on
///      its own, and getting it wrong in the lenient direction drops a position's legs — a dropped *debt* leg
///      RAISES the reported NAV. Two copies of a threshold is how the two paths drift apart, so there is one.
///
///      **Why a threshold at all, rather than "consumed == forwarded".** A starved callee never quite spends
///      everything it was given. Gas runs out inside whatever the callee is itself reading, not in the callee's
///      own frame: that sub-call takes 63/64 under EIP-150, out-of-gasses, and the callee's own reserve comes
///      back unspent when it bubbles the revert. One level of nesting consumes ~63/64 of the stipend, two
///      ~0.969, three ~0.954 — each level leaves another reserve behind. An exact test sees the shortfall and
///      calls a starved callee healthy, which is the silent failure; and no fixed fraction is exact either, so
///      {SLACK_DIVISOR} narrows the silent window rather than closing it.
///
///      Being wrong the other way is cheap: a busy callee that reverts after real work gets read as exhausted
///      and produces a loud, retryable failure instead of a wrong number.
///
///      **What this cannot see at all.** The question is only asked when the callee BUBBLES its out-of-gas. A
///      callee that wraps its own read in `try`/`catch` — or in a fail-open low-level staticcall — absorbs the
///      out-of-gas itself, carries on with the ~1/64 the EVM handed back, and RETURNS SUCCESSFULLY with a leg
///      missing. No classifier upstream is reached, because nothing failed from where it is standing. That
///      residual is a property of each adapter's internal error handling, not of this threshold, and it is why
///      "narrows the silent window" is the accurate claim rather than "closes it".
library GasStipendLib {
    /// @notice Fraction of the stipend a failed call may leave unspent and still count as exhausted: `1/8`.
    /// @dev Covers nesting far past anything in this repo. Raising it (a smaller divisor) widens the window in
    ///      which a genuinely reverting callee is called exhausted — loud but wrong; lowering it re-opens the
    ///      silent window. The tests bracket it from both sides deliberately.
    uint256 private constant SLACK_DIVISOR = 8;

    /// @notice Gas to forward to one child of a fan-out, given what the calling frame currently holds.
    /// @dev Exactly what the EVM would forward on its own (63/64), computed explicitly so {exhausted} has a
    ///      figure to compare against rather than an implied one. Deliberately NOT a smaller fixed ceiling: a
    ///      ceiling makes exhaustion unrecoverable — the caller cannot escape it by supplying more gas — which
    ///      turns ordinary growth in a child's cost, and cheap third-party griefing of a per-account list, into
    ///      an outage that only a redeploy can lift.
    /// @param available `gasleft()` in the calling frame, read BEFORE this call.
    /// @return The stipend to pass as `{gas: …}`.
    function stipendFrom(uint256 available) internal pure returns (uint256) {
        return available - available / 64;
    }

    /// @notice Whether a failed call that was forwarded `stipend` and cost the caller `consumed` ran out of gas
    ///         rather than reverting with an answer.
    /// @dev `consumed` must be measured against the SAME `available` that produced `stipend` via {stipendFrom}.
    ///      That single-sample discipline is what fixes the sign of the slack: the caller-side overhead the
    ///      callee never spends lands on the `consumed` side, so a genuine out-of-gas always clears the
    ///      threshold. Re-sampling nearer the call inverts it and a real exhaustion reads as a benign revert.
    /// @param stipend The value returned by {stipendFrom} and passed as `{gas: …}`.
    /// @param consumed `available - gasleft()`, measured after the call returned.
    function exhausted(uint256 stipend, uint256 consumed) internal pure returns (bool) {
        return consumed >= stipend - stipend / SLACK_DIVISOR;
    }
}
