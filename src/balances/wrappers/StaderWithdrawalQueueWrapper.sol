// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title StaderWithdrawalQueueWrapper
/// @author KPK
/// @notice Stateless, role-free helper **meant to be DELEGATECALLed by the owning Safe** to route Stader
///         withdrawal-queue requests/claims while keeping the {StaderWithdrawalQueueBalanceAdapter} id-cache current
///         on-chain, atomically. Both entrypoints run in the Safe's context (`address(this)` is the Safe), so the Safe
///         is the Stader request owner AND the `msg.sender` the adapter's `msg.sender`-keyed cache records against — no
///         roles, no allowances to this contract, no custody.
///
/// @dev **Both functions MUST be DELEGATECALLed by the owning Safe.** Under delegatecall, `address(this)` is the Safe,
///      `msg.sender` seen by the manager/adapter is the Safe, and the immutables (`USER_WITHDRAWAL_MANAGER`, `ADAPTER`,
///      `ETHX`) are read from this contract's bytecode. The Safe already custodies the ETHx, so `requestWithdraw` just
///      approves the manager (from the Safe) and forwards — there is no `transferFrom` from a separate depositor and
///      this contract never holds funds.
///
///      1. **`requestWithdraw`** — `forceApprove`s the manager for `_ethXAmount` ETHx (from the Safe), forwards to
///         `UserWithdrawalManager.requestWithdraw(_ethXAmount, _owner)` (so the request is owned by the Safe), and
///         `submit`s the returned `requestId` (the adapter caches it for `msg.sender` == the Safe). `_owner` mirrors
///         Stader's signature and is pinned to `address(this)` (the Safe) — the request owner, the tracked account, and
///         the adapter's `msg.sender` are then all the same Safe, so the ownership re-verification always passes.
///      2. **`claim`** — forwards to `UserWithdrawalManager.claim(_requestId)` (Stader requires `msg.sender == owner`;
///         under delegatecall that is the Safe ✓, ETH flows to the Safe) and then calls the adapter's `remove` to drop
///         the now-deleted (provably-stale) request id from the Safe's cache.
///
///      A **normal CALL** to either function reverts `NotDelegateCall` (the {onlyDelegateCall} guard: on a direct call
///      `address(this) == SELF`), so a wrong invocation fails loud and early. EOAs cannot delegatecall, so the intended
///      callers are Safe/Avatar accounts.
contract StaderWithdrawalQueueWrapper {
    using SafeERC20 for IERC20;

    /// @notice Thrown when an entrypoint that must be delegatecalled is called directly on the singleton.
    error NotDelegateCall();

    /// @notice The balance adapter this wrapper feeds (the Safe's `submit`/`remove` target under delegatecall).
    address public immutable ADAPTER;

    /// @notice Stader UserWithdrawalManager — the `requestWithdraw`/`claim` target.
    address public immutable USER_WITHDRAWAL_MANAGER;

    /// @notice ETHx token — approved to the UserWithdrawalManager (from the Safe) on `requestWithdraw`.
    address public immutable ETHX;

    /// @notice This deployment's own address, pinned at construction — used by {onlyDelegateCall} to tell a delegatecall
    ///         (running in a Safe's context) from a direct call on the singleton.
    address private immutable SELF;

    /// @dev Reverts unless the current call is a delegatecall (running in a caller's context, not the singleton's).
    ///      Under delegatecall `address(this)` is the caller Safe; on a direct call it is this deployment (`== SELF`,
    ///      the address pinned at construction). {requestWithdraw} / {claim} rely on running in the Safe's context (so
    ///      Stader/the adapter see `msg.sender = Safe`), so a direct call is always a mistake — fail loud here instead
    ///      of letting Stader revert obscurely.
    modifier onlyDelegateCall() {
        if (address(this) == SELF) revert NotDelegateCall();
        _;
    }

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
        SELF = address(this);
    }

    /// @notice Request a withdrawal of `_ethXAmount` ETHx from Stader and track the resulting request. **Must be
    ///         DELEGATECALLed by the owning Safe** (see contract NatSpec). Mirrors
    ///         `UserWithdrawalManager.requestWithdraw`'s signature.
    /// @param _ethXAmount ETHx to withdraw (approved to the manager from the delegatecalling Safe, which holds it).
    /// @param _owner      Must equal `address(this)` — under delegatecall this is the Safe, so the request is owned by
    ///                    (and tracked for) the Safe.
    /// @return requestId The created withdrawal request id (tracked for the Safe).
    function requestWithdraw(uint256 _ethXAmount, address _owner)
        external
        onlyDelegateCall
        returns (uint256 requestId)
    {
        // Under delegatecall address(this) is the Safe. Pin the request owner / tracked account to the Safe so the
        // adapter's msg.sender-keyed cache and its live ownership re-verification both line up on the Safe.
        if (_owner != address(this)) revert InvalidArguments();

        // The Safe holds the ETHx; approve the manager (from the Safe) for the exact amount it will pull. forceApprove
        // tolerates tokens that require resetting a non-zero allowance.
        IERC20(ETHX).forceApprove(USER_WITHDRAWAL_MANAGER, _ethXAmount);

        requestId = IStaderUserWithdrawalManager(USER_WITHDRAWAL_MANAGER).requestWithdraw(_ethXAmount, _owner);
        // msg.sender seen by the adapter is the Safe (== _owner), so it caches the id for the Safe.
        IStaderWithdrawalQueueAssistedBalanceAdapter(ADAPTER).submit(requestId);
    }

    /// @notice Claim withdrawal request `_requestId` from Stader and stop tracking it. **Must be DELEGATECALLed by the
    ///         owning Safe** (see contract NatSpec): Stader's claim hard-requires `msg.sender == userRequest.owner`.
    ///         Under delegatecall `msg.sender` seen by the manager is the Safe (== owner), the ETH flows to the Safe,
    ///         and the now-deleted request is dropped from the Safe's adapter cache via `remove`. Mirrors
    ///         `UserWithdrawalManager.claim`'s signature.
    /// @param _requestId The withdrawal request id to claim (owned by the delegatecalling Safe).
    function claim(uint256 _requestId) external onlyDelegateCall {
        IStaderUserWithdrawalManager(USER_WITHDRAWAL_MANAGER).claim(_requestId);
        // msg.sender seen by the adapter is the Safe. remove drops the id only because the claim just deleted the
        // request (provably no longer owned); it can never delete a live one.
        IStaderWithdrawalQueueAssistedBalanceAdapter(ADAPTER).remove(_requestId);
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

/// @notice Minimal interface for the balance adapter's feed surface used by this wrapper (keyed on `msg.sender`).
interface IStaderWithdrawalQueueAssistedBalanceAdapter {
    function submit(uint256 requestId) external;
    function remove(uint256 requestId) external;
}
