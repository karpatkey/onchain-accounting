// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BalanceAdapterAssistant} from "src/balances/AssistedBalanceAdapters/assistants/BalanceAdapterAssistant.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title NexusMutualStakingPoolsAssistant
/// @author KPK
/// @notice **Delegatecall-only** logic module the staking **account** (e.g. an OIV Safe) delegatecalls to stake into
///         Nexus Mutual V2 pools while keeping the assistant-fed {NexusMutualStakingPoolsAssistedBalanceAdapter} id-cache
///         current, atomically: `depositTo` forwards to the pool and `submit`s the resulting StakingNFT `tokenId`;
///         `withdraw` forwards and `remove`s it.
/// @dev Extends {BalanceAdapterAssistant} for the `SELF` / {onlyDelegateCall} guard and immutable `ADAPTER`. Because it
///      runs via `delegatecall`, `address(this)` is the calling account throughout — so the module needs no token
///      custody and no Nexus membership of its own: the account holds the NXM, is the member, and owns the minted NFT.
///      There is no `transferFrom`; the account's own NXM is staked directly (`depositTo(destination = address(this))`),
///      and the position is tracked/untracked for the account (the adapter's `msg.sender`-keyed cache sees the account).
///      The module only sets the account's NXM allowance to the `TOKEN_CONTROLLER`. On `withdraw` the id is popped only
///      once the position is fully emptied: the adapter's {_removable} is value-based, so a *partial* / rewards-only
///      withdrawal (leaving live stake) reverts `CoordinateStillLive`, which the module swallows to keep the residual
///      tracked. See [ADR 0018](../../../../docs/decisions/0018-assistant-fed-assisted-balance-adapters.md).
contract NexusMutualStakingPoolsAssistant is BalanceAdapterAssistant {
    using SafeERC20 for IERC20;

    /// @notice NXM token (staked from the calling account, pulled by Nexus via the TokenController operator transfer).
    address public immutable NXM;

    /// @notice Nexus TokenController — the NXM `operator`. `depositTo` approves it the exact `amount` from the account.
    address public immutable TOKEN_CONTROLLER;

    /// @param adapter_         The assistant-fed {NexusMutualStakingPoolsAssistedBalanceAdapter}. Must be a contract.
    /// @param nxm_             NXM token. Must be a contract.
    /// @param tokenController_ Nexus TokenController (the NXM operator). Must be a contract.
    constructor(address adapter_, address nxm_, address tokenController_) BalanceAdapterAssistant(adapter_) {
        if (nxm_ == address(0) || tokenController_ == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(nxm_, "NXM");
        AddressCheckLib.requireContract(tokenController_, "TokenController");
        NXM = nxm_;
        TOKEN_CONTROLLER = tokenController_;
    }

    /// @notice Stake `amount` NXM (the calling account's own) into pool `poolAddress` and track the resulting
    ///         StakingNFT for the account. Mirrors the Nexus pool's `depositTo` with `poolAddress` prepended and
    ///         `destination` forced to `address(this)` (the calling account). **Delegatecall-only.**
    /// @param poolAddress    The Nexus staking pool.
    /// @param amount         NXM to stake (from the calling account's balance).
    /// @param trancheId      Target tranche.
    /// @param requestTokenId 0 to mint a new StakingNFT, or an existing id (owned by the account) to top it up.
    /// @return tokenId The minted/topped-up StakingNFT id (tracked for `address(this)`).
    function depositTo(address poolAddress, uint256 amount, uint256 trancheId, uint256 requestTokenId)
        external
        onlyDelegateCall
        returns (uint256 tokenId)
    {
        // Approve the TokenController (NXM operator) for the exact amount: the deployed NXM's operatorTransfer runs
        // through _transferFrom, which decrements the operator's allowance from address(this) (the account).
        IERC20(NXM).forceApprove(TOKEN_CONTROLLER, amount);
        // destination = address(this): the account stakes its own NXM and owns the minted NFT, so the adapter's live
        // ownership re-verification always passes for it.
        tokenId = INexusMutualStakingPool(poolAddress).depositTo(amount, trancheId, requestTokenId, address(this));
        // msg.sender seen by the adapter is the account (address(this)), so it caches the id for the account.
        INexusMutualStakingPoolsAssistedBalanceAdapter(ADAPTER).submit(tokenId);
    }

    /// @notice Withdraw stake and/or rewards from `tokenId` in pool `poolAddress` (to the account, which owns it) and
    ///         stop tracking `tokenId`. Mirrors the Nexus pool's `withdraw` with `poolAddress` prepended.
    ///         **Delegatecall-only.**
    /// @param poolAddress     The Nexus staking pool.
    /// @param tokenId         The StakingNFT to withdraw from.
    /// @param withdrawStake   Withdraw unlocked stake.
    /// @param withdrawRewards Withdraw accrued rewards.
    /// @param trancheIds      Tranches to withdraw from.
    /// @return withdrawnStake   NXM stake withdrawn.
    /// @return withdrawnRewards NXM rewards withdrawn.
    function withdraw(
        address poolAddress,
        uint256 tokenId,
        bool withdrawStake,
        bool withdrawRewards,
        uint256[] calldata trancheIds
    ) external onlyDelegateCall returns (uint256 withdrawnStake, uint256 withdrawnRewards) {
        (withdrawnStake, withdrawnRewards) =
            INexusMutualStakingPool(poolAddress).withdraw(tokenId, withdrawStake, withdrawRewards, trancheIds);
        // Untrack only once the position is fully emptied. Nexus does not burn the StakingNFT, so a partial or
        // rewards-only withdraw leaves live stake — the adapter then reverts `CoordinateStillLive`, which we swallow
        // and keep the id tracked (its residual stays valued; a later full withdraw re-syncs it). Any other revert
        // (e.g. `CoordinateNotCached` for an untracked id) bubbles up.
        try INexusMutualStakingPoolsAssistedBalanceAdapter(ADAPTER).remove(tokenId) {}
        catch (bytes memory reason) {
            if (bytes4(reason) != CoordinateStillLive.selector) {
                assembly {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }
    }
}

/// @notice Minimal interface for a Nexus Mutual StakingPool — only the two functions the assistant forwards.
interface INexusMutualStakingPool {
    function depositTo(uint256 amount, uint256 trancheId, uint256 requestTokenId, address destination)
        external
        returns (uint256 tokenId);

    function withdraw(uint256 tokenId, bool withdrawStake, bool withdrawRewards, uint256[] memory trancheIds)
        external
        returns (uint256 withdrawnStake, uint256 withdrawnRewards);
}

/// @notice Minimal interface for the assistant-fed balance adapter's feed surface (keyed on `msg.sender`).
interface INexusMutualStakingPoolsAssistedBalanceAdapter {
    function submit(uint256 tokenId) external;
    function remove(uint256 tokenId) external;
}
