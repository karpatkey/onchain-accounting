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
///         {NexusMutualStakingPoolsBalanceAdapter} id-cache current **on-chain, atomically**. `depositTo` forwards to
///         the pool and, in the same transaction, pushes the returned StakingNFT `tokenId` into the adapter for the
///         caller; `withdraw` forwards to the pool and pops the `tokenId`. The adapter grants this contract
///         `WRAPPER_ROLE`, so any address the admin grants `DEPOSITOR_ROLE` gets its Nexus positions tracked
///         automatically as it deposits/withdraws through the wrapper.
/// @dev **Pure forwarder — custody is arranged off-chain.** Nexus's `depositTo` pulls `amount` NXM from `msg.sender`
///      (= this wrapper) via `tokenController.depositStakedNXM`, so the wrapper must already hold the NXM; `depositTo`
///      only sets the exact-`amount` allowance to the `TOKEN_CONTROLLER` right before the call (`forceApprove`). It
///      does **not** move NXM between users. `withdraw` requires this wrapper to be authorized on the `StakingNFT`
///      (the NFT owner, or its approved operator) — arranged off-chain.
///
///      **Tracked account = the caller.** Both mutators track/untrack for `msg.sender` (the `DEPOSITOR_ROLE` holder),
///      matching the adapter's live ownership re-verification. Nexus mints/tops-up the position to `destination`, which
///      stays in `depositTo`'s signature (matching the pool ABI). The adapter's `submit` is **fail-loud**: if the
///      resulting NFT is not owned by `msg.sender` (i.e. `destination != msg.sender`), `submit` reverts `NotTokenOwner`
///      and the whole deposit reverts atomically — so a caller must set `destination` to itself. `withdraw` pops the
///      `tokenId` unconditionally; because Nexus does not burn the `StakingNFT` on withdraw, a *partial* withdrawal
///      stops tracking any remaining stake (a safe under-report per ADR 0015 — a later top-up re-adds the id).
contract NexusMutualStakingPoolsWrapper is AccessControl {
    using SafeERC20 for IERC20;

    /// @notice Role allowed to deposit/withdraw through the wrapper (and thereby have its Nexus positions tracked).
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    /// @notice The wrapper-fed balance adapter this wrapper feeds (holds `WRAPPER_ROLE` on it).
    address public immutable ADAPTER;

    /// @notice NXM token (pulled from this wrapper by Nexus on deposit).
    address public immutable NXM;

    /// @notice Nexus TokenController — the spender that pulls NXM in `depositTo` (`depositStakedNXM(msg.sender, …)`).
    address public immutable TOKEN_CONTROLLER;

    /// @param adapter_         The wrapper-fed {NexusMutualStakingPoolsBalanceAdapter}. Must be a contract.
    /// @param nxm_             NXM token. Must be a contract.
    /// @param tokenController_ Nexus TokenController (NXM spender). Must be a contract.
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
    ///         Mirrors the Nexus pool's `depositTo`, prepended with `poolAddress`. Reverts (rolling back the deposit)
    ///         if the resulting NFT is not owned by `msg.sender` — set `destination` to `msg.sender`.
    /// @param poolAddress   The Nexus staking pool.
    /// @param amount        NXM to stake (this wrapper must hold it).
    /// @param trancheId     Target tranche.
    /// @param requestTokenId 0 to mint a new StakingNFT, or an existing id to top it up.
    /// @param destination   Recipient/owner of the StakingNFT — must equal `msg.sender` (see contract NatSpec).
    /// @return tokenId The minted/topped-up StakingNFT id (tracked for `msg.sender`).
    function depositTo(
        address poolAddress,
        uint256 amount,
        uint256 trancheId,
        uint256 requestTokenId,
        address destination
    ) external onlyRole(DEPOSITOR_ROLE) returns (uint256 tokenId) {
        // Exact-amount allowance for the TokenController (Nexus pulls NXM from this wrapper). forceApprove tolerates
        // tokens that require resetting a non-zero allowance.
        IERC20(NXM).forceApprove(TOKEN_CONTROLLER, amount);
        tokenId = INexusStakingPool(poolAddress).depositTo(amount, trancheId, requestTokenId, destination);
        // Track for the caller. Fail-loud: reverts NotTokenOwner (rolling back the deposit) if destination != msg.sender.
        INexusStakingPoolsBalanceAdapterFeed(ADAPTER).submit(msg.sender, tokenId);
    }

    /// @notice Withdraw stake and/or rewards from `tokenId` in pool `poolAddress`, and stop tracking `tokenId` for the
    ///         caller. Mirrors the Nexus pool's `withdraw`, prepended with `poolAddress`.
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

/// @notice Minimal interface for the wrapper-fed balance adapter's `WRAPPER_ROLE`-gated feed surface.
interface INexusStakingPoolsBalanceAdapterFeed {
    function submit(address account, uint256 tokenId) external;
    function remove(address account, uint256 tokenId) external;
}
