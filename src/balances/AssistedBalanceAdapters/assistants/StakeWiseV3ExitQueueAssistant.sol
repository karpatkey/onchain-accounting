// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterAssistant} from "src/balances/AssistedBalanceAdapters/assistants/BalanceAdapterAssistant.sol";

/// @title StakeWise V3 Exit-Queue Assistant
/// @author KPK
/// @notice Delegatecall-only action a depositor Safe delegatecalls to enter / exit the StakeWise V3 exit queue and, in
///         the same transaction, register / deregister the resulting `positionTicket` on
///         {StakeWiseV3ExitQueueAssistedBalanceAdapter} so the queued value stays visible to NAV. StakeWise keys
///         `claimExitedAssets` on `msg.sender` and vault shares are non-transferable, so the Safe must be both the
///         `receiver` and the claimer — exactly what delegatecall gives: the assistant's code runs in the Safe's context,
///         so `address(this)` is the Safe, the vault sees `msg.sender = Safe`, and the exit position is owned by (and
///         claimed to) the Safe. No custody, no asset-forwarding.
/// @dev Extends {BalanceAdapterAssistant} for the `SELF` / {onlyDelegateCall} guard and immutable `ADAPTER`. No token
///      approval is needed (shares live in the vault). The adapter is permissionless and self-scopes by `msg.sender`,
///      so the assistant's call (carrying `msg.sender = the Safe`) tracks exactly the Safe's own positions. See
///      [ADR 0018](../../../../docs/decisions/0018-assistant-fed-assisted-balance-adapters.md).
contract StakeWiseV3ExitQueueAssistant is BalanceAdapterAssistant {
    /// @notice Emitted (in the Safe's context) when the Safe enters the exit queue and the ticket is registered.
    event ExitQueueEntered(address indexed account, address indexed vault, uint256 positionTicket, uint256 timestamp);
    /// @notice Emitted (in the Safe's context) when the Safe claims and the ticket is deregistered.
    event ExitedAssetsClaimed(
        address indexed account, address indexed vault, uint256 positionTicket, uint256 timestamp
    );
    /// @notice Emitted (in the Safe's context) when the vault was not collateralized: StakeWise redeemed the shares
    ///         immediately (assets paid, no exit request), so there is no ticket to register.
    event RedeemedImmediately(address indexed account, address indexed vault, uint256 shares);
    /// @notice Emitted (in the Safe's context) when a partial claim re-queued the remainder under `newPositionTicket`
    ///         (same `timestamp`) and the assistant registered it — `tracked = false` if registering it failed (the claim
    ///         still went through; the keeper can file the remainder with `submitFor`, except when the cache is full —
    ///         then the owner frees a slot first with `evict` / `clearAccount`).
    event RemainderRequeued(
        address indexed account,
        address indexed vault,
        uint256 positionTicket,
        uint256 newPositionTicket,
        uint256 timestamp,
        bool tracked
    );

    /// @param adapter_ The {StakeWiseV3ExitQueueAssistedBalanceAdapter} to feed. Must be a contract.
    constructor(address adapter_) BalanceAdapterAssistant(adapter_) {}

    /// @notice Enter the StakeWise V3 exit queue for `vault` and register the resulting ticket on the adapter. Mirrors
    ///         the vault's `enterExitQueue(shares, receiver)`, with `vault` prepended and `receiver` forced to the
    ///         executing Safe (`address(this)`). **Delegatecall-only.**
    /// @param vault  StakeWise V3 vault.
    /// @param shares Vault shares to move into the exit queue (burned from the Safe).
    /// @return positionTicket The ticket assigned by the vault, now tracked on the adapter for the Safe.
    function enterExitQueue(address vault, uint256 shares) external onlyDelegateCall returns (uint256 positionTicket) {
        positionTicket = IStakeWiseVaultEnterExit(vault).enterExitQueue(shares, address(this));
        // An uncollateralized vault redeems on the spot and returns type(uint256).max instead of a ticket — nothing is
        // queued, so registering it would revert (CoordinateNotOwned) and block the Safe's only allow-listed exit path.
        if (positionTicket == type(uint256).max) {
            emit RedeemedImmediately(address(this), vault, shares);
            return positionTicket;
        }
        IStakeWiseV3ExitQueueAssistedBalanceAdapter(ADAPTER).submit(vault, positionTicket, block.timestamp);
        emit ExitQueueEntered(address(this), vault, positionTicket, block.timestamp);
    }

    /// @notice Claim exited assets for a queue position, deregister its ticket, and — on a PARTIAL claim — register
    ///         the remainder. StakeWise deletes the request under `positionTicket` on every claim and, when more than one
    ///         ticket is left, re-queues the remainder under `positionTicket + exitedTickets` with the SAME `timestamp`;
    ///         registering that new ticket here keeps the unclaimed rest in the NAV without waiting for a keeper. Mirrors
    ///         the vault's `claimExitedAssets(positionTicket, timestamp, exitQueueIndex)`, with `vault` prepended.
    ///         **Delegatecall-only** (StakeWise keys the claim on `msg.sender = Safe`).
    /// @param vault          StakeWise V3 vault.
    /// @param positionTicket The exit position's ticket.
    /// @param timestamp      Entry timestamp (part of the exit-request key; the same value registered on enter).
    /// @param exitQueueIndex Checkpoint index for the position (from `getExitQueueIndex`).
    function claimExitedAssets(address vault, uint256 positionTicket, uint256 timestamp, uint256 exitQueueIndex)
        external
        onlyDelegateCall
    {
        // Same call, same state, same tx as the vault's own claim math → the exact split the claim will apply.
        (uint256 leftTickets, uint256 exitedTickets,) = IStakeWiseVaultEnterExit(vault)
            .calculateExitedAssets(address(this), positionTicket, timestamp, exitQueueIndex);
        IStakeWiseVaultEnterExit(vault).claimExitedAssets(positionTicket, timestamp, exitQueueIndex);
        // Best-effort deregister — never block the claim itself. The claim deleted the request under this ticket, so the
        // adapter normally removes it; an untracked ticket reverts `CoordinateNotCached` (nothing to untrack).
        // {_bubbleUnlessCacheRevert} swallows the cache reverts and re-throws anything else.
        try IStakeWiseV3ExitQueueAssistedBalanceAdapter(ADAPTER).remove(vault, positionTicket, timestamp) {}
        catch (bytes memory reason) {
            _bubbleUnlessCacheRevert(reason);
        }
        emit ExitedAssetsClaimed(address(this), vault, positionTicket, timestamp);
        // StakeWise re-queues only when MORE than one ticket is left (a single leftover ticket is a rounding error it
        // drops), mirroring `claimExitedAssets`'s own `leftTickets > 1` test on the values just read.
        if (leftTickets > 1 && exitedTickets > 0) {
            uint256 newPositionTicket = positionTicket + exitedTickets;
            bool tracked;
            // Never block the claim: a failed registration is reported (tracked = false). The keeper can file it with
            // `submitFor` — unless the cause was a full cache, which only the owner's `evict` / `clearAccount` frees.
            try IStakeWiseV3ExitQueueAssistedBalanceAdapter(ADAPTER).submit(vault, newPositionTicket, timestamp) {
                tracked = true;
            } catch {}
            emit RemainderRequeued(address(this), vault, positionTicket, newPositionTicket, timestamp, tracked);
        }
    }
}

/// @notice Minimal interface for a StakeWise V3 vault's exit-queue mutators.
interface IStakeWiseVaultEnterExit {
    /// @notice Locks `shares` into the exit queue for `receiver`; returns the position ticket.
    function enterExitQueue(uint256 shares, address receiver) external returns (uint256 positionTicket);

    /// @notice Claims assets that were withdrawn by the vault. Callable only by the `receiver` from `enterExitQueue`.
    function claimExitedAssets(uint256 positionTicket, uint256 timestamp, uint256 exitQueueIndex) external;

    /// @notice For the request keyed by `(receiver, timestamp, positionTicket)`: tickets still queued, tickets exited, and
    ///         the assets those exited tickets are worth.
    function calculateExitedAssets(address receiver, uint256 positionTicket, uint256 timestamp, uint256 exitQueueIndex)
        external
        view
        returns (uint256 leftTickets, uint256 exitedTickets, uint256 exitedAssets);
}

/// @notice Minimal interface for the assistant-fed balance adapter's tracking mutators (self-scoped to `msg.sender`).
interface IStakeWiseV3ExitQueueAssistedBalanceAdapter {
    function submit(address vault, uint256 positionTicket, uint256 timestamp) external;
    function remove(address vault, uint256 positionTicket, uint256 timestamp) external;
}
