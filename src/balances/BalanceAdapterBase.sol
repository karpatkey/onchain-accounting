// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBalanceAdapter} from "./IBalanceAdapter.sol";
import {IPositionDescribable} from "./IPositionDescribable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title BalanceAdapterBase
/// @author KPK
/// @notice Shared base for the plain (immutable, non-assisted) balance adapters. It declares the common
///         {IBalanceAdapter} + {IPositionDescribable} surface and implements the one piece every plain adapter
///         repeats verbatim — `supportsInterface` advertising that pair plus {IERC165}. Concrete adapters implement
///         the balance/position reads and the {IPositionDescribable} display hooks.
/// @dev Plain adapters stay immutable (no Ownable/admin). The assisted family has its own base
///      ({AssistedCoordCache}); meta-adapters have {MetaBalanceAdapter}. `supportsInterface` is `public virtual`
///      so an adapter advertising an extra interface can override and `super`-chain — it was `external`, which
///      made that impossible (Solidity cannot reach an `external` function through `super`), forcing any such
///      adapter to re-declare the whole base list and silently drift from it. `public` matches the
///      {AssistedCoordCache} precedent, where the Nexus adapter really does `super`-chain. It stays `pure`
///      because the answer is a compile-time comparison; an override that must read state (an immutable, say)
///      cannot widen it, and should expose its extra interface from a `pure` override here regardless.
abstract contract BalanceAdapterBase is IBalanceAdapter, IPositionDescribable {
    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IPositionDescribable).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}
