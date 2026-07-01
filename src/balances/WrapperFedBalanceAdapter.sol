// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IWrapperFedBalanceAdapter} from "src/balances/IWrapperFedBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title WrapperFedBalanceAdapter
/// @author KPK
/// @notice Minimal base for the **wrapper-fed** assisted balance-adapter variant (ADR 0015 / 0020) — adapters whose
///         position coordinates are supplied on-chain by a trusted wrapper contract (see
///         {IWrapperFedBalanceAdapter}). This base contributes only the access-control scaffolding: a two-role model
///         where `DEFAULT_ADMIN_ROLE` manages roles and `WRAPPER_ROLE` is authorized to submit/remove coordinates. It
///         mirrors {AssistedBalanceAdapter} (the off-chain-agent variant) but gates on `WRAPPER_ROLE` instead of
///         `ASSISTANT_ROLE`, and the feeder is expected to be a single wrapper contract rather than an off-chain
///         automation.
/// @dev Concrete adapters still implement {IBalanceAdapter} (and typically {IPositionDescribable}) themselves, gate
///      their submit/remove mutators with `onlyRole(WRAPPER_ROLE)`, and must uphold the family invariant: cache only
///      position *coordinates* (never amounts), value every read live on-chain, and re-verify ownership per read, so a
///      faulty or compromised feeder can only under-report. This base intentionally prescribes no submit/remove
///      surface — that is layered on by {WrapperFedNftCacheAdapter} for the NFT-id case.
abstract contract WrapperFedBalanceAdapter is IWrapperFedBalanceAdapter, AccessControl {
    /// @inheritdoc IWrapperFedBalanceAdapter
    bytes32 public constant WRAPPER_ROLE = keccak256("WRAPPER_ROLE");

    /// @param admin   Holder of `DEFAULT_ADMIN_ROLE` — administers (grants/revokes) `WRAPPER_ROLE`. Required.
    /// @param wrapper Initial holder of `WRAPPER_ROLE` (the wrapper contract). Optional (pass `address(0)` to grant
    ///        later via `admin` — the deploy flow grants it after the wrapper is deployed, since the wrapper needs this
    ///        adapter's address at construction).
    constructor(address admin, address wrapper) {
        if (admin == address(0)) revert InvalidArguments();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (wrapper != address(0)) _grantRole(WRAPPER_ROLE, wrapper);
    }

    /// @inheritdoc IERC165
    /// @dev Reconciles ERC-165 across {AccessControl} (which advertises {IAccessControl}/{IERC165}) and this variant.
    ///      Advertises {IBalanceAdapter} too — every wrapper-fed adapter is one (via {IWrapperFedBalanceAdapter}), and
    ///      the registry (`Balances.checkBalanceAdapterSupport`) requires it — so concrete adapters register without
    ///      re-overriding. A concrete adapter that also implements {IPositionDescribable} overrides again to add it,
    ///      calling `super`.
    function supportsInterface(bytes4 interfaceId) public view virtual override(AccessControl, IERC165) returns (bool) {
        return interfaceId == type(IWrapperFedBalanceAdapter).interfaceId
            || interfaceId == type(IBalanceAdapter).interfaceId || super.supportsInterface(interfaceId);
    }
}
