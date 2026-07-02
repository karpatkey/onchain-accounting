// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IAssistantFedBalanceAdapter} from "src/balances/IAssistantFedBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title AssistantFedBalanceAdapter
/// @author KPK
/// @notice Minimal base for the "assisted" balance-adapter family — adapters whose positions cannot be derived from
///         on-chain state alone and must be fed verifiable data by a trusted assistant (see
///         {IAssistantFedBalanceAdapter}). This base contributes only the access-control scaffolding: a two-role model
///         where `DEFAULT_ADMIN_ROLE` manages roles and `ASSISTANT_ROLE` is authorized to submit the assistance.
/// @dev Concrete adapters still implement {IBalanceAdapter} (and typically {IPositionDescribable}) themselves, gate
///      their submit/clear mutators with `onlyRole(ASSISTANT_ROLE)`, and must uphold the family invariant: cache only
///      position *coordinates* (never amounts), value every read live on-chain, and re-verify ownership per read, so a
///      faulty or compromised assistant can only under-report. This base intentionally prescribes no submit/clear
///      surface — each protocol's data shape differs.
abstract contract AssistantFedBalanceAdapter is IAssistantFedBalanceAdapter, AccessControl {
    /// @inheritdoc IAssistantFedBalanceAdapter
    bytes32 public constant ASSISTANT_ROLE = keccak256("ASSISTANT_ROLE");

    /// @param admin     Holder of `DEFAULT_ADMIN_ROLE` — administers (grants/revokes) `ASSISTANT_ROLE`. Required.
    /// @param assistant Initial holder of `ASSISTANT_ROLE`. Optional (pass `address(0)` to grant later via `admin`).
    constructor(address admin, address assistant) {
        if (admin == address(0)) revert InvalidArguments();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (assistant != address(0)) _grantRole(ASSISTANT_ROLE, assistant);
    }

    //
    // Shared submit orchestration (internal)
    //

    /// @notice Family-wide submit chokepoint, shared by every assisted adapter. Concrete adapters expose a *friendly,
    ///         typed* public `submit…` wrapper (e.g. `submitTokenIds(address, uint256[])`) gated with
    ///         `onlyRole(ASSISTANT_ROLE)`; that wrapper `abi.encode`s its payload and routes here so the per-account
    ///         validation and the **replace** semantics live in one place. `data` is the adapter's element list
    ///         ABI-encoded (the typed shape is per-adapter: a `uint256[]` of token ids, an `ExitPosition[]`, an
    ///         `Allocation[]`, …). REPLACE semantics: the decoded list becomes the account's COMPLETE cached set.
    /// @dev Kept internal (not a public interface method) deliberately — the public surface stays strongly typed and
    ///      self-documenting per adapter. Access control is enforced by the caller's `onlyRole(ASSISTANT_ROLE)`.
    function _submit(address account, bytes memory data) internal {
        if (account == address(0)) revert InvalidArguments();
        _applyReplace(account, data);
    }

    /// @notice Batch form of {_submit}: each account's encoded list replaces that account's cached set. `accounts` and
    ///         `data` must have the same length.
    function _submitBatch(address[] calldata accounts, bytes[] memory data) internal {
        if (accounts.length != data.length) revert ArrayLengthMismatch();
        for (uint256 i; i < accounts.length; ++i) {
            _submit(accounts[i], data[i]);
        }
    }

    /// @dev Decode `data` into the adapter's typed element list and REPLACE `account`'s cached set — clear the prior
    ///      set, then re-add each element validating fail-loud (revert on a bad element so the whole submit, including
    ///      the clear, rolls back atomically and the prior set is preserved). Implemented per adapter.
    function _applyReplace(address account, bytes memory data) internal virtual;

    /// @inheritdoc IERC165
    /// @dev Reconciles ERC-165 across {AccessControl} (which advertises {IAccessControl}/{IERC165}) and this family.
    ///      Advertises {IBalanceAdapter} too — every assisted adapter is one (via {IAssistantFedBalanceAdapter}), and the
    ///      registry (`Balances.checkBalanceAdapterSupport`) requires it — so concrete adapters register without
    ///      re-overriding. A concrete adapter that also implements {IPositionDescribable} overrides again to add it,
    ///      calling `super`.
    function supportsInterface(bytes4 interfaceId) public view virtual override(AccessControl, IERC165) returns (bool) {
        return interfaceId == type(IAssistantFedBalanceAdapter).interfaceId
            || interfaceId == type(IBalanceAdapter).interfaceId || super.supportsInterface(interfaceId);
    }
}
