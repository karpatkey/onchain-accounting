// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";

/// @title IListFedBalanceAdapter
/// @author KPK
/// @notice Marker interface for the **list-fed** balance-adapter family: externally-fed adapters whose positions
///         cannot be derived from on-chain state alone and are kept fresh by a **permissionless off-chain agent** — a
///         plain keeper EOA / cron, **not** a `delegatecall` assistant contract — that submits, **on behalf of** a
///         tracked account, that account's **complete current element set as one whole list**, which **replaces** the
///         account's prior cached set (an element omitted from the list is dropped). "Submit the whole list", not
///         "submit one new element", is the defining trait.
/// @dev **How this differs from {IAssistedBalanceAdapter}** (the other externally-fed family):
///      - {IAssistedBalanceAdapter} is `msg.sender`-keyed and fed **per-element** (submit/remove individual
///        coordinates), by a `delegatecall` assistant so the adapter sees `msg.sender = the position owner`; it caches
///        **coordinates only, never amounts** and re-verifies ownership live per read.
///      - a **list-fed** adapter is **submit-on-behalf-of** — the submit mutator takes an explicit `account` (one
///        agent feeds many tracked accounts) — and is fed the **whole set at once** (replace semantics), by an
///        ordinary external caller: no assistant contract, no roles, no `delegatecall`.
///
///      **Trust model.** Because the feeder is permissionless and submits on behalf of arbitrary accounts, integrity
///      does NOT come from `msg.sender`-keying or live-ownership re-verification. Instead **every write carries a
///      protocol-specific validity proof checked on-chain** (e.g. Merkl merkle-proof verification against the live
///      `Distributor.getMerkleRoot()`), so a faulty or malicious feeder can only ever submit an account's **real**
///      data — it can **under-report, never over-report**. Stale entries read as 0 (e.g. cached root ≠ live root).
///
///      The per-protocol **submit** signature (element shape + its validity proof) is deliberately NOT prescribed
///      here — it varies by protocol. The interface advertises the family (via ERC-165) and the one universal mutator.
interface IListFedBalanceAdapter is IBalanceAdapter {
    /// @notice Drop **all** of `account`'s cached elements — permissionless, **stale-gated** garbage collection.
    /// @dev Takes an explicit `account` because this family is submit-on-behalf-of (contrast
    ///      {IAssistedBalanceAdapter.clearAccount}, which is `msg.sender`-keyed and unconditional). **Reverts if ANY
    ///      of `account`'s elements is still live** (still contributing to NAV), so a live set can only ever be
    ///      *replaced* via the per-protocol submit, never suppressed by a third party — preserving the
    ///      under-report-only invariant. Clears only when the whole set is stale/dead (reads already 0).
    function clearAccount(address account) external;
}
