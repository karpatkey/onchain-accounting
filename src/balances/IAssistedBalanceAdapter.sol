// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";

/// @title IAssistedBalanceAdapter
/// @author KPK
/// @notice Marker interface for the **permissionless, assistant-fed** assisted balance-adapter family — adapters whose
///         positions cannot be derived from on-chain state alone (non-enumerable NFTs, withdrawal/exit-queue tickets)
///         and are instead fed their position *coordinates* on-chain by the position owner itself. The canonical
///         feeder is a small assistant contract ({IBalanceAdapterAssistant}) that a depositor Safe `delegatecall`s: in the
///         same transaction it enters/exits a protocol, it pushes/pops the resulting coordinate onto the adapter, and
///         because it runs under `delegatecall` the adapter sees `msg.sender = the Safe = the position owner`.
/// @dev **Trust model (family invariant).** Every member caches **only position coordinates, never amounts**; values
///      each read entirely from live on-chain reads; and re-verifies ownership on every read (discarding coordinates
///      no longer owned). A faulty or malicious feeder can therefore only **under-report, never over-report**.
///
///      **Permissionless & self-scoped.** Unlike a role-gated off-chain-agent design (where one agent feeds many
///      accounts and submission is gated behind an `ASSISTANT_ROLE`), this family needs no
///      roles and no AccessControl: the submit/remove mutators derive the account from `msg.sender`, so a caller can
///      only ever add/remove its OWN coordinates — nobody can touch another account's set. The interface deliberately
///      does NOT prescribe the `submit`/`remove` signatures, since the coordinate shape is per-protocol (a bare
///      `uint256` tokenId/requestId, or a richer tuple). It only advertises the family (via ERC-165) and the one
///      universal self-service mutator below.
interface IAssistedBalanceAdapter is IBalanceAdapter {
    /// @notice Drop **all** of the caller's own cached position coordinates (self-service garbage collection). Keyed on
    ///         `msg.sender`, so it can only clear the caller's own set — never another account's. This is
    ///         unconditional: unlike per-coordinate `remove` (which reverts `CoordinateStillLive` while a position is
    ///         live), `clearAccount` does **not** check liveness, so any still-live positions stop being reported until
    ///         re-submitted. Consistent with the family invariant it only ever **under-reports** the caller's own NAV;
    ///         it is not NAV-neutral when live coordinates are present.
    function clearAccount() external;
}
