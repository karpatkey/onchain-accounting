// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";

/// @title IAttestedBalanceAdapter
/// @author KPK
/// @notice Marker interface for the **attested** balance-adapter family: externally-fed adapters whose positions
///         cannot be derived from on-chain state alone and are kept fresh by a **permissionless off-chain agent** — a
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
///        agent feeds many tracked accounts), by an ordinary external caller: no assistant contract, no roles, no
///        `delegatecall`. Its integrity rests on the on-chain **proof** carried by every write.
///
///      **Trust model & invariant.** Because the feeder is permissionless and submits on behalf of arbitrary
///      accounts, integrity does NOT come from `msg.sender`-keying or live-ownership re-verification. Instead **every
///      write carries a protocol-specific validity proof checked on-chain** (e.g. Merkl merkle-proof verification
///      against the live `Distributor.getMerkleRoot()`), so a faulty or malicious feeder can only ever cache an
///      account's **real proof-bound VALUE** — **under-report, never over-report** on the number. It does NOT
///      extend to auxiliary metadata a member caches beside that value, which may be submitter-controlled. Writes are a per-element **upsert** (add /
///      refresh a proven element); a submit **never drops** an element it omits, so a third party can never suppress
///      a live entry by submitting a partial or empty set. Removal is only via the stale-gated `clearAccount` (below)
///      / a per-protocol per-element clear. Stale entries read as 0 (e.g. cached root ≠ live root).
///
///      The per-protocol **submit** signature (element shape + its validity proof) is deliberately NOT prescribed
///      here — it varies by protocol. The interface advertises the family (via ERC-165) and the one universal mutator.
interface IAttestedBalanceAdapter is IBalanceAdapter {
    /// @notice Drop **all** of `account`'s cached elements — permissionless, **stale-gated** garbage collection.
    /// @dev Takes an explicit `account` because this family is submit-on-behalf-of (contrast
    ///      {IAssistedBalanceAdapter.clearAccount}, which is `msg.sender`-keyed and unconditional). **Reverts if ANY
    ///      of `account`'s elements is still live** (still contributing to NAV), so a live set can only ever be
    ///      *refreshed* via the per-protocol submit, never suppressed by a third party — preserving the
    ///      under-report-only invariant. Clears only when the whole set is stale/dead (reads already 0).
    function clearAccount(address account) external;
}
