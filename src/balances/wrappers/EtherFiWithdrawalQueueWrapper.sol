// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title EtherFiWithdrawalQueueWrapper
/// @author KPK
/// @notice Delegatecall-only logic that a depositor Safe runs to request/claim ether.fi withdrawals while keeping the
///         wrapper-fed {EtherFiWithdrawalQueueAssistedBalanceAdapter} id-cache current **on-chain, atomically**. Both
///         entrypoints are meant to be **DELEGATECALLed by the owning Safe**, and both keep the adapter cache in sync
///         by routing back through this wrapper's own address (`SELF`) so the adapter is fed by the `WRAPPER_ROLE`
///         holder (this contract), never by the Safe. The adapter grants this contract `WRAPPER_ROLE`; access control
///         over *which* Safe may run this is enforced at the Safe layer (e.g. Zodiac Roles), not here.
///
/// @dev **Both `requestWithdraw` and `claimWithdraw` MUST be DELEGATECALLed by the depositor Safe.** Under delegatecall
///      `address(this)` is the Safe and the wrapper's immutables (`SELF`, `ADAPTER`, `LIQUIDITY_POOL`,
///      `WITHDRAW_REQUEST_NFT`, `EETH`) are still readable (they live in the wrapper's bytecode). A *direct* call to
///      either reverts `NotDelegateCall` (the {onlyDelegateCall} guard: on a direct call `address(this) == SELF`).
///
///      - `requestWithdraw(amount)` runs as the Safe: it approves the LiquidityPool to spend the Safe's eETH and calls
///        `LiquidityPool.requestWithdraw(recipient = address(this) = Safe, amount)` **directly**, so the eETH is pulled
///        straight from the Safe and the minted `WithdrawRequestNFT` is owned by the Safe. It then feeds the adapter by
///        a regular call to `EtherFiWithdrawalQueueWrapper(SELF).submit(requestId)`.
///      - `claimWithdraw(tokenId)` runs as the Safe: `WithdrawRequestNFT.claimWithdraw(tokenId)` (Safe == owner, ETH to
///        Safe), then `EtherFiWithdrawalQueueWrapper(SELF).remove(tokenId)`.
///
///      The `submit` / `remove` methods are the regular-call forwarders reached via the `SELF` self-call (and are
///      independently callable). They forward to the adapter's `WRAPPER_ROLE`-gated `submit` / `remove` **as this
///      wrapper**, keyed to `msg.sender` (the Safe). They are permissionless because the adapter re-verifies ownership
///      per id, keyed to that same `msg.sender`: a caller can only ever add/remove ids it actually owns (or has ceased
///      to own), for its own account — never over-report, never touch another account. See
///      `docs/decisions/0020-wrapper-fed-etherfi-withdrawal-queue.md`.
contract EtherFiWithdrawalQueueWrapper {
    using SafeERC20 for IERC20;

    /// @notice This wrapper's own deployed address, pinned at construction. Because it is an immutable it is baked into
    ///         the bytecode, so it still reads as the wrapper's real address when the entrypoints run under
    ///         delegatecall (where `address(this)` is the Safe) — letting them route the cache feed back through the
    ///         wrapper (`WRAPPER_ROLE` holder). Mirrors the UUPS `__self` pattern.
    address public immutable SELF;

    /// @notice The wrapper-fed balance adapter this wrapper feeds (holds `WRAPPER_ROLE` on it).
    address public immutable ADAPTER;

    /// @notice ether.fi LiquidityPool — the `requestWithdraw` target that pulls eETH and mints the WithdrawRequestNFT.
    address public immutable LIQUIDITY_POOL;

    /// @notice ether.fi WithdrawRequestNFT — the `claimWithdraw` target.
    address public immutable WITHDRAW_REQUEST_NFT;

    /// @notice eETH token — the Safe approves this to the LiquidityPool inside the delegatecalled `requestWithdraw`.
    address public immutable EETH;

    /// @param adapter_            The wrapper-fed {EtherFiWithdrawalQueueAssistedBalanceAdapter}. Must be a contract.
    /// @param liquidityPool_      ether.fi LiquidityPool. Must be a contract.
    /// @param withdrawRequestNft_ ether.fi WithdrawRequestNFT. Must be a contract.
    /// @param eeth_               eETH token. Must be a contract.
    constructor(address adapter_, address liquidityPool_, address withdrawRequestNft_, address eeth_) {
        if (
            adapter_ == address(0) || liquidityPool_ == address(0) || withdrawRequestNft_ == address(0)
                || eeth_ == address(0)
        ) {
            revert InvalidArguments();
        }
        AddressCheckLib.requireContract(adapter_, "adapter");
        AddressCheckLib.requireContract(liquidityPool_, "LiquidityPool");
        AddressCheckLib.requireContract(withdrawRequestNft_, "WithdrawRequestNFT");
        AddressCheckLib.requireContract(eeth_, "eETH");

        SELF = address(this);
        ADAPTER = adapter_;
        LIQUIDITY_POOL = liquidityPool_;
        WITHDRAW_REQUEST_NFT = withdrawRequestNft_;
        EETH = eeth_;
    }

    /// @dev Reverts unless the current call is a delegatecall (running in a caller's context, not the singleton's).
    ///      Under delegatecall `address(this)` is the caller Safe; on a direct call it is this deployment (`== SELF`,
    ///      the address pinned at construction). {requestWithdraw} / {claimWithdraw} rely on running in the Safe's
    ///      context (so ether.fi sees `msg.sender = Safe`), so a direct call is always a mistake — fail loud here
    ///      instead of letting ether.fi revert obscurely.
    modifier onlyDelegateCall() {
        if (address(this) == SELF) revert NotDelegateCall();
        _;
    }

    /// @notice Request a withdrawal of `amount` eETH from ether.fi and track the resulting WithdrawRequestNFT for the
    ///         caller. **Must be DELEGATECALLed by the owning Safe** (see contract NatSpec). Runs as the Safe: approves
    ///         the LiquidityPool for the Safe's eETH and calls it directly (NFT minted to the Safe), then feeds the
    ///         returned `requestId` to the adapter via the `SELF` self-call.
    /// @param amount eETH to withdraw (pulled directly from the delegatecalling Safe by the LiquidityPool).
    /// @return requestId The minted WithdrawRequestNFT id (tracked for the Safe).
    function requestWithdraw(uint256 amount) external onlyDelegateCall returns (uint256 requestId) {
        // Running as the Safe: approve the LiquidityPool to pull the Safe's eETH (forceApprove tolerates tokens that
        // require resetting a non-zero allowance), then request directly. recipient = address(this) = the Safe, so the
        // NFT is owned by the tracked account and the adapter's live ownership re-verification passes for it.
        IERC20(EETH).forceApprove(LIQUIDITY_POOL, amount);
        requestId = ILiquidityPool(LIQUIDITY_POOL).requestWithdraw(address(this), amount);
        EtherFiWithdrawalQueueWrapper(SELF).submit(requestId);
    }

    /// @notice Claim withdrawal request `tokenId` from ether.fi and stop tracking it. **Must be DELEGATECALLed by the
    ///         owning Safe** (see contract NatSpec): ether.fi's claim hard-requires `ownerOf(tokenId) == msg.sender`.
    ///         Runs as the Safe (== owner), ETH flows to the Safe, and the now-burned id is removed via the `SELF`
    ///         self-call.
    /// @param tokenId The WithdrawRequestNFT id to claim (owned by the delegatecalling Safe).
    function claimWithdraw(uint256 tokenId) external onlyDelegateCall {
        IWithdrawRequestNFTClaim(WITHDRAW_REQUEST_NFT).claimWithdraw(tokenId);
        EtherFiWithdrawalQueueWrapper(SELF).remove(tokenId);
    }

    /// @notice Track `tokenId` for `msg.sender` by forwarding to the adapter's `WRAPPER_ROLE`-gated `submit` (this
    ///         wrapper is the role holder). Reached via the `SELF` self-call from the delegatecalled {requestWithdraw}
    ///         (so `msg.sender` is the Safe), and independently callable. Permissionless: the adapter reverts unless
    ///         `msg.sender` owns `tokenId`, so a caller can only register its own owned ids for its own account.
    /// @param tokenId The WithdrawRequestNFT id to track for `msg.sender`.
    function submit(uint256 tokenId) external {
        IEtherFiWithdrawalQueueAssistedBalanceAdapter(ADAPTER).submit(msg.sender, tokenId);
    }

    /// @notice Prune `tokenId` from `msg.sender`'s adapter cache by forwarding to the adapter's `WRAPPER_ROLE`-gated
    ///         `remove` (this wrapper is the role holder). The adapter removes the id **only if** it is no longer
    ///         owned by `msg.sender` (e.g. burned on claim), so this can never delete a live position — safe to leave
    ///         open. Reached via the `SELF` self-call from the delegatecalled {claimWithdraw}, and independently
    ///         callable to GC a stale id.
    /// @param tokenId The WithdrawRequestNFT id to stop tracking for `msg.sender`.
    function remove(uint256 tokenId) external {
        IEtherFiWithdrawalQueueAssistedBalanceAdapter(ADAPTER).remove(msg.sender, tokenId);
    }
}

/// @notice Minimal interface for ether.fi's LiquidityPool — only the function the wrapper forwards.
interface ILiquidityPool {
    /// @notice Burns `amount` eETH from `msg.sender` and mints a WithdrawRequestNFT to `recipient`.
    /// @return requestId The minted WithdrawRequestNFT id.
    function requestWithdraw(address recipient, uint256 amount) external returns (uint256 requestId);
}

/// @notice Minimal interface for ether.fi's WithdrawRequestNFT — only the claim entrypoint the wrapper forwards.
interface IWithdrawRequestNFTClaim {
    /// @notice Claims request `tokenId`; requires `ownerOf(tokenId) == msg.sender`, burns the NFT, sends ETH to owner.
    function claimWithdraw(uint256 tokenId) external;
}

/// @notice Minimal interface for the wrapper-fed balance adapter's feed surface used by this wrapper.
interface IEtherFiWithdrawalQueueAssistedBalanceAdapter {
    function submit(address account, uint256 tokenId) external;
    function remove(address account, uint256 tokenId) external;
}
