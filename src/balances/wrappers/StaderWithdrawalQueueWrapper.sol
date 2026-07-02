// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BalanceAdapterWrapper} from "src/balances/wrappers/BalanceAdapterWrapper.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title StaderWithdrawalQueueWrapper
/// @author KPK
/// @notice Stateless helper **meant to be DELEGATECALLed by the owning Safe** to route Stader withdrawal-queue
///         requests/claims while keeping the {StaderWithdrawalQueueBalanceAdapter} id-cache current on-chain,
///         atomically. Both entrypoints run in the Safe's context (`address(this)` is the Safe), so the Safe is the
///         Stader request owner AND the `msg.sender` the adapter's `msg.sender`-keyed cache records against — no roles,
///         no allowances to this contract, no custody.
/// @dev Extends {BalanceAdapterWrapper} for the shared `SELF` / {onlyDelegateCall} guard, the immutable `ADAPTER`, and
///      {_requireSelf}. A **normal CALL** to either entrypoint reverts `NotDelegateCall`. EOAs cannot delegatecall, so
///      the intended callers are Safe/Avatar accounts. The Safe already custodies the ETHx, so `requestWithdraw` just
///      approves the manager (from the Safe) and forwards. See [ADR 0018](../../../docs/decisions/0018-wrapper-fed-assisted-balance-adapters.md).
contract StaderWithdrawalQueueWrapper is BalanceAdapterWrapper {
    using SafeERC20 for IERC20;

    /// @notice Stader UserWithdrawalManager — the `requestWithdraw`/`claim` target.
    address public immutable USER_WITHDRAWAL_MANAGER;

    /// @notice ETHx token — approved to the UserWithdrawalManager (from the Safe) on `requestWithdraw`.
    address public immutable ETHX;

    /// @param adapter_               The {StaderWithdrawalQueueBalanceAdapter}. Must be a contract.
    /// @param userWithdrawalManager_ Stader UserWithdrawalManager. Must be a contract.
    /// @param ethx_                  ETHx token. Must be a contract.
    constructor(address adapter_, address userWithdrawalManager_, address ethx_) BalanceAdapterWrapper(adapter_) {
        if (userWithdrawalManager_ == address(0) || ethx_ == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(userWithdrawalManager_, "UserWithdrawalManager");
        AddressCheckLib.requireContract(ethx_, "ETHx");
        USER_WITHDRAWAL_MANAGER = userWithdrawalManager_;
        ETHX = ethx_;
    }

    /// @notice Request a withdrawal of `_ethXAmount` ETHx from Stader and track the resulting request. **Must be
    ///         DELEGATECALLed by the owning Safe.** Mirrors `UserWithdrawalManager.requestWithdraw`'s signature.
    /// @param _ethXAmount ETHx to withdraw (approved to the manager from the delegatecalling Safe, which holds it).
    /// @param _owner      Must equal `address(this)` — under delegatecall this is the Safe, so the request is owned by
    ///                    (and tracked for) the Safe.
    /// @return requestId The created withdrawal request id (tracked for the Safe).
    function requestWithdraw(uint256 _ethXAmount, address _owner)
        external
        onlyDelegateCall
        returns (uint256 requestId)
    {
        // Pin the request owner / tracked account to the Safe (address(this) under delegatecall) so the adapter's
        // msg.sender-keyed cache and its live ownership re-verification both line up on the Safe.
        _requireSelf(_owner);
        // The Safe holds the ETHx; approve the manager (from the Safe) for the exact amount it will pull.
        IERC20(ETHX).forceApprove(USER_WITHDRAWAL_MANAGER, _ethXAmount);
        requestId = IStaderUserWithdrawalManager(USER_WITHDRAWAL_MANAGER).requestWithdraw(_ethXAmount, _owner);
        // msg.sender seen by the adapter is the Safe (== _owner), so it caches the id for the Safe.
        IStaderWithdrawalQueueBalanceAdapter(ADAPTER).submit(requestId);
    }

    /// @notice Claim withdrawal request `_requestId` from Stader and stop tracking it. **Must be DELEGATECALLed by the
    ///         owning Safe**: Stader's claim hard-requires `msg.sender == userRequest.owner`. Under delegatecall
    ///         `msg.sender` is the Safe (== owner), the ETH flows to the Safe, and the now-deleted request is dropped
    ///         from the Safe's adapter cache via `remove`. Mirrors `UserWithdrawalManager.claim`'s signature.
    /// @param _requestId The withdrawal request id to claim (owned by the delegatecalling Safe).
    function claim(uint256 _requestId) external onlyDelegateCall {
        IStaderUserWithdrawalManager(USER_WITHDRAWAL_MANAGER).claim(_requestId);
        // The claim just deleted the request (provably no longer owned), so the adapter's fail-loud remove accepts it.
        IStaderWithdrawalQueueBalanceAdapter(ADAPTER).remove(_requestId);
    }
}

/// @notice Minimal interface for Stader's UserWithdrawalManager — only the functions the wrapper forwards.
interface IStaderUserWithdrawalManager {
    /// @notice Burns `_ethXAmount` ETHx from `msg.sender` and records a withdrawal request owned by `_owner`.
    function requestWithdraw(uint256 _ethXAmount, address _owner) external returns (uint256 requestId);

    /// @notice Claims request `_requestId`; requires `msg.sender == owner`, deletes the request, sends ETH to owner.
    function claim(uint256 _requestId) external;
}

/// @notice Minimal interface for the balance adapter's feed surface used by this wrapper (keyed on `msg.sender`).
interface IStaderWithdrawalQueueBalanceAdapter {
    function submit(uint256 requestId) external;
    function remove(uint256 requestId) external;
}
