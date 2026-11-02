// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title IAssistedBalanceAdapter
/// @author KPK
/// @notice Marker interface for the **assistant-fed** assisted balance-adapter family — adapters whose
///         positions cannot be derived from on-chain state alone (non-enumerable NFTs, withdrawal/exit-queue tickets)
///         and are instead fed their position *coordinates* on-chain by the position owner itself. The canonical
///         feeder is a small assistant contract ({IBalanceAdapterAssistant}) that a depositor Safe `delegatecall`s: in the
///         same transaction it enters/exits a protocol, it pushes/pops the resulting coordinate onto the adapter, and
///         because it runs under `delegatecall` the adapter sees `msg.sender = the Safe = the position owner`.
/// @dev **Trust model (family invariant).** Every member caches **only position coordinates, never amounts**; values
///      each read entirely from live on-chain reads; and re-verifies ownership on every read (discarding coordinates
///      no longer owned). A faulty or malicious feeder can therefore only **under-report, never over-report**.
///
///      **The deployed guarantee is stronger, and its second half is not in this repository.** The portfolio Safes'
///      **roles-modifier permission set allows the corresponding protocol entries only through the assistant
///      contracts — the direct protocol entrypoint is not allow-listed** — so a position of these types cannot be
///      active without its coordinate having been fed, making the cache **complete by construction**. Contract level
///      (here) → cannot **over**-report; roles level (outside this repo) → cannot **under**-report either. Nothing in
///      this repo enforces the latter (the owner mutators are permissionless), so do not infer it from the code; the
///      residual risk is a roles-permission change adding a non-assistant path, which no tripwire here would catch.
///      See ADR 0015 / ADR 0018 and `AssistedBalanceAdapters/README.md` §5.0.
///
///      **Two feeders (ADR 0030).** The owner path is unchanged: the typed `submit`/`remove` mutators derive the
///      account from `msg.sender`, so an account (directly or through its assistant) only ever touches its OWN set.
///      The interface does not prescribe those typed signatures, since the coordinate shape is per-protocol. Added for
///      positions the account did NOT open through its assistant: {submitFor}/{submitForBatch}, gated by
///      {SUBMITTER_ROLE} (a keeper), which file a coordinate only under the account the protocol says owns it — the
///      same write-time validation as the owner path, so the role decides WHICH positions occupy the capped cache,
///      never what they are worth. {removeFor} is permissionless but succeeds only once the protocol proves the
///      position is gone, so no caller can drop a live one. {previewPositions} values caller-supplied coordinates
///      without touching the cache.
///
///      **Coordinate encoding.** The generic entry points take `coord` as the member's canonical `abi.encode` of its
///      tuple (a 32-byte tokenId for ether.fi / Nexus Mutual, `(address vault, uint256 ticket, uint256 timestamp)` for
///      StakeWise). Any other length reverts, so one position has exactly one cache key.
interface IAssistedBalanceAdapter is IAccessControl, IBalanceAdapter {
    /// @notice A {previewPositions} payload names the same coordinate twice — a double count, rejected fail-loud.
    error DuplicateCoordinate(address account, uint256 id);

    /// @notice A {previewPositions} payload has more coordinates than an account's cache may hold.
    error TooManyCoordinates(address account, uint256 count, uint256 max);

    /// @notice `coord` is not the member's canonical encoding (wrong length), so it could alias another cache key.
    error NonCanonicalCoordinate(uint256 length, uint256 expected);

    /// @notice The role allowed to call {submitFor}/{submitForBatch}.
    function SUBMITTER_ROLE() external view returns (bytes32);

    /// @notice File `coord` under `account`, which the protocol must say owns it (idempotent). Requires
    ///         {SUBMITTER_ROLE}. Reverts `CoordinateNotOwned` / `InvalidCoordinate` on a bad or non-owned
    ///         coordinate, `CoordinateCacheFull` once the account holds the cap minus `OWNER_RESERVE` entries (the reserve stays for the
    ///         owner's own submit), {NonCanonicalCoordinate} on a wrong encoding.
    function submitFor(address account, bytes calldata coord) external;

    /// @notice Batch {submitFor}; all-or-nothing. Requires {SUBMITTER_ROLE}.
    function submitForBatch(address[] calldata accounts, bytes[] calldata coords) external;

    /// @notice Drop `coord` from `account`'s cache once the protocol proves the position is gone (claimed, burned,
    ///         transferred away, nothing left). Permissionless: a read that reverts never counts as proof, so no caller
    ///         can drop a live position. Reverts `CoordinateNotCached` / `CoordinateStillLive`.
    function removeFor(address account, bytes calldata coord) external;

    /// @notice Values caller-supplied coordinates for `account` without reading or writing the cache.
    /// @dev `data = abi.encode(bytes[] coords)`, each in the canonical encoding. Every coordinate goes through the
    ///      same validation as a submit and reverts on failure (bad, non-owned, duplicate, or more than the cap);
    ///      surviving ones are valued exactly as the NAV read values a cached coordinate. Empty `data` or a zero
    ///      `account` returns an empty array; an unregistered underlying returns an empty array, as the NAV read does.
    function previewPositions(address account, bytes calldata data)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory positions);

    /// @notice Drop **all** of the caller's own cached position coordinates (self-service garbage collection). Keyed on
    ///         `msg.sender`, so it can only clear the caller's own set — never another account's. This is
    ///         unconditional: unlike per-coordinate `remove` (which reverts `CoordinateStillLive` while a position is
    ///         live), `clearAccount` does **not** check liveness, so any still-live positions stop being reported until
    ///         re-submitted. Consistent with the family invariant it only ever **under-reports** the caller's own NAV;
    ///         it is not NAV-neutral when live coordinates are present.
    function clearAccount() external;
}
