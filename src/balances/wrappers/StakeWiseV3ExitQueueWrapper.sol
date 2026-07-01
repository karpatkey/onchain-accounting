// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title StakeWise V3 Exit-Queue Wrapper
/// @author KPK
/// @notice A thin, **permissionless delegatecall action** contract that a depositor Safe delegatecalls to enter / exit
///         the StakeWise V3 exit queue and, in the *same* transaction, register / deregister the resulting
///         `positionTicket` on {StakeWiseV3ExitQueueAssistedBalanceAdapter} so the queued value stays visible to NAV.
///         StakeWise exit positions are not enumerable and StakeWise keys `claimExitedAssets` on `msg.sender`, so the
///         Safe must be both the `receiver` and the claimer — which is exactly what delegatecall gives: the wrapper's
///         code runs in the Safe's context, so `address(this)` is the Safe, the vault sees `msg.sender = Safe`, the
///         exit position is owned by the Safe, and claimed assets are paid to the Safe. No custody or asset-forwarding
///         logic is needed.
/// @dev **No access control.** The wrapper is a stateless action library: which Safe may run it is governed by that
///      Safe's own permission system (e.g. a Zodiac Roles module), not here. It holds no roles and no admin. Because it
///      is delegatecalled, {enterExitQueue} / {claimExitedAssets} run against the *caller's* (Safe's) storage, so they
///      perform **no storage writes**. They feed the adapter with a direct call — the adapter is likewise
///      permissionless and self-scopes by `msg.sender`, so the wrapper's call (carrying `msg.sender = the Safe`) tracks
///      exactly the Safe's own positions, and no third party can register/deregister for another account. The adapter
///      re-validates every ticket live on-chain (StakeWise-registered vault + non-zero owed for the account), so the
///      family invariant (ADR 0015) holds: a caller can only under-report, never over-report. See
///      `docs/decisions/0019-stakewise-v3-exit-queue-wrapper.md` (StakeWise-specific instance of the wrapper-fed
///      assisted family, ADR 0018).
contract StakeWiseV3ExitQueueWrapper {
    /// @notice This wrapper's own deployment address, pinned at construction. Under delegatecall `address(this)` is the
    ///         caller Safe; comparing against this fixed value is how {onlyDelegateCall} detects a direct call.
    address public immutable SELF;

    /// @notice The balance adapter fed by this wrapper ({StakeWiseV3ExitQueueAssistedBalanceAdapter}). Immutable, so it
    ///         is readable from the wrapper's bytecode under delegatecall.
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
    constructor(address adapter_) {
        if (adapter_ == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(adapter_, "ExitQueueAdapter");
        SELF = address(this);
        ADAPTER = adapter_;
    }

    /// @notice Enter the StakeWise V3 exit queue for `vault` and register the resulting ticket on the adapter.
    ///         Mirrors the vault's `enterExitQueue(shares, receiver)`, with `vault` prepended and `receiver` dropped:
    ///         the receiver is always forced to the executing Safe (`address(this)`), so only the Safe can claim and
    ///         claimed assets are paid to it.
    /// @dev MUST be delegatecalled by the depositor Safe (enforced by {onlyDelegateCall}). Locks `shares` of the Safe's
    ///      `vault` shares into the queue. The adapter call carries `msg.sender = the Safe`, so the Safe's own position
    ///      is tracked.
    /// @param vault  StakeWise V3 vault.
    /// @param shares Vault shares to move into the exit queue (burned from the Safe).
    /// @return positionTicket The ticket assigned by the vault, now tracked on the adapter for the Safe.
    function enterExitQueue(address vault, uint256 shares) external onlyDelegateCall returns (uint256 positionTicket) {
        positionTicket = IStakeWiseVaultEnterExit(vault).enterExitQueue(shares, address(this));
        IStakeWiseExitQueueTracker(ADAPTER).submit(vault, positionTicket, block.timestamp);
        emit ExitQueueEntered(address(this), vault, positionTicket, block.timestamp);
    }

    /// @notice Claim exited assets for a queue position and deregister its ticket from the adapter. Signature mirrors
    ///         the vault's `claimExitedAssets(positionTicket, timestamp, exitQueueIndex)`, with `vault` prepended.
    /// @dev MUST be delegatecalled by the depositor Safe (enforced by {onlyDelegateCall}; StakeWise keys the claim on
    ///      `msg.sender = Safe`). Claimed assets are paid to the Safe by the vault; the wrapper only forwards the call
    ///      and updates the adapter.
    /// @param vault          StakeWise V3 vault.
    /// @param positionTicket The exit position's ticket.
    /// @param timestamp      Entry timestamp (part of the exit-request key; the same value registered on enter).
    /// @param exitQueueIndex Checkpoint index for the position (from `getExitQueueIndex`).
    function claimExitedAssets(address vault, uint256 positionTicket, uint256 timestamp, uint256 exitQueueIndex)
        external
        onlyDelegateCall
    {
        IStakeWiseVaultEnterExit(vault).claimExitedAssets(positionTicket, timestamp, exitQueueIndex);
        IStakeWiseExitQueueTracker(ADAPTER).remove(vault, positionTicket, timestamp);
        emit ExitedAssetsClaimed(address(this), vault, positionTicket, timestamp);
    }
}

/// @notice Minimal interface for a StakeWise V3 vault's exit-queue mutators.
interface IStakeWiseVaultEnterExit {
    /// @notice Locks `shares` into the exit queue for `receiver`; returns the position ticket.
    function enterExitQueue(uint256 shares, address receiver) external returns (uint256 positionTicket);

    /// @notice Claims assets that were withdrawn by the vault. Callable only by the `receiver` from `enterExitQueue`.
    function claimExitedAssets(uint256 positionTicket, uint256 timestamp, uint256 exitQueueIndex) external;
}

/// @notice Minimal interface for the wrapper-fed balance adapter's tracking mutators (self-scoped to `msg.sender`).
interface IStakeWiseExitQueueTracker {
    function submit(address vault, uint256 positionTicket, uint256 timestamp) external;
    function remove(address vault, uint256 positionTicket, uint256 timestamp) external;
}
