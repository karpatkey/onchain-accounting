// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @title IBalanceAdapterAssistant
/// @author KPK
/// @notice Marker interface for the **delegatecall-action assistants** that feed the assistant-fed assisted
///         balance adapters ({IAssistedBalanceAdapter}). An assistant is a stateless logic module a depositor Safe
///         `delegatecall`s: in the same transaction it enters/exits a protocol (deposit, withdrawal-request, exit-queue
///         entry, claim), it pushes/pops the resulting position **coordinate** onto its paired adapter. Running under
///         `delegatecall` makes `address(this)` the Safe, so the protocol sees `msg.sender = Safe` (the position owner)
///         and the adapter's `msg.sender`-keyed cache records against that same Safe — no roles, no custody, no
///         asset-forwarding.
/// @dev Concrete assistants extend {BalanceAdapterAssistant} (which provides the `SELF` / `onlyDelegateCall` guard and the
///      immutable `ADAPTER` reference) and add the protocol-specific forward-then-`submit`/`remove` entrypoints. Their
///      signatures are per-protocol, so this interface only exposes the two immutables common to all of them.
interface IBalanceAdapterAssistant {
    /// @notice The assistant-fed assisted balance adapter this assistant feeds.
    function ADAPTER() external view returns (address);

    /// @notice This assistant's own deployed address, pinned at construction — the delegatecall-guard anchor (under
    ///         `delegatecall` `address(this)` is the calling Safe, `!= SELF`; on a direct call `address(this) == SELF`).
    function SELF() external view returns (address);
}
