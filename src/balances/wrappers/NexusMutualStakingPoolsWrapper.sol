// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title NexusMutualStakingPoolsWrapper
/// @author KPK
/// @notice Thin, `DEPOSITOR_ROLE`-gated forwarder around Nexus Mutual V2 staking pools that keeps the wrapper-fed
///         {NexusMutualStakingPoolsAssistedBalanceAdapter} id-cache current **on-chain, atomically**. `depositTo` forwards to
///         the pool and, in the same transaction, pushes the returned StakingNFT `tokenId` into the adapter for the
///         caller; `withdraw` forwards to the pool and pops the `tokenId`. The adapter grants this contract
///         `SUBMITTER_ROLE`, so any address the admin grants `DEPOSITOR_ROLE` gets its Nexus positions tracked
///         automatically as it deposits/withdraws through the wrapper.
/// @dev **NXM is pulled from the caller, then re-approved to the TokenController.** `depositTo` `transferFrom`s the
///      exact `amount` of NXM from the DEPOSITOR into this wrapper, then approves the `TOKEN_CONTROLLER` for that
///      `amount`. Nexus pulls it from the wrapper inside `pool.depositTo` via
///      `TokenController.depositStakedNXM` → `NXMToken.operatorTransfer(wrapper, amount)`. Although `operatorTransfer`
///      is operator-privileged, the **deployed** NXM token (Solidity 0.5.7) implements it via the shared
///      `_transferFrom`, which **decrements `_allowed[wrapper][operator]`** — so the wrapper must hold an NXM allowance
///      to the operator (the TokenController), or the transfer underflows and reverts. The wrapper is otherwise
///      custody-free (it holds no NXM between calls — the deposit consumes exactly what it pulled). The DEPOSITOR must
///      approve this wrapper to spend its NXM beforehand.
///
///      **Prerequisite: the wrapper must be a whitelisted Nexus member.** NXM's `transferFrom` gates on the
///      *recipient* (`canTransfer(to)` → `require(whiteListed[to])`), so the `transferFrom(DEPOSITOR → wrapper)` only
///      succeeds if this wrapper is a whitelisted member. Enrolling the wrapper as a Nexus member is a one-time
///      operational step that must be done before deposits work; it is **not** enforceable in the wrapper's code.
///
///      On `withdraw`, Nexus sends the withdrawn stake + rewards to `StakingNFT.ownerOf(tokenId)` (the token owner),
///      **not** to `msg.sender` — and since `depositTo` mints the NFT to the caller, the owner is the DEPOSITOR, so the
///      withdrawn NXM flows **directly from Nexus to the DEPOSITOR** and never touches this wrapper. Nexus `withdraw`
///      is permissionless (funds always route to the owner regardless of caller), so the wrapper needs no `StakingNFT`
///      operator approval and no member enrollment for the withdraw path.
///
///      **Tracked account = the caller.** Both mutators track/untrack for `msg.sender` (the `DEPOSITOR_ROLE` holder),
///      matching the adapter's live ownership re-verification. `depositTo` hardcodes the pool's `destination` to
///      `msg.sender` (the NFT is always minted/topped-up to the caller), so the position is always owned by the tracked
///      account — the `destination` parameter is intentionally omitted from the wrapper's signature. `withdraw` pops the
///      `tokenId` unconditionally; because Nexus does not burn the `StakingNFT` on withdraw, a *partial* withdrawal
///      stops tracking any remaining stake (a safe under-report per ADR 0015 — a later top-up re-adds the id).
contract NexusMutualStakingPoolsWrapper is AccessControl {
    using SafeERC20 for IERC20;

    /// @notice Role allowed to deposit/withdraw through the wrapper (and thereby have its Nexus positions tracked).
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    /// @notice The wrapper-fed balance adapter this wrapper feeds (holds `SUBMITTER_ROLE` on it).
    address public immutable ADAPTER;

    /// @notice NXM token (pulled from this wrapper by Nexus on deposit, via the TokenController's operator transfer).
    address public immutable NXM;

    /// @notice Nexus TokenController — the NXM `operator` that pulls staked NXM in `depositTo`. The wrapper approves
    ///         it the exact deposit `amount` each call (the deployed NXM's `operatorTransfer` consumes this allowance).
    address public immutable TOKEN_CONTROLLER;

    /// @param adapter_         The wrapper-fed {NexusMutualStakingPoolsAssistedBalanceAdapter}. Must be a contract.
    /// @param nxm_             NXM token. Must be a contract.
    /// @param tokenController_ Nexus TokenController (the NXM operator). Must be a contract.
    /// @param admin_           Holder of `DEFAULT_ADMIN_ROLE` (administers `DEPOSITOR_ROLE`). Required.
    constructor(address adapter_, address nxm_, address tokenController_, address admin_) {
        if (adapter_ == address(0) || nxm_ == address(0) || tokenController_ == address(0) || admin_ == address(0)) {
            revert InvalidArguments();
        }
        AddressCheckLib.requireContract(adapter_, "adapter");
        AddressCheckLib.requireContract(nxm_, "NXM");
        AddressCheckLib.requireContract(tokenController_, "TokenController");

        ADAPTER = adapter_;
        NXM = nxm_;
        TOKEN_CONTROLLER = tokenController_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @notice Deposit `amount` NXM into staking pool `poolAddress` and track the resulting StakingNFT for the caller.
    ///         Mirrors the Nexus pool's `depositTo`, prepended with `poolAddress` and with `destination` omitted — the
    ///         NFT is always minted/topped-up to `msg.sender`, so the tracked account always owns it.
    /// @param poolAddress   The Nexus staking pool.
    /// @param amount        NXM to stake (pulled from `msg.sender` — the DEPOSITOR must approve this wrapper first).
    /// @param trancheId     Target tranche.
    /// @param requestTokenId 0 to mint a new StakingNFT, or an existing id (owned by the caller) to top it up.
    /// @return tokenId The minted/topped-up StakingNFT id (tracked for `msg.sender`).
    function depositTo(address poolAddress, uint256 amount, uint256 trancheId, uint256 requestTokenId)
        external
        onlyRole(DEPOSITOR_ROLE)
        returns (uint256 tokenId)
    {
        // Pull the NXM from the DEPOSITOR into this wrapper, then approve the TokenController (NXM operator) for the
        // exact amount: the deployed NXM's operatorTransfer runs through _transferFrom, which decrements the operator's
        // allowance, so a zero allowance would underflow-revert. Requires this wrapper to be a whitelisted Nexus member
        // (NXM transferFrom gates on the recipient) — see the contract NatSpec.
        IERC20(NXM).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(NXM).forceApprove(TOKEN_CONTROLLER, amount);
        // destination = msg.sender: the NFT is always owned by the tracked account, so the adapter's live ownership
        // re-verification always passes for it.
        tokenId = INexusStakingPool(poolAddress).depositTo(amount, trancheId, requestTokenId, msg.sender);
        INexusStakingPoolsBalanceAdapterFeed(ADAPTER).submit(msg.sender, tokenId);
    }

    /// @notice Withdraw stake and/or rewards from `tokenId` in pool `poolAddress`, and stop tracking `tokenId` for the
    ///         caller. Mirrors the Nexus pool's `withdraw`, prepended with `poolAddress`. Nexus sends the withdrawn NXM
    ///         to the token owner (`StakingNFT.ownerOf(tokenId)`) — the DEPOSITOR who minted it — so the funds go
    ///         directly to the caller and never touch this wrapper.
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
    ) external onlyRole(DEPOSITOR_ROLE) returns (uint256 withdrawnStake, uint256 withdrawnRewards) {
        (withdrawnStake, withdrawnRewards) =
            INexusStakingPool(poolAddress).withdraw(tokenId, withdrawStake, withdrawRewards, trancheIds);
        INexusStakingPoolsBalanceAdapterFeed(ADAPTER).remove(msg.sender, tokenId);
    }
}

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
