// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBalanceAdapterAssistant} from "src/balances/AssistedBalanceAdapters/assistants/IBalanceAdapterAssistant.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title BalanceAdapterAssistant
/// @author KPK
/// @notice Abstract base for the delegatecall-action assistants that feed the permissionless, assistant-fed assisted
///         balance adapters. It contributes the pieces every such assistant shares: the immutable `ADAPTER` reference,
///         this module's own `SELF` address pinned at construction, and the {onlyDelegateCall} guard. Concrete assistants
///         add the protocol-target immutables and the forward-then-`submit`/`remove` entrypoints.
/// @dev Because entrypoints run under `delegatecall` (from the owner Safe), `address(this)` is the Safe throughout, yet
///      the immutables (`SELF`, `ADAPTER`, and any the concrete adds) remain readable — they live in the assistant's
///      bytecode. That is what lets an entrypoint both act as the Safe against the protocol and reach the adapter with
///      `msg.sender = Safe`. A *direct* call to a delegatecall-only entrypoint has `address(this) == SELF` and is
///      rejected by {onlyDelegateCall} (fail loud, canonical {NotDelegateCall}), rather than letting the protocol
///      revert obscurely. The base holds no roles, no custody, and no mutable state (delegatecall-storage-collision
///      safe): access to *which* Safe may run an assistant is governed at the Safe/Zodiac layer, not here.
abstract contract BalanceAdapterAssistant is IBalanceAdapterAssistant {
    /// @inheritdoc IBalanceAdapterAssistant
    address public immutable override SELF;

    /// @inheritdoc IBalanceAdapterAssistant
    address public immutable override ADAPTER;

    /// @param adapter_ The assistant-fed assisted balance adapter this assistant feeds. Must be a contract.
    constructor(address adapter_) {
        if (adapter_ == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(adapter_, "adapter");
        SELF = address(this);
        ADAPTER = adapter_;
    }

    /// @notice Reverts unless the current call is a `delegatecall` (running in the caller Safe's context, not the
    ///         singleton's). Under `delegatecall` `address(this)` is the Safe; on a direct call it is this deployment
    ///         (`== SELF`). Delegatecall-only entrypoints rely on running as the Safe, so a direct call is always a
    ///         mistake — fail loud here.
    modifier onlyDelegateCall() {
        if (address(this) == SELF) revert NotDelegateCall();
        _;
    }

    /// @notice Sanity check for the assistants whose forwarded protocol call mirrors a signature with an explicit
    ///         `receiver`/`owner`/`destination` account: it MUST be the executing context (`address(this)` — the
    ///         delegatecalling Safe), so the created position is owned by, and tracked for, that same Safe. Reverts
    ///         `AssistantAccountMismatch` otherwise. Assistants that instead force the receiver to `address(this)` in the
    ///         forwarded call have no argument to check and need not call this.
    function _requireSelf(address account) internal view {
        if (account != address(this)) revert AssistantAccountMismatch(address(this), account);
    }

    /// @notice Best-effort untrack helper for the `withdraw`/`claim` entrypoints: given the raw revert `reason` from a
    ///         failed `ADAPTER.remove(...)`, swallow the two expected cache-state reverts and re-throw anything else.
    ///         `CoordinateNotCached` = the id was never tracked (cleared via `clearAccount` / `evict`, or acquired outside the
    ///         assistant) — nothing to untrack. `CoordinateStillLive` = the position is still live after a partial
    ///         withdraw/claim — keep it tracked. Both are safe to ignore because the adapter re-verifies ownership and
    ///         re-values live on every read: a coordinate left cached only ever **under-reports** (a fully-consumed or
    ///         no-longer-owned one resolves to 0), never over-reports. Any other revert is a real fault and is
    ///         re-thrown verbatim so the op fails loud rather than silently continuing.
    function _bubbleUnlessCacheRevert(bytes memory reason) internal pure {
        bytes4 sel = bytes4(reason);
        if (sel != CoordinateStillLive.selector && sel != CoordinateNotCached.selector) {
            assembly {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }
}
