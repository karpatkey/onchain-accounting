// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterAssistant} from "src/balances/AssistedBalanceAdapters/assistants/BalanceAdapterAssistant.sol";
import {CoordinateStillLive} from "src/errors.sol";

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
        IStakeWiseV3ExitQueueAssistedBalanceAdapter(ADAPTER).submit(vault, positionTicket, block.timestamp);
        emit ExitQueueEntered(address(this), vault, positionTicket, block.timestamp);
    }

    /// @notice Claim exited assets for a queue position and deregister its ticket **once fully consumed** (a partial
    ///         claim keeps the ticket tracked for its residual). Mirrors the vault's `claimExitedAssets(positionTicket,
    ///         timestamp, exitQueueIndex)`, with `vault` prepended. **Delegatecall-only** (StakeWise keys the claim on
    ///         `msg.sender = Safe`).
    /// @param vault          StakeWise V3 vault.
    /// @param positionTicket The exit position's ticket.
    /// @param timestamp      Entry timestamp (part of the exit-request key; the same value registered on enter).
    /// @param exitQueueIndex Checkpoint index for the position (from `getExitQueueIndex`).
    function claimExitedAssets(address vault, uint256 positionTicket, uint256 timestamp, uint256 exitQueueIndex)
        external
        onlyDelegateCall
    {
        IStakeWiseVaultEnterExit(vault).claimExitedAssets(positionTicket, timestamp, exitQueueIndex);
        // Deregister only once the ticket is fully consumed. A partial claim leaves owed shares under this ticket, so
        // the adapter reverts `CoordinateStillLive` — swallow that and keep it tracked (its residual stays valued);
        // any other revert (e.g. `CoordinateNotCached`) bubbles up. NOTE: StakeWise re-queues a not-yet-checkpointed
        // remainder under a NEW ticket; that new ticket is a distinct coordinate the caller must `submit` (from the
        // vault's re-queue event) — this assistant only manages the ticket it was given.
        try IStakeWiseV3ExitQueueAssistedBalanceAdapter(ADAPTER).remove(vault, positionTicket, timestamp) {}
        catch (bytes memory reason) {
            if (bytes4(reason) != CoordinateStillLive.selector) {
                assembly {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }
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

/// @notice Minimal interface for the assistant-fed balance adapter's tracking mutators (self-scoped to `msg.sender`).
interface IStakeWiseV3ExitQueueAssistedBalanceAdapter {
    function submit(address vault, uint256 positionTicket, uint256 timestamp) external;
    function remove(address vault, uint256 positionTicket, uint256 timestamp) external;
}
