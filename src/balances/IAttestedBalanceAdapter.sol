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

    // ─── Reads ───

    /// @notice The cached attestation for `(account, asset)`.
    /// @dev `epoch == 0` means absent. A non-zero `epoch` that no longer matches the member's live epoch is STALE
    ///      and values as 0 — so a non-zero `value` here is NOT by itself a claim that the element contributes to
    ///      NAV. Use {IBalanceAdapter.getAdapterBalanceForAsset} for the figure actually reported.
    function attestations(address account, address asset)
        external
        view
        returns (uint256 value, bytes32 epoch, uint64 attestedAt);

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
