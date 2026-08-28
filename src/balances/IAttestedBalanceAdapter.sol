// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title IAttestedBalanceAdapter
/// @author KPK
/// @notice Marker interface for the **attested** balance-adapter family: externally-fed adapters whose positions
///         cannot be derived from on-chain state alone and are kept fresh by a **role-gated off-chain agent** — a
///         plain keeper EOA / cron, **not** a `delegatecall` assistant contract — that submits, **on behalf of** a
///         tracked account, that account's cached elements. The defining trait is that **every write carries a
///         protocol-specific validity proof verified on-chain** (an *attestation*): a write only lands if its proof
///         validates, so the **proof-bound value** is always the account's real, protocol-attested figure.
///         **The attestation covers that value and nothing else.** A member may cache auxiliary metadata the proof
///         does NOT commit to — Merkl's campaign ids and per-campaign split are submitter-controlled, with only
///         their SUM checked against the proven per-token total — so consumers must not treat cached position
///         IDENTITY as attested. A member that caches such metadata must document it.
/// @dev **How this differs from {IAssistedBalanceAdapter}** (the other externally-fed family):
///      - {IAssistedBalanceAdapter} is `msg.sender`-keyed and fed by a `delegatecall` assistant so the adapter sees
///        `msg.sender = the position owner`; it caches **coordinates only, never amounts** and re-verifies ownership
///        live per read. Its integrity rests on `msg.sender`-keying + live-ownership re-verification.
///      - an **attested** adapter is **submit-on-behalf-of** — the submit mutator takes an explicit `account` (one
///        agent feeds many tracked accounts), by an ordinary external caller holding `SUBMITTER_ROLE`: no assistant contract, no
///        `delegatecall`. Its integrity rests on the on-chain **proof** carried by every write.
///
///      **Trust model & invariant.** Because the feeder submits on behalf of arbitrary accounts, integrity does NOT come from `msg.sender`-keying or live-ownership re-verification. Instead **every
///      write carries a protocol-specific validity proof checked on-chain** (e.g. Merkl merkle-proof verification
///      against the live `Distributor.getMerkleRoot()`), so a faulty or malicious feeder can only ever cache an
///      account's **real proof-bound VALUE** — **under-report, never over-report** on the number. It does NOT
///      extend to auxiliary metadata a member caches beside that value, which may be submitter-controlled. Writes are a per-element **upsert** (add /
///      refresh a proven element); a submit **never drops** an element it omits, so a third party can never suppress
///      a live entry by submitting a partial or empty set. Removal is only via the stale-gated `clearAccount` / `clearAttestation`
///      (both below, both universal). Stale entries read as 0 (e.g. cached root ≠ live root).
///
///      The per-protocol **submit** signature (typed element shape + its validity proof) is deliberately NOT
///      prescribed here — it varies by protocol. The interface advertises the family (via ERC-165), the one universal
///      mutator (`clearAccount`), and one universal **read** (`previewPositions(account, bytes)`): the read's proof
///      data is opaque `bytes` at the family level (each member `abi.decode`s it into its own shape), so a single
///      signature serves every attested adapter, present and future, with the `bytes` being whatever that protocol needs.
/// @dev **CHARTER: this family reports CREDITS ONLY.** Every leg an adapter advertising THIS interface id emits
///      has `isDebt == false`, and the base ENFORCES it rather than asking members to remember. The enforcement
///      stack, stated precisely because an earlier version of this text over-claimed it: the scalar reads and the
///      per-item failure policy are non-virtual, so the compiler blocks them; `_row`, the base's leg constructor,
///      cannot set the flag; and — because `_assetLegs` is necessarily virtual and returns member-built structs,
///      so nothing forces a member through `_row` — the base also REJECTS a debt leg at runtime as it collects,
///      reverting {DebtLegRejected}. The conformance kit asserts the same property at test time. The scope is
///      deliberate — an
///      attested-LIABILITY protocol is conceivable, but under this base it would need the reads, the leg builder,
///      the per-item failure policy and the drop licence all overridden in concert, which is maximally easy to
///      get wrong. Such a protocol wants a sibling base and its own interface id, not an override of this one.
///
///      This is what licenses the base's per-item **drop** on a failed read: a dropped CREDIT leg can only make
///      NAV smaller, the direction the family already tolerates. Dropping a DEBT leg would make NAV larger — the
///      one direction forbidden — so the licence and the charter stand or fall together.
interface IAttestedBalanceAdapter is IAccessControl, IBalanceAdapter {
    /// @notice Role required to SUBMIT attestations. Granted and revoked by `DEFAULT_ADMIN_ROLE`.
    /// @dev **Gates the write surface only.** The family's clears stay permissionless and stale-gated on purpose:
    ///      role-gating removal is exactly what audit finding L-02 flagged on an earlier draft, where a compromised
    ///      role-holder could delete valid LIVE allocations — a targeted under-report caused by the mechanism meant
    ///      to prevent one. The stale gate (an entry may only be cleared once it already contributes 0) makes
    ///      clearing safe for any caller, which is why it needs no role.
    ///
    ///      **What the role buys, and what it does not.** It does NOT protect the reported AMOUNT — the per-write
    ///      proof already does that, and no caller could ever write an unattested figure. What it protects is the
    ///      space the proof does not cover: **which elements occupy the per-account cache** (cap squatting) and
    ///      **how a proven total is labelled** (member-supplied sub-position metadata such as Merkl's campaign
    ///      split). Both are bounded, non-NAV-affecting griefs under a permissionless surface; the role closes
    ///      them at the cost of a privileged key and a liveness chokepoint on cache freshness.
    function SUBMITTER_ROLE() external view returns (bytes32);

    // ─── Events ─── every member emits these; typed here so an indexer never imports a member or the base.

    /// @notice Emitted on every `(account, asset)` upsert.
    /// @param submitter The caller that wrote it. Attribution for monitoring — authorization is `SUBMITTER_ROLE`.
    event AttestationCached(
        address indexed account,
        address indexed asset,
        address indexed submitter,
        uint256 value,
        bytes32 epoch,
        uint64 attestedAt
    );
    event AttestationCleared(address indexed account, address indexed asset);
    event AccountCleared(address indexed account);

    // ─── Errors ─── declared here so a consumer can decode a revert without importing the implementation.

    /// @notice The NAVCalculator supplied at construction cannot serve `getRegisteredAsset(address)`.
    error NAVCalculatorTooOld(address navCalculator);
    /// @notice The member's attestation epoch source returned zero (uninitialized).
    error UninitializedEpoch();
    /// @notice Admitting this element would exceed the member's per-account cache cap.
    error TooManyAttestations(address account, uint256 count);
    /// @notice A clear was attempted on an element still contributing to NAV. Clearing is GC for dead entries only.
    error AttestationStillLive(address account, address asset);
    /// @notice A clear was attempted on an `(account, asset)` with nothing cached.
    error NothingToClear();
    /// @notice The same asset appeared twice in a {previewPositions} payload — a double-count, rejected fail-loud.
    error DuplicateAsset(address asset);

    /// @notice A member returned a leg with `isDebt == true`, which this family's charter forbids.
    /// @dev The base's per-item DROP on a failed read is licensed ONLY because every leg is a credit: a dropped
    ///      credit leg shrinks NAV (tolerated), a dropped debt leg inflates it (forbidden). Rather than trust a
    ///      member to honour that, the base checks it as it collects. A debt-attesting protocol wants a sibling
    ///      base and its own interface id — see the charter on this interface.
    ///
    ///      **Blast radius on the NAV path, so it is not over-read as a per-leg drop.** This reverts in the
    ///      collecting frame, OUTSIDE the per-asset `try`, so it is not absorbed by the per-item isolation: it
    ///      bubbles out of `getAdapterPositions`, and `PriceFeedLib` fails open on a plain revert, so the
    ///      adapter's ENTIRE leg set leaves NAV for that account rather than just the offending asset. That is
    ///      the intended severity — a member emitting debt has broken the family's central assumption, and the
    ///      whole adapter should stop contributing rather than contribute something quietly wrong — but the
    ///      direction is under-report, so it degrades NAV rather than inflating it.
    error DebtLegRejected(address asset);

    /// @notice A member's legs for one asset summed to MORE than that asset's live value.
    /// @dev The third structural bound on member-built legs, alongside the count cap and the credit-only check.
    ///      The family's whole point is that the attestation BOUNDS the reported figure, and legs are supposed to
    ///      partition that figure — so a member emitting two legs each carrying the full value doubles the account's
    ///      reported holding while passing every other guard. Direction: OVER-report, the one direction forbidden.
    ///
    ///      **BLAST RADIUS — the same one {DebtLegRejected} carries.** This is thrown from `_collectLegs`, which
    ///      sits OUTSIDE the per-asset `try`, so it bubbles out of `getAdapterPositions`; `PriceFeedLib` fails
    ///      OPEN on a plain revert, and the adapter's ENTIRE leg set silently leaves NAV for that account — not
    ///      just the offending asset. The trigger can be tiny and the loss total: a member using CEILING-rounded
    ///      pro-rata splits is one wei over on one asset and loses the whole account's adapter contribution, with
    ///      no error anywhere. Split with a FLOOR (`Math.mulDiv` rounds down by default), as the README recipe
    ///      says and as the Merkl member does. Note the asymmetry with an over-emitted leg COUNT, which drops
    ///      only its own asset — confining these four the same way is a live option, deliberately not taken in
    ///      the same sitting that wrote them.
    error LegSumExceedsValue(address asset);

    /// @notice A member returned a leg denominated in a DIFFERENT asset than the one being valued.
    /// @dev The fourth axis, and the one that makes the magnitude bound dimensionally sound. `balanceAsset.asset`
    ///      is the PRICING KEY — `PriceFeedLib` resolves a feed from exactly this field and converts `amount`
    ///      through it. Without this pin a member could pass the count, direction and magnitude bounds in the
    ///      attested asset's raw units while denominating its legs in some other REGISTERED asset, inflating
    ///      quote-NAV by the price ratio: unbounded, and in the direction the family forbids. Bounding amounts
    ///      without pinning the unit compares numbers that are not in the same currency.
    ///
    ///      **BLAST RADIUS — the same one {DebtLegRejected} carries.** This is thrown from `_collectLegs`, which
    ///      sits OUTSIDE the per-asset `try`, so it bubbles out of `getAdapterPositions`; `PriceFeedLib` fails
    ///      OPEN on a plain revert, and the adapter's ENTIRE leg set silently leaves NAV for that account — not
    ///      just the offending asset. The trigger can be tiny and the loss total: a member using CEILING-rounded
    ///      pro-rata splits is one wei over on one asset and loses the whole account's adapter contribution, with
    ///      no error anywhere. Split with a FLOOR (`Math.mulDiv` rounds down by default), as the README recipe
    ///      says and as the Merkl member does. Note the asymmetry with an over-emitted leg COUNT, which drops
    ///      only its own asset — confining these four the same way is a live option, deliberately not taken in
    ///      the same sitting that wrote them.
    error LegAssetMismatch(address expected);

    /// @notice A member returned a leg attributed to an adapter other than itself.
    /// @dev `balanceAdapter == address(this)` is a repo-wide invariant and the audit trail every reconciliation
    ///      keys on. Nothing but the shared `_row` helper was upholding it, and `_assetLegs` is virtual.
    ///
    ///      **BLAST RADIUS — the same one {DebtLegRejected} carries.** This is thrown from `_collectLegs`, which
    ///      sits OUTSIDE the per-asset `try`, so it bubbles out of `getAdapterPositions`; `PriceFeedLib` fails
    ///      OPEN on a plain revert, and the adapter's ENTIRE leg set silently leaves NAV for that account — not
    ///      just the offending asset. The trigger can be tiny and the loss total: a member using CEILING-rounded
    ///      pro-rata splits is one wei over on one asset and loses the whole account's adapter contribution, with
    ///      no error anywhere. Split with a FLOOR (`Math.mulDiv` rounds down by default), as the README recipe
    ///      says and as the Merkl member does. Note the asymmetry with an over-emitted leg COUNT, which drops
    ///      only its own asset — confining these four the same way is a live option, deliberately not taken in
    ///      the same sitting that wrote them.
    error LegAdapterMismatch(address asset);

    // ─── Reads ───

    /// @notice The cached attestation for `(account, asset)`.
    /// @dev `epoch == 0` means absent. A non-zero `epoch` that no longer matches the member's live epoch is STALE
    ///      and values as 0 — so a non-zero `value` here is NOT by itself a claim that the element contributes to
    ///      NAV. Use {IBalanceAdapter.getAdapterBalanceForAsset} for the figure actually reported.
    function attestations(address account, address asset)
        external
        view
        returns (uint256 value, bytes32 epoch, uint64 attestedAt);

    /// @notice The per-account cache cap: the most distinct assets this adapter will hold for one account.
    /// @dev Family-level because the base enforces it (`TooManyAttestations` on admission) and because a
    ///      protocol-agnostic consumer needs it without knowing the member: comparing `assetsOf(account).length`
    ///      against this is how you detect an account approaching the cap, whether through ordinary accumulation
    ///      or through a third party occupying slots. Constant per deployment — no admin can loosen it.
    function maxAssetsPerAccount() external view returns (uint256);

    /// @notice Whether `account`'s cached attestation for `asset` is still valid under this member's scheme.
    /// @dev **Disambiguates the three states that all read as a balance of 0**, which a consumer otherwise cannot
    ///      tell apart and which need three different responses: nothing cached (`attestations().epoch == 0`);
    ///      cached but no longer current, i.e. the feeder is behind (false here — page the feeder); and cached,
    ///      current, but fully consumed (true here, balance 0 — garbage-collect it).
    ///
    ///      Deliberately a PREDICATE rather than an exposed epoch. What "still valid" means is per-protocol — a
    ///      merkle root matching, a signature inside its TTL, a per-asset anchor — and publishing one global epoch
    ///      would freeze the first member's scheme into the family contract forever. Every member can answer this
    ///      question; not every member has a single global anchor to publish.
    ///
    ///      Two honest caveats. **It can flap**: a protocol whose anchor is non-monotonic (Merkl's dispute window
    ///      rolls the root back) can return false and then true again for the same entry. And **live is not the
    ///      same as counted** — a live but fully-consumed entry reads 0 and is clearable.
    function isAttestationLive(address account, address asset) external view returns (bool);

    /// @notice The assets currently cached for `account`, stale ones included.
    /// @dev The family cannot enumerate its universe ahead of time, so `underlyingAssetsSupported()` is empty and
    ///      this per-account list is what drives the reads. Filter on `attestations(...).epoch` for freshness.
    function assetsOf(address account) external view returns (address[] memory);

    // ─── Mutators ───

    // ─── Mutators — the write surface ───

    /// @notice Submit attestations for `account`. Requires {SUBMITTER_ROLE}.
    /// @dev **`data` is opaque at the family level**, exactly as on {previewPositions} — each member `abi.decode`s
    ///      it into its own element/proof shape, so ONE signature serves every attested adapter. The two take the
    ///      SAME payload by design and share the member's single decode-and-verify hook, which is what stops the
    ///      write path and the preview from ever disagreeing about what a valid attestation is.
    ///
    ///      Semantics are **upsert**: each element in `data` adds or refreshes its own `(account, asset)` and
    ///      elements omitted from `data` are left untouched, so a submit can never suppress a live entry. Removal is
    ///      only via the stale-gated clears. **Atomic** — any invalid element reverts the whole call, leaving the
    ///      prior set intact.
    ///
    ///      A member MAY additionally expose a typed convenience entrypoint (Merkl's `submitProofs`) for ABI
    ///      ergonomics, but this generic one is the family contract and every member has it.
    /// @param account The account the attestations are for.
    /// @param data    ABI-encoded, protocol-specific attestation data (Merkl: `abi.encode(Allocation[])`).
    function submit(address account, bytes calldata data) external;

    /// @notice Batch variant — one payload per account. Requires {SUBMITTER_ROLE}.
    /// @dev **Atomic across accounts:** any single invalid element reverts the ENTIRE batch, so no account in the
    ///      call is updated. Deliberate fail-loud handling, but it means a multi-account feeder should pre-filter
    ///      bad data (or fall back to {submit}) so one account cannot block every other account's refresh.
    function submitBatch(address[] calldata accounts, bytes[] calldata data) external;

    /// @notice Drop ONE cached element — permissionless, **stale-gated** garbage collection.
    /// @dev Universal, not per-protocol: implemented once for the whole family. Reverts {AttestationStillLive}
    ///      while the element still contributes to NAV, so a live entry can only be *refreshed*, never suppressed.
    ///      **Deliberately not role-gated** — see {SUBMITTER_ROLE}.
    function clearAttestation(address account, address asset) external;

    /// @notice Drop **all** of `account`'s cached elements — permissionless, **stale-gated** garbage collection.
    /// @dev Takes an explicit `account` because this family is submit-on-behalf-of (contrast
    ///      {IAssistedBalanceAdapter.clearAccount}, which is `msg.sender`-keyed and unconditional). **Reverts if ANY
    ///      of `account`'s elements is still live** (still contributing to NAV), so a live set can only ever be
    ///      *refreshed* via the per-protocol submit, never suppressed by a third party — preserving the
    ///      under-report-only invariant. Clears only when the whole set is stale/dead (reads already 0).
    function clearAccount(address account) external;

    /// @notice Trustless, CACHE-FREE preview: value `account`'s positions from **caller-supplied** off-chain proof
    ///         data, with no prior submit and without touching the cache. `data` is opaque at the family level — each
    ///         member `abi.decode`s it into its own proof shape (Merkl: `abi.encode(Allocation[])`) — so this one
    ///         signature serves every attested adapter, with `data` being whatever that protocol needs.
    /// @dev A `view`: reads no member cache and writes none, so it does not feed the cache and has no effect on the NAV
    ///      read (`getAdapterPositions`, which keeps reading the agent-fed cache). It carries the same integrity as the
    ///      write path — every proof in `data` is verified on-chain against the protocol's live root, so it can only
    ///      surface the account's real figure (under-report, never over-report) — and is **fail-loud** on an invalid
    ///      proof. An *extra* read for a portal / frontend / third party that computes proofs off-chain. Empty `data`
    ///      (or a zero `account`) returns an empty array. **As on the write path, the attestation covers only the
    ///      proof-bound value** — any auxiliary sub-position metadata a member returns (e.g. Merkl campaign identity,
    ///      where only the shares' SUM is checked) is submitter-controlled and NOT attested; consumers must not treat
    ///      returned position IDENTITY as proof-backed. See the member's docs.
    /// @param account The account to value (any address — proofs are public; the result is that account's real figure).
    /// @param data    ABI-encoded, protocol-specific proof/off-chain data (Merkl: `abi.encode(Allocation[])`).
    function previewPositions(address account, bytes calldata data)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory positions);
}
