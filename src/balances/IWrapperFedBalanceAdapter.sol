// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title IWrapperFedBalanceAdapter
/// @author KPK
/// @notice Marker interface for balance adapters in the assisted family (ADR 0015) whose position coordinates are fed
///         **on-chain** by a trusted wrapper contract rather than by an off-chain agent. The wrapper holds
///         `WRAPPER_ROLE` and pushes/pops the account's NFT token ids atomically as it forwards deposits/withdrawals to
///         the underlying protocol, so the cache is kept current in the same transaction that changes the position.
///         The family invariant is unchanged from {IAssistedBalanceAdapter}: cache **coordinates only** (never
///         amounts), value every read live on-chain, and re-verify ownership per read, so a faulty or compromised
///         feeder can only under-report, never over-report.
/// @dev The interface only *identifies* this variant and exposes the role gating the feeder; it deliberately does NOT
///      prescribe how the data is submitted or verified — that is per-adapter. Role administration follows OpenZeppelin
///      AccessControl: `DEFAULT_ADMIN_ROLE` administers `WRAPPER_ROLE`. `IAccessControl` is listed first so the
///      interface's C3 linearization matches `AccessControl`'s (OZ v5 `IAccessControl` is not `IERC165`; the reverse
///      order does not compile) — mirroring {IAssistedBalanceAdapter}. See ADR 0020 (aligns with the wrapper-fed family
///      introduced by ADR 0018).
interface IWrapperFedBalanceAdapter is IAccessControl, IBalanceAdapter {
    /// @notice Role allowed to feed the adapter by submitting/removing position coordinates (held by the wrapper).
    /// @return The `bytes32` role identifier (`keccak256("WRAPPER_ROLE")`).
    function WRAPPER_ROLE() external view returns (bytes32);
}
