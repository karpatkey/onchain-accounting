// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {GasStipendLib} from "src/utils/GasStipendLib.sol";

/// @title StaticCallLib
/// @author KPK
/// @notice Best-effort view-call helpers for reading from possibly-noncompliant external contracts: a staticcall
///         that decodes a uint256/address and never reverts on a failed, short, oversized or undecodable call.
/// @dev Consolidates the staticcall+decode wrappers that were copy-pasted — and had begun to drift — across
///      ConvexCurveLPStakingMeta and UniswapV2PairLib (the call sites migrated so far).
///      NOTE: this is NOT yet the repo-wide single source of truth — other hand-rolled copies remain and do
///      not route through this library: CurvePoolLib, FluidVaultLib, CompoundV3CometLib, and AaveUmbrella.
///      Some even differ subtly (e.g. CurvePoolLib gates its address-decoding `lp_token()`/`minter()` reads on
///      `returndata.length == 32` where this library uses `>= 32`), so migrating them is a behavior-sensitive
///      follow-up, not a no-op. Internal library: inlined
///      into each caller (no separate deployment, no DELEGATECALL), so this is a maintainability change, not a
///      size one.
///
///      **Three properties make the "never reverts" claim actually hold**, and all three are load-bearing:
///
///      1. **Bounded gas** ({PROBE_GAS}). Without a stipend a callee that loops forever consumes 63/64 of
///         whatever the caller had, so one malformed instance starves every read that follows it — a fail-open
///         that silently drops later positions rather than a single value.
///      2. **A fixed 32-byte output area.** Assigning `(bool ok, bytes memory ret)` from a raw staticcall makes
///         solc `returndatacopy` the *entire* reply into freshly allocated memory — revert payloads included —
///         and the quadratic cost of that copy is paid by the *caller*, on top of whatever the callee already
///         spent producing it. Writing straight into scratch memory through a 32-byte output window means the
///         reply size cannot influence the caller's gas at all: bytes past the first word are discarded by the
///         EVM, never copied.
///      3. **Masking rather than `abi.decode`.** `abi.decode(ret, (address))` emits a validator that reverts
///         when bits above 160 are dirty, and that revert fires in the *calling* frame — a `try`/`catch` around
///         the caller does not stop it. {safeAddr} truncates instead, exactly as `address(uint160(word))` does
///         everywhere else in the EVM, so a sloppy callee yields a (possibly wrong) address rather than taking
///         the whole read down. Callers already treat `address(0)` / an unusable address as "absent".
///
///      IMPORTANT: `ok` is the raw `staticcall` success flag only — it does NOT incorporate the returndata-length
///      check. A call can return `ok == true` with `result == 0` if the callee returned fewer than 32 bytes
///      (decoding is skipped in that case), which mirrors the exact semantics of the per-adapter helpers this
///      library replaced. Callers that must distinguish "call succeeded but gave no usable value" from "returned
///      zero" cannot get that from `(ok, result)` at all — they should call {probeWord} and gate on its
///      `hasWord`, rather than hand-roll another raw staticcall. A code-less `target` likewise yields
///      `ok == true` with empty returndata — a raw staticcall has no `extcodesize` precheck — so a `code.length`
///      guard in front of these helpers would be dead code, not a safety net.
library StaticCallLib {
    /// @notice Gas stipend forwarded to every probe.
    /// @dev Ample for a real metadata/accounting read even through a couple of proxy hops (the reads routed here
    ///      are storage getters and small accounting formulas, an order of magnitude cheaper), while bounding
    ///      what a hostile or broken callee can burn on the caller's behalf. Mirrors the `PROBE_GAS` stipends
    ///      the adapters that harden their own reads already use.
    uint256 internal constant PROBE_GAS = 100_000;

    /// @notice staticcalls `target` with `data`, decoding a uint256 only if the call returned ≥ 32 bytes.
    /// @return ok The raw staticcall success flag (true even when fewer than 32 bytes were returned).
    /// @return result The decoded uint256; 0 if the call reverted OR returned fewer than 32 bytes.
    function safeUint(address target, bytes memory data) internal view returns (bool ok, uint256 result) {
        bool hasWord;
        uint256 word;
        (ok, hasWord, word) = probeWord(target, data);
        if (hasWord) result = word;
    }

    /// @notice staticcalls `target` with `data`, decoding an address only if the call returned ≥ 32 bytes.
    /// @dev The first returned word is masked to 160 bits rather than run through `abi.decode(ret, (address))`,
    ///      which reverts on dirty upper bits — see the note on the library.
    /// @return ok The raw staticcall success flag (true even when fewer than 32 bytes were returned).
    /// @return result The decoded address; address(0) if the call reverted OR returned fewer than 32 bytes.
    function safeAddr(address target, bytes memory data) internal view returns (bool ok, address result) {
        bool hasWord;
        uint256 word;
        (ok, hasWord, word) = probeWord(target, data);
        if (hasWord) result = address(uint160(word));
    }

    /// @notice As {safeAddr}, but REJECTS a word with dirty bits above 160 instead of masking it off, and tells
    ///         the caller when that happened.
    /// @dev Both policies are legitimate and the choice is per call site, not per library, which is why both
    ///      exist here rather than one being "the" address reader:
    ///
    ///      - **Mask** ({safeAddr}) favours liveness. A sloppy-but-honest callee — a `bytes32`-shaped return, a
    ///        padding-careless implementation — still yields a usable address. Right when a wrong address simply
    ///        fails downstream (an unregistered reward token is skipped; a bogus LP token resolves to nothing).
    ///      - **Reject** (this) favours a clean "cannot read" sentinel. Right when `address(0)` is a MEANINGFUL
    ///        value that a caller branches on, so silently manufacturing it from garbage changes the answer
    ///        rather than losing it.
    ///
    ///      Two call sites need the strict form: Euler's `EVC()`, whose `address(0)` is the "cannot classify"
    ///      sentinel `_supplyKind` short-circuits on, and Uniswap V2's `feeTo()`, whose `address(0)` means "no
    ///      protocol fee" and so drops the dilution term and RAISES the reported LP share.
    ///
    ///      **`malformed` reports "answered, but not with an address" — NOT merely "no address available".**
    ///      That distinction is the whole point and it is easy to get wrong. A callee that returns NOTHING (a
    ///      code-less target, an empty reply, a revert) has told you it does not implement the selector, which
    ///      for an optional view is ordinary and usually means "treat it as absent". A callee that returns a
    ///      full word which is not a valid address has told you something is broken. Folding both into one
    ///      "not an address" flag makes callers drop positions over a missing optional getter — so `malformed`
    ///      is deliberately false for a short or absent reply, and callers distinguish that case via `ok` and a
    ///      zero `result` exactly as they would with {safeAddr}.
    /// @return ok The raw staticcall success flag (true even when the word was rejected as not an address).
    /// @return result The address; address(0) if the call reverted, returned fewer than 32 bytes, or returned a
    ///         word that is not a valid address.
    /// @return malformed True ONLY when a full word came back AND its upper 96 bits are dirty. False for a
    ///         revert, a short reply, or a code-less target — those are "absent", not "broken".
    function safeAddrStrict(address target, bytes memory data)
        internal
        view
        returns (bool ok, address result, bool malformed)
    {
        bool hasWord;
        uint256 word;
        (ok, hasWord, word) = probeWord(target, data);
        malformed = hasWord && word >> 160 != 0;
        if (hasWord && !malformed) result = address(uint160(word));
    }

    /// @notice Performs the bounded staticcall and hands back the first returned word, undecoded.
    /// @dev Exposed because {safeUint}'s `(ok, result)` pair cannot distinguish "returned zero" from "returned
    ///      nothing", and for some reads that difference is load-bearing — Convex's `pid()` is the canonical
    ///      example, where a short reply read as `0` would silently resolve to Booster pool 0's LP token.
    ///      Those callers gate on `hasWord` instead of inventing another raw staticcall.
    ///
    ///      The output window is the 32-byte scratch slot at 0x00, so `returndatasize()` never influences the
    ///      caller's memory footprint: the EVM copies `min(returndatasize(), 32)` bytes and drops the rest. The
    ///      scratch space (0x00–0x3f) is free for transient use, which is why this block is `memory-safe`.
    ///
    ///      `word` is returned as 0 unless `hasWord`, and that assignment is load-bearing rather than tidiness.
    ///      A fixed output window is not cleared between probes: on an empty reply the EVM writes nothing, so
    ///      the slot still holds whatever the *previous* probe left there — inside one `getAdapterPositions`
    ///      sweep, that is the preceding instance's successful reply, not obvious garbage. The `bytes memory`
    ///      shape this replaced allocated fresh memory per call and so made "the callee returned nothing"
    ///      structurally unreadable; zeroing here restores that guarantee for the same three gas.
    /// @return ok The raw staticcall success flag. Callers wanting "did I get a value" want `hasWord`, not this.
    /// @return hasWord True when the call succeeded AND returned at least one full word.
    /// @return word The first 32 bytes of returndata, or 0 when `!hasWord`.
    function probeWord(address target, bytes memory data) internal view returns (bool ok, bool hasWord, uint256 word) {
        uint256 size;
        uint256 raw;
        assembly ("memory-safe") {
            ok := staticcall(PROBE_GAS, target, add(data, 0x20), mload(data), 0x00, 0x20)
            size := returndatasize()
            raw := mload(0x00)
        }
        hasWord = ok && size >= 32;
        // `ok &&` is not redundant with the size check: a callee that reverts with a standard `Error(string)`
        // payload produces ≥ 32 bytes of returndata, which the EVM copies into the output window exactly as a
        // successful reply would. Without `ok`, that revert payload's first word would be handed back as a value.
        if (hasWord) word = raw;
    }

    /// @notice As {probeWord}, but with a CALLER-SUPPLIED stipend, and it reports whether a failed call ran out
    ///         of that stipend rather than answering.
    /// @dev Exists because {probeWord}'s two properties — a fixed {PROBE_GAS} ceiling and a `false` that folds
    ///      "reverted" together with "ran out of gas" — are wrong for a read whose absence changes a NAV number
    ///      rather than a label.
    ///
    ///      **Why the stipend is the caller's.** {PROBE_GAS} is local and fixed, so a starved read cannot be
    ///      rescued by handing the whole call more gas — the ceiling binds first, identically, at every budget.
    ///      That is tolerable for a cosmetic read and not for an accounting one: it makes the failure permanent
    ///      rather than a matter of asking for more. A caller passing `GasStipendLib.stipendFrom(gasleft())` gets
    ///      the same recoverable shape the rest of the read path already has.
    ///
    ///      **Why `starved` is separate from `ok`.** A revert and an exhausted stipend are indistinguishable in
    ///      the success flag alone, and they deserve opposite treatment: a contract that genuinely does not
    ///      implement the selector has ANSWERED, and failing open is right; one that ran out of gas has not, and
    ///      recording its absence as a zero is how a missing debt leg becomes a higher NAV.
    ///
    ///      The classification is {GasStipendLib}'s, deliberately shared rather than restated — a threshold that
    ///      drifts between the guards asking this question re-opens the hole between them.
    ///
    ///      It is measured against what was ACTUALLY forwarded, not against `stipend`. EIP-150 hands the callee
    ///      `min(stipend, 63/64 of what remains)`, so in a frame too poor to forward the full stipend a callee
    ///      that burns everything it got would consume far less than `stipend` and read as a cheap revert. That
    ///      false negative is precisely the nested-starvation case, so the floor is computed here.
    ///
    ///      **The guarantee has a depth, and it is 8.** Every nesting level leaves another 1/64 reserve behind,
    ///      so a callee `d` frames down burns at most `(63/64)^d` of the stipend measured here. `GasStipendLib`'s
    ///      `SLACK_DIVISOR` of 8 accepts anything at or above `7/8`, and `(63/64)^d >= 7/8` holds up to
    ///      `d ~= 8.48`: a starved callee is classified LOUD through depth 8 and goes SILENT at depth 9,
    ///      invariant across the whole gas range rather than only at some budgets. Nothing in this repo nests
    ///      anywhere near that, so it does not bound the reads routed here today — but it is the ceiling on what
    ///      this can promise, and it is stated numerically because {GasStipendLib} asserts it only qualitatively
    ///      ("covers nesting far past anything in this repo"). A future reader stacking fan-outs needs the number,
    ///      not the reassurance.
    /// @param stipend Gas ceiling for the call. Pass `GasStipendLib.stipendFrom(gasleft())` for the recoverable
    ///        shape; a fixed value only where the read's absence is cosmetic.
    /// @return ok The raw staticcall success flag.
    /// @return hasWord True when the call succeeded AND returned at least one full word.
    /// @return word The first 32 bytes of returndata, or 0 when `!hasWord`.
    /// @return starved True ONLY when the call failed AND consumed essentially everything it was forwarded.
    /// @return consumed Gas the call cost this frame — reportable in the caller's error.
    function probeWordMetered(address target, bytes memory data, uint256 stipend)
        internal
        view
        returns (bool ok, bool hasWord, uint256 word, bool starved, uint256 consumed)
    {
        uint256 available = gasleft();
        uint256 size;
        uint256 raw;
        assembly ("memory-safe") {
            ok := staticcall(stipend, target, add(data, 0x20), mload(data), 0x00, 0x20)
            size := returndatasize()
            raw := mload(0x00)
        }
        consumed = available - gasleft();
        hasWord = ok && size >= 32;
        if (hasWord) word = raw;
        if (!ok) {
            uint256 forwarded = available - available / 64;
            if (stipend < forwarded) forwarded = stipend;
            starved = GasStipendLib.exhausted(forwarded, consumed);
        }
    }
}
