// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterWrapper} from "src/balances/wrappers/BalanceAdapterWrapper.sol";

/// @title StakeWise V3 Exit-Queue Wrapper
/// @author KPK
/// @notice Delegatecall-only action a depositor Safe delegatecalls to enter / exit the StakeWise V3 exit queue and, in
///         the same transaction, register / deregister the resulting `positionTicket` on
///         {StakeWiseV3ExitQueueAssistedBalanceAdapter} so the queued value stays visible to NAV. StakeWise keys
///         `claimExitedAssets` on `msg.sender` and vault shares are non-transferable, so the Safe must be both the
///         `receiver` and the claimer — exactly what delegatecall gives: the wrapper's code runs in the Safe's context,
///         so `address(this)` is the Safe, the vault sees `msg.sender = Safe`, and the exit position is owned by (and
///         claimed to) the Safe. No custody, no asset-forwarding.
/// @dev Extends {BalanceAdapterWrapper} for the `SELF` / {onlyDelegateCall} guard and immutable `ADAPTER`. No token
///      approval is needed (shares live in the vault). The adapter is permissionless and self-scopes by `msg.sender`,
///      so the wrapper's call (carrying `msg.sender = the Safe`) tracks exactly the Safe's own positions. See
///      [ADR 0018](../../../docs/decisions/0018-wrapper-fed-assisted-balance-adapters.md).
contract StakeWiseV3ExitQueueWrapper is BalanceAdapterWrapper {
    /// @notice Emitted (in the Safe's context) when the Safe enters the exit queue and the ticket is registered.
    event ExitQueueEntered(address indexed account, address indexed vault, uint256 positionTicket, uint256 timestamp);
    /// @notice Emitted (in the Safe's context) when the Safe claims and the ticket is deregistered.
    event ExitedAssetsClaimed(address indexed account, address indexed vault, uint256 positionTicket, uint256 timestamp);

    /// @param adapter_ The {StakeWiseV3ExitQueueAssistedBalanceAdapter} to feed. Must be a contract.
    constructor(address adapter_) BalanceAdapterWrapper(adapter_) {}

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

    /// @notice Claim exited assets for a queue position and deregister its ticket. Mirrors the vault's
    ///         `claimExitedAssets(positionTicket, timestamp, exitQueueIndex)`, with `vault` prepended.
    ///         **Delegatecall-only** (StakeWise keys the claim on `msg.sender = Safe`).
    /// @param vault          StakeWise V3 vault.
    /// @param positionTicket The exit position's ticket.
    /// @param timestamp      Entry timestamp (part of the exit-request key; the same value registered on enter).
    /// @param exitQueueIndex Checkpoint index for the position (from `getExitQueueIndex`).
    function claimExitedAssets(address vault, uint256 positionTicket, uint256 timestamp, uint256 exitQueueIndex)
        external
        onlyDelegateCall
    {
        IStakeWiseVaultEnterExit(vault).claimExitedAssets(positionTicket, timestamp, exitQueueIndex);
        IStakeWiseV3ExitQueueAssistedBalanceAdapter(ADAPTER).remove(vault, positionTicket, timestamp);
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
interface IStakeWiseV3ExitQueueAssistedBalanceAdapter {
    function submit(address vault, uint256 positionTicket, uint256 timestamp) external;
    function remove(address vault, uint256 positionTicket, uint256 timestamp) external;
}
