// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IAssistedBalanceAdapter} from "src/balances/IAssistedBalanceAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title AssistedBalanceAdapter
/// @author KPK
/// @notice Minimal base for the "assisted" balance-adapter family — adapters whose positions cannot be derived from
///         on-chain state alone and must be fed verifiable data by a trusted assistant (see
///         {IAssistedBalanceAdapter}). This base contributes only the access-control scaffolding: a two-role model
///         where `DEFAULT_ADMIN_ROLE` manages roles and `ASSISTANT_ROLE` is authorized to submit the assistance.
/// @dev Concrete adapters still implement {IBalanceAdapter} (and typically {IPositionDescribable}) themselves, gate
///      their submit/clear mutators with `onlyRole(ASSISTANT_ROLE)`, and must uphold the family invariant: cache only
///      position *coordinates* (never amounts), value every read live on-chain, and re-verify ownership per read, so a
///      faulty or compromised assistant can only under-report. This base intentionally prescribes no submit/clear
///      surface — each protocol's data shape differs.
abstract contract AssistedBalanceAdapter is IAssistedBalanceAdapter, AccessControl {
    /// @inheritdoc IAssistedBalanceAdapter
    bytes32 public constant ASSISTANT_ROLE = keccak256("ASSISTANT_ROLE");

    /// @param admin     Holder of `DEFAULT_ADMIN_ROLE` — administers (grants/revokes) `ASSISTANT_ROLE`. Required.
    /// @param assistant Initial holder of `ASSISTANT_ROLE`. Optional (pass `address(0)` to grant later via `admin`).
    constructor(address admin, address assistant) {
        if (admin == address(0)) revert InvalidArguments();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (assistant != address(0)) _grantRole(ASSISTANT_ROLE, assistant);
    }

    /// @inheritdoc IERC165
    /// @dev Reconciles ERC-165 across {AccessControl} (which advertises {IAccessControl}/{IERC165}) and this family's
    ///      marker. Concrete adapters override again to add `IBalanceAdapter` / `IPositionDescribable`, calling `super`.
    function supportsInterface(bytes4 interfaceId) public view virtual override(AccessControl, IERC165) returns (bool) {
        return interfaceId == type(IAssistedBalanceAdapter).interfaceId || super.supportsInterface(interfaceId);
    }
}
