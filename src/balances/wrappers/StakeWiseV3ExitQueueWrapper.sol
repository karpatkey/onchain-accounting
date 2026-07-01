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
/// @dev **Delegatecall-only design.** Because the wrapper executes against the *caller's* (Safe's) storage:
///      - it performs **no storage writes** in {enterExitQueue} / {claimExitedAssets} (a write would corrupt Safe
///        storage), and
///      - its `DEPOSITOR_ROLE` gate cannot use the inherited `onlyRole` modifier (that reads Safe storage). Instead it
///        checks the role against the wrapper **singleton's own** storage via the immutable {SELF} (bytecode-embedded,
///        so readable under delegatecall): `IAccessControl(SELF).hasRole(DEPOSITOR_ROLE, address(this))` — i.e. "is the
///        executing Safe an approved depositor?". Admins grant/revoke `DEPOSITOR_ROLE` by calling the singleton
///        directly (a normal, non-delegatecall transaction, where the inherited AccessControl machinery applies).
///      See `docs/decisions/0019-stakewise-v3-exit-queue-wrapper.md` (StakeWise-specific instance of the wrapper-fed
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
    ///         Signature mirrors the vault's `enterExitQueue(shares, receiver)`, with `vault` prepended.
    /// @dev MUST be delegatecalled by the depositor Safe. `receiver` must be the executing Safe (`address(this)`) — the
    ///      exit position and its future claim/assets belong to the receiver, and only the Safe can claim; a different
    ///      receiver would strand the position. Locks `shares` of the Safe's `vault` shares into the exit queue.
    /// @param vault    StakeWise V3 vault.
    /// @param shares   Vault shares to move into the exit queue (burned from the Safe).
    /// @param receiver Must equal `address(this)` (the executing Safe).
    /// @return positionTicket The ticket assigned by the vault, now tracked on the adapter for the Safe.
    function enterExitQueue(address vault, uint256 shares, address receiver) external returns (uint256 positionTicket) {
        _requireDepositor();
        if (receiver != address(this)) revert InvalidArguments();

        positionTicket = IStakeWiseVaultEnterExit(vault).enterExitQueue(shares, address(this));
        IStakeWiseExitQueueTracker(ADAPTER).submit(address(this), vault, positionTicket, block.timestamp);
        emit ExitQueueEntered(address(this), vault, positionTicket, block.timestamp);
    }

    /// @notice Claim exited assets for a queue position and deregister its ticket from the adapter. Signature mirrors
    ///         the vault's `claimExitedAssets(positionTicket, timestamp, exitQueueIndex)`, with `vault` prepended.
    /// @dev MUST be delegatecalled by the depositor Safe (StakeWise keys the claim on `msg.sender = Safe`). Claimed
    ///      assets are paid to the Safe by the vault; the wrapper only forwards the call and updates the adapter.
    /// @param vault          StakeWise V3 vault.
    /// @param positionTicket The exit position's ticket.
    /// @param timestamp      Entry timestamp (part of the exit-request key; the same value registered on `submit`).
    /// @param exitQueueIndex Checkpoint index for the position (from `getExitQueueIndex`).
    function claimExitedAssets(address vault, uint256 positionTicket, uint256 timestamp, uint256 exitQueueIndex)
        external
    {
        _requireDepositor();

        IStakeWiseVaultEnterExit(vault).claimExitedAssets(positionTicket, timestamp, exitQueueIndex);
        IStakeWiseExitQueueTracker(ADAPTER).remove(address(this), vault, positionTicket, timestamp);
        emit ExitedAssetsClaimed(address(this), vault, positionTicket, timestamp);
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
