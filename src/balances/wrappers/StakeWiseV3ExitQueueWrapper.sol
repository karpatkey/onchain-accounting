// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title StakeWise V3 Exit-Queue Wrapper
/// @author KPK
/// @notice A thin **delegatecall action** contract that a depositor Safe delegatecalls to enter / exit the StakeWise
///         V3 exit queue and, in the *same* transaction, register / deregister the resulting `positionTicket` on
///         {StakeWiseV3ExitQueueAssistedBalanceAdapter} so the queued value stays visible to NAV. StakeWise exit positions are
///         not enumerable and StakeWise keys `claimExitedAssets` on `msg.sender`, so the Safe must be both the
///         `receiver` and the claimer — which is exactly what delegatecall gives: the wrapper's code runs in the
///         Safe's context, so `address(this)` is the Safe, the vault sees `msg.sender = Safe`, the exit position is
///         owned by the Safe, and claimed assets are paid to the Safe. No custody or asset-forwarding logic is needed.
/// @dev **Delegatecall-only design.** Because {enterExitQueue} / {claimExitedAssets} execute against the *caller's*
///      (Safe's) storage:
///      - they perform **no storage writes** (a write would corrupt Safe storage), and
///      - their `DEPOSITOR_ROLE` gate cannot use the inherited `onlyRole` modifier (that reads Safe storage). Instead
///        they check the role against the wrapper **singleton's own** storage via the immutable {SELF} (bytecode-
///        embedded, so readable under delegatecall): `IAccessControl(SELF).hasRole(DEPOSITOR_ROLE, address(this))` — i.e.
///        "is the executing Safe an approved depositor?". Admins grant/revoke `DEPOSITOR_ROLE` by calling the singleton
///        directly (a normal, non-delegatecall transaction, where the inherited AccessControl machinery applies).
///
///      **Feeding the adapter via a self-call.** The delegatecalled entrypoints do NOT call the adapter directly — that
///      call would carry `msg.sender = the Safe`, forcing the adapter to grant its `WRAPPER_ROLE` to every depositor.
///      Instead they call **back into the singleton** ({submit}/{remove}) via {SELF}; those functions run in the
///      singleton's context and forward to the adapter, so the adapter sees `msg.sender = the singleton` and grants
///      `WRAPPER_ROLE` **only to this wrapper**. {submit}/{remove} are `onlyRole(DEPOSITOR_ROLE)` (the caller Safe must
///      be an approved depositor) and require `account == msg.sender` (a depositor can only track its OWN tickets);
///      they may also be called standalone by an approved depositor. See
///      `docs/decisions/0019-stakewise-v3-exit-queue-wrapper.md` (StakeWise-specific instance of the wrapper-fed
///      assisted family, ADR 0018).
contract StakeWiseV3ExitQueueWrapper is AccessControl {
    /// @notice Role identifying an approved depositor Safe. Held on the singleton's storage; checked via {SELF}.
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    /// @notice This wrapper's own deployment address, pinned at construction. Under delegatecall `address(this)` is the
    ///         caller Safe, so role checks must target this fixed singleton to hit the real role storage.
    address public immutable SELF;

    /// @notice The balance adapter fed by this wrapper ({StakeWiseV3ExitQueueAssistedBalanceAdapter}). Immutable, so it is
    ///         readable from the wrapper's bytecode under delegatecall.
    address public immutable ADAPTER;

    /// @notice Emitted (in the Safe's context) when the Safe enters the exit queue and the ticket is registered.
    event ExitQueueEntered(address indexed account, address indexed vault, uint256 positionTicket, uint256 timestamp);
    /// @notice Emitted (in the Safe's context) when the Safe claims and the ticket is deregistered.
    event ExitedAssetsClaimed(
        address indexed account, address indexed vault, uint256 positionTicket, uint256 timestamp
    );

    /// @notice Thrown when an entrypoint that must be delegatecalled is called directly on the singleton.
    error NotDelegateCall();

    /// @dev Reverts unless the current call is a delegatecall (running in a caller's context, not the singleton's).
    ///      Under delegatecall `address(this)` is the caller Safe; on a direct call it is this deployment (`== SELF`,
    ///      the address pinned at construction). {enterExitQueue} / {claimExitedAssets} rely on running in the Safe's
    ///      context (so the vault sees `msg.sender = Safe`), so a direct call is always a mistake — fail loud here
    ///      instead of letting the vault revert obscurely.
    modifier onlyDelegateCall() {
        if (address(this) == SELF) revert NotDelegateCall();
        _;
    }

    /// @param adapter_ The {StakeWiseV3ExitQueueAssistedBalanceAdapter} to feed. Must be a contract.
    /// @param admin_   Holder of `DEFAULT_ADMIN_ROLE` — administers `DEPOSITOR_ROLE`. Required.
    constructor(address adapter_, address admin_) {
        if (adapter_ == address(0) || admin_ == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(adapter_, "ExitQueueAdapter");
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        SELF = address(this);
        ADAPTER = adapter_;
    }

    /// @notice Enter the StakeWise V3 exit queue for `vault` and register the resulting ticket on the adapter.
    ///         Mirrors the vault's `enterExitQueue(shares, receiver)`, with `vault` prepended and `receiver` dropped:
    ///         the receiver is always forced to the executing Safe (`address(this)`), so only the Safe can claim and
    ///         claimed assets are paid to it.
    /// @dev MUST be delegatecalled by the depositor Safe (enforced by {onlyDelegateCall}). Locks `shares` of the Safe's
    ///      `vault` shares into the queue.
    /// @param vault  StakeWise V3 vault.
    /// @param shares Vault shares to move into the exit queue (burned from the Safe).
    /// @return positionTicket The ticket assigned by the vault, now tracked on the adapter for the Safe.
    function enterExitQueue(address vault, uint256 shares) external onlyDelegateCall returns (uint256 positionTicket) {
        _requireDepositor();

        positionTicket = IStakeWiseVaultEnterExit(vault).enterExitQueue(shares, address(this));
        // Feed the adapter via the singleton (a real call to SELF), not directly, so the adapter's WRAPPER_ROLE is held
        // only by this wrapper — never by the depositor Safe. {submit} re-checks the depositor role + account.
        StakeWiseV3ExitQueueWrapper(SELF).submit(address(this), vault, positionTicket, block.timestamp);
        emit ExitQueueEntered(address(this), vault, positionTicket, block.timestamp);
    }

    /// @notice Forward one exit-queue ticket to the adapter for `account`. Runs on the wrapper **singleton** (so the
    ///         adapter call carries `msg.sender = this wrapper`, holder of the adapter's `WRAPPER_ROLE`). Invoked by
    ///         {enterExitQueue} via {SELF}, or standalone by an approved depositor. `onlyRole(DEPOSITOR_ROLE)` and
    ///         `account == msg.sender` — a depositor can only track its OWN tickets.
    /// @dev This is `external` by necessity: {enterExitQueue} runs in the Safe's context (delegatecall) and can only
    ///      reach the singleton — where the adapter must see `msg.sender = this wrapper` — through a real `CALL` to
    ///      {SELF}. That call is indistinguishable from a depositor calling this function directly (both carry
    ///      `msg.sender = the Safe`, and the EVM has no call-stack introspection), so this **cannot** be restricted to
    ///      "only via {enterExitQueue}". It doesn't need to be: the adapter re-validates every ticket live on-chain
    ///      (StakeWise-registered vault + non-zero owed for `account`), so a standalone call can only ever register a
    ///      real, account-owned, in-queue position — exactly what {enterExitQueue} would. See ADR 0019.
    function submit(address account, address vault, uint256 positionTicket, uint256 timestamp)
        external
        onlyRole(DEPOSITOR_ROLE)
    {
        if (account != msg.sender) revert NotAuthorized();
        IStakeWiseExitQueueTracker(ADAPTER).submit(account, vault, positionTicket, timestamp);
    }

    /// @notice Claim exited assets for a queue position and deregister its ticket from the adapter. Signature mirrors
    ///         the vault's `claimExitedAssets(positionTicket, timestamp, exitQueueIndex)`, with `vault` prepended.
    /// @dev MUST be delegatecalled by the depositor Safe (enforced by {onlyDelegateCall}; StakeWise keys the claim on
    ///      `msg.sender = Safe`). Claimed assets are paid to the Safe by the vault; the wrapper only forwards the call
    ///      and updates the adapter.
    /// @param vault          StakeWise V3 vault.
    /// @param positionTicket The exit position's ticket.
    /// @param timestamp      Entry timestamp (part of the exit-request key; the same value registered on `submit`).
    /// @param exitQueueIndex Checkpoint index for the position (from `getExitQueueIndex`).
    function claimExitedAssets(address vault, uint256 positionTicket, uint256 timestamp, uint256 exitQueueIndex)
        external
        onlyDelegateCall
    {
        _requireDepositor();

        IStakeWiseVaultEnterExit(vault).claimExitedAssets(positionTicket, timestamp, exitQueueIndex);
        // Deregister via the singleton (see {enterExitQueue}); keeps WRAPPER_ROLE off the depositor Safe.
        StakeWiseV3ExitQueueWrapper(SELF).remove(address(this), vault, positionTicket, timestamp);
        emit ExitedAssetsClaimed(address(this), vault, positionTicket, timestamp);
    }

    /// @notice Deregister one exit-queue ticket from the adapter for `account`. Runs on the wrapper singleton; same
    ///         gating as {submit} (`onlyRole(DEPOSITOR_ROLE)` + `account == msg.sender`). Invoked by
    ///         {claimExitedAssets} via {SELF}, or standalone by an approved depositor.
    /// @dev `external` for the same delegatecall reason as {submit}, and likewise not restrictable to "only via
    ///      {claimExitedAssets}". Deregistering keeps NAV within the family's under-report-only invariant, and stale
    ///      tickets already read as 0 anyway.
    function remove(address account, address vault, uint256 positionTicket, uint256 timestamp)
        external
        onlyRole(DEPOSITOR_ROLE)
    {
        if (account != msg.sender) revert NotAuthorized();
        IStakeWiseExitQueueTracker(ADAPTER).remove(account, vault, positionTicket, timestamp);
    }

    /// @dev Delegatecall-safe `DEPOSITOR_ROLE` gate: checks the executing Safe (`address(this)`) against the wrapper
    ///      singleton's real role storage via {SELF}. Reverts {NotAuthorized} if the Safe is not an approved depositor.
    function _requireDepositor() private view {
        if (!IAccessControl(SELF).hasRole(DEPOSITOR_ROLE, address(this))) revert NotAuthorized();
    }
}

/// @notice Minimal interface for a StakeWise V3 vault's exit-queue mutators.
interface IStakeWiseVaultEnterExit {
    /// @notice Locks `shares` into the exit queue for `receiver`; returns the position ticket.
    function enterExitQueue(uint256 shares, address receiver) external returns (uint256 positionTicket);

    /// @notice Claims assets that were withdrawn by the vault. Callable only by the `receiver` from `enterExitQueue`.
    function claimExitedAssets(uint256 positionTicket, uint256 timestamp, uint256 exitQueueIndex) external;
}

/// @notice Minimal interface for the wrapper-fed balance adapter's tracking mutators.
interface IStakeWiseExitQueueTracker {
    function submit(address account, address vault, uint256 positionTicket, uint256 timestamp) external;
    function remove(address account, address vault, uint256 positionTicket, uint256 timestamp) external;
}
