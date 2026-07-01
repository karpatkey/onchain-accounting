// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title StaderWithdrawalQueueWrapper
/// @author KPK
/// @notice **Permissionless** forwarder around Stader's `UserWithdrawalManager` that keeps the
///         {StaderWithdrawalQueueBalanceAdapter} id-cache current **on-chain, atomically**. Anyone can request/claim
///         through this wrapper for their own account, and the resulting Stader withdrawal request is tracked
///         automatically. The wrapper holds no roles and custodies no funds; the adapter grants this contract
///         `SUBMITTER_ROLE` so it is the single trusted feeder.
///
/// @dev **This contract is used in two DIFFERENT execution modes — read this carefully.**
///
///      1. **`requestWithdraw` — a normal CALL.** The caller calls the wrapper directly. The wrapper pulls the exact
///         `_ethXAmount` of ETHx from the caller (`transferFrom` — the caller must approve this wrapper first), sets the
///         exact-amount allowance to the `USER_WITHDRAWAL_MANAGER` (`forceApprove`), forwards to
///         `UserWithdrawalManager.requestWithdraw(_ethXAmount, _owner = caller)` — so the recorded request owner is the
///         caller — and then `submit`s the returned `requestId` for the caller into the adapter (the wrapper holds
///         `SUBMITTER_ROLE`). The wrapper custodies no ETHx between calls. `_owner` is kept in the signature to match
///         `UserWithdrawalManager.requestWithdraw` exactly, but is pinned to `msg.sender` (`_owner != msg.sender`
///         reverts): this keeps the caller from creating (and having the adapter track) a request owned by a third
///         party, so a permissionless caller can only ever affect its own cache entry — never bloat a victim's cache.
///
///      2. **`claim` — a DELEGATECALL from the owning Safe.** Stader's `UserWithdrawalManager.claim(_requestId)`
///         hard-requires `msg.sender == userRequest.owner` (reverts `CallerNotAuthorizedToRedeem`) and sends the ETH to
///         `userRequest.owner`, so a plain CALL through the wrapper cannot claim on the owner's behalf. The owning Safe
///         must **delegatecall** this function: then `address(this)` is the Safe, `msg.sender` seen by the manager is
///         the Safe (== the owner ✓), and ETH flows straight to the Safe. Immutables (`USER_WITHDRAWAL_MANAGER`,
///         `ADAPTER`) are embedded in bytecode, so they are readable under delegatecall. It touches **no** wrapper
///         storage. Cache cleanup calls the adapter's **permissionless** `pruneStale(address(this), _requestId)`, which
///         removes the id only because the claim just deleted the request (so it is provably no longer owned) — it can
///         never delete a live position.
///
///      A direct CALL to `claim` by a non-owner simply reverts inside the manager (`CallerNotAuthorizedToRedeem`), so it
///      fails safe if invoked the wrong way. EOA callers cannot use the delegatecalled claim (an EOA cannot
///      delegatecall); they claim directly on Stader. The intended claimers are Safe/Avatar accounts.
contract StaderWithdrawalQueueWrapper {
    using SafeERC20 for IERC20;

    /// @notice The balance adapter this wrapper feeds (holds `SUBMITTER_ROLE` on it).
    address public immutable ADAPTER;

    /// @notice Stader UserWithdrawalManager — the `requestWithdraw`/`claim` target.
    address public immutable USER_WITHDRAWAL_MANAGER;

    /// @notice ETHx token — pulled from the caller on `requestWithdraw` and approved to the UserWithdrawalManager.
    address public immutable ETHX;

    /// @param adapter_               The {StaderWithdrawalQueueBalanceAdapter}. Must be a contract.
    /// @param userWithdrawalManager_ Stader UserWithdrawalManager. Must be a contract.
    /// @param ethx_                  ETHx token. Must be a contract.
    constructor(address adapter_, address userWithdrawalManager_, address ethx_) {
        if (adapter_ == address(0) || userWithdrawalManager_ == address(0) || ethx_ == address(0)) {
            revert InvalidArguments();
        }
        AddressCheckLib.requireContract(adapter_, "adapter");
        AddressCheckLib.requireContract(userWithdrawalManager_, "UserWithdrawalManager");
        AddressCheckLib.requireContract(ethx_, "ETHx");

        ADAPTER = adapter_;
        USER_WITHDRAWAL_MANAGER = userWithdrawalManager_;
        ETHX = ethx_;
    }

    /// @notice Request a withdrawal of `_ethXAmount` ETHx from Stader and track the resulting request for the caller.
    ///         **Normal CALL** (see contract NatSpec). Mirrors `UserWithdrawalManager.requestWithdraw`'s signature.
    /// @param _ethXAmount ETHx to withdraw (pulled from `msg.sender` — the caller must approve this wrapper first).
    /// @param _owner      Must equal `msg.sender` — the request is always recorded for (and tracked for) the caller.
    /// @return requestId The created withdrawal request id (tracked for `msg.sender`).
    function requestWithdraw(uint256 _ethXAmount, address _owner) external returns (uint256 requestId) {
        // Pin the request owner / tracked account to the caller so the adapter's live ownership re-verification always
        // passes for it (and a permissionless caller can't record a withdrawal owned by / tracked for a third party).
        if (_owner != msg.sender) revert InvalidArguments();

        // Pull the ETHx from the caller, then set the exact-amount allowance for the UserWithdrawalManager (it pulls
        // ETHx from this wrapper on requestWithdraw). forceApprove tolerates tokens that require resetting a non-zero
        // allowance.
        IERC20(ETHX).safeTransferFrom(msg.sender, address(this), _ethXAmount);
        IERC20(ETHX).forceApprove(USER_WITHDRAWAL_MANAGER, _ethXAmount);

        requestId = IStaderUserWithdrawalManager(USER_WITHDRAWAL_MANAGER).requestWithdraw(_ethXAmount, msg.sender);
        IStaderWithdrawalFeed(ADAPTER).submit(msg.sender, requestId);
    }

    /// @notice Claim withdrawal request `_requestId` from Stader and stop tracking it. **Must be DELEGATECALLed by the
    ///         owning Safe** (see contract NatSpec): Stader's claim hard-requires `msg.sender == userRequest.owner`.
    ///         Under delegatecall `msg.sender` seen by the manager is the Safe (== owner), the ETH flows to the Safe,
    ///         and the now-deleted request is pruned from the adapter cache via the permissionless `pruneStale`. Touches
    ///         no wrapper storage. Mirrors `UserWithdrawalManager.claim`'s signature.
    /// @param _requestId The withdrawal request id to claim (owned by the delegatecalling Safe).
    function claim(uint256 _requestId) external {
        IStaderUserWithdrawalManager(USER_WITHDRAWAL_MANAGER).claim(_requestId);
        // address(this) is the Safe under delegatecall — the account the id was submitted for. pruneStale removes it
        // only because the claim just deleted the request (provably no longer owned); it can never delete a live one.
        IStaderWithdrawalFeed(ADAPTER).pruneStale(address(this), _requestId);
    }
}

/// @notice Minimal interface for Stader's UserWithdrawalManager — only the functions the wrapper forwards.
interface IStaderUserWithdrawalManager {
    /// @notice Burns `_ethXAmount` ETHx from `msg.sender` and records a withdrawal request owned by `_owner`.
    /// @return requestId The created withdrawal request id.
    function requestWithdraw(uint256 _ethXAmount, address _owner) external returns (uint256 requestId);

    /// @notice Claims request `_requestId`; requires `msg.sender == owner`, deletes the request, sends ETH to owner.
    function claim(uint256 _requestId) external;
}

/// @notice Minimal interface for the balance adapter's feed surface used by this wrapper.
interface IStaderWithdrawalFeed {
    function submit(address account, uint256 requestId) external;
    function pruneStale(address account, uint256 requestId) external;
}
