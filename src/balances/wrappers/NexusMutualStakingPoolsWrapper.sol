// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title NexusMutualStakingPoolsWrapper
/// @author KPK
/// @notice **Delegatecall-only** logic module for staking into Nexus Mutual V2 pools while keeping the wrapper-fed
///         {NexusMutualStakingPoolsAssistedBalanceAdapter} id-cache current, atomically. It is meant to be
///         `delegatecall`ed by the staking **account** (e.g. an OIV Safe): `depositTo` forwards to the pool and pushes
///         the returned StakingNFT `tokenId` into the adapter for the account; `withdraw` forwards and pops it. Both
///         functions revert on a direct call (see {onlyDelegateCall}).
/// @dev Because it runs via `delegatecall`, `address(this)` is the **calling account** throughout — so the module needs
///      no token custody and no membership of its own: the account already holds the NXM, is the Nexus member, and
///      owns the minted StakingNFT. This is what "simplifies the logic": there is **no `transferFrom`** — the account's
///      own NXM is staked directly (`pool.depositTo(destination = address(this))` → `TokenController.operatorTransfer`
///      pulls from `address(this)`), and the position is tracked/untracked for `address(this)`. The module only sets
///      the account's NXM allowance to the `TOKEN_CONTROLLER` (the deployed NXM's `operatorTransfer` runs through
///      `_transferFrom`, which decrements `_allowed[account][operator]`, so a zero allowance would underflow-revert).
///
///      **Requirements on the calling account** (all satisfied by a normal Nexus-member Safe): it must hold the NXM,
///      be a whitelisted Nexus member, and hold `SUBMITTER_ROLE` on the adapter — because the adapter's
///      `submit`/`remove` are invoked with `msg.sender == address(this)` (the account). The account should
///      `delegatecall` this module rather than calling it directly.
///
///      On `withdraw`, Nexus routes the withdrawn stake + rewards to `StakingNFT.ownerOf(tokenId)` (the account) and is
///      permissionless. `withdraw` pops the `tokenId` unconditionally; because Nexus does not burn the `StakingNFT` on
///      withdraw, a *partial* withdrawal stops tracking any remaining stake (a safe under-report per ADR 0015 — a later
///      top-up re-adds the id).
contract NexusMutualStakingPoolsWrapper {
    using SafeERC20 for IERC20;

    /// @notice This module's own deployed address, captured at construction. Under `delegatecall`, `address(this)` is
    ///         the calling account (≠ `SELF`); a direct call has `address(this) == SELF`. Used to enforce delegatecall.
    address private immutable SELF;

    /// @notice The wrapper-fed balance adapter fed by the calling account (which must hold `SUBMITTER_ROLE` on it).
    address public immutable ADAPTER;

    /// @notice NXM token (staked from the calling account, pulled by Nexus via the TokenController operator transfer).
    address public immutable NXM;

    /// @notice Nexus TokenController — the NXM `operator`. `depositTo` approves it the exact `amount` from the calling
    ///         account each call (the deployed NXM's `operatorTransfer` consumes this allowance).
    address public immutable TOKEN_CONTROLLER;

    /// @param adapter_         The wrapper-fed {NexusMutualStakingPoolsAssistedBalanceAdapter}. Must be a contract.
    /// @param nxm_             NXM token. Must be a contract.
    /// @param tokenController_ Nexus TokenController (the NXM operator). Must be a contract.
    constructor(address adapter_, address nxm_, address tokenController_) {
        if (adapter_ == address(0) || nxm_ == address(0) || tokenController_ == address(0)) {
            revert InvalidArguments();
        }
        AddressCheckLib.requireContract(adapter_, "adapter");
        AddressCheckLib.requireContract(nxm_, "NXM");
        AddressCheckLib.requireContract(tokenController_, "TokenController");

        SELF = address(this);
        ADAPTER = adapter_;
        NXM = nxm_;
        TOKEN_CONTROLLER = tokenController_;
    }

    /// @notice Reverts unless the function is reached via `delegatecall` (i.e. `address(this)` is the calling account,
    ///         not this module's own deployed address).
    modifier onlyDelegateCall() {
        if (address(this) == SELF) revert OnlyDelegateCall();
        _;
    }

    /// @notice Stake `amount` NXM (the calling account's own) into pool `poolAddress` and track the resulting
    ///         StakingNFT for the account. Mirrors the Nexus pool's `depositTo` with `poolAddress` prepended and
    ///         `destination` omitted — the NFT is always minted/topped-up to `address(this)` (the calling account).
    ///         **Delegatecall-only.**
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
        // through _transferFrom, which decrements the operator's allowance from `address(this)` (the account).
        IERC20(NXM).forceApprove(TOKEN_CONTROLLER, amount);
        // destination = address(this): the account stakes its own NXM and owns the minted NFT, so the adapter's live
        // ownership re-verification always passes for it.
        tokenId = INexusStakingPool(poolAddress).depositTo(amount, trancheId, requestTokenId, address(this));
        INexusStakingPoolsBalanceAdapterFeed(ADAPTER).submit(address(this), tokenId);
    }

    /// @notice Withdraw stake and/or rewards from `tokenId` in pool `poolAddress` (to the account, which owns it) and
    ///         stop tracking `tokenId` for the account. Mirrors the Nexus pool's `withdraw` with `poolAddress`
    ///         prepended. **Delegatecall-only.**
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
            INexusStakingPool(poolAddress).withdraw(tokenId, withdrawStake, withdrawRewards, trancheIds);
        INexusStakingPoolsBalanceAdapterFeed(ADAPTER).remove(address(this), tokenId);
    }
}

/// @notice Raised when a delegatecall-only function is called directly (not via `delegatecall`).
error OnlyDelegateCall();

/// @notice Minimal interface for a Nexus Mutual StakingPool — only the two functions the wrapper forwards.
interface INexusStakingPool {
    function depositTo(uint256 amount, uint256 trancheId, uint256 requestTokenId, address destination)
        external
        returns (uint256 tokenId);

    function withdraw(uint256 tokenId, bool withdrawStake, bool withdrawRewards, uint256[] memory trancheIds)
        external
        returns (uint256 withdrawnStake, uint256 withdrawnRewards);
}

/// @notice Minimal interface for the wrapper-fed balance adapter's `SUBMITTER_ROLE`-gated feed surface.
interface INexusStakingPoolsBalanceAdapterFeed {
    function submit(address account, uint256 tokenId) external;
    function remove(address account, uint256 tokenId) external;
}
