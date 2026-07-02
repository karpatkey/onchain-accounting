// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AssistedNftIdCache} from "./AssistedNftIdCache.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title AssistedNftIdValuation
/// @author KPK
/// @notice Extends {AssistedNftIdCache} with the **per-id fail-open read fan-out** for adapters whose per-id valuation
///         can revert (e.g. Nexus Mutual's `StakingViewer.getTokens`). Each cached id is valued behind an external
///         `this.valueTokenIdSelf(...)` staticcall wrapped in try/catch, so a revert in one id's live reads discards
///         only THAT id and never propagates out of {getAdapterPositions} — where NAVCalculator's per-adapter
///         try/catch would otherwise fail-open and drop the account's ENTIRE position set for this adapter.
/// @dev Adapters whose per-id valuation is already internally try/catch-safe (single-leg withdrawal-request adapters)
///      can stay on the plain {AssistedNftIdCache} base and skip this isolation layer. Concrete adapters here still
///      implement the same {_valueTokenId} / {_maxLegsPerId} / {_ownerOf} / {_maxTokenIds} hooks.
abstract contract AssistedNftIdValuation is AssistedNftIdCache {
    /// @param underlyingToken_ The reported underlying asset. Must be non-zero.
    /// @param navCalculator_   NAVCalculator. Must be a contract.
    constructor(address underlyingToken_, address navCalculator_) AssistedNftIdCache(underlyingToken_, navCalculator_) {}

    /// @inheritdoc AssistedNftIdCache
    /// @dev Overrides the direct loop with per-id fault isolation: each id is valued in its own external call frame, so
    ///      a revert only discards that id.
    function _collect(address account, INAVCalculator.Asset memory underlying)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        uint256[] memory ids = _cachedTokenIds(account);
        if (ids.length == 0) return new INAVCalculator.PositionBalance[](0);

        INAVCalculator.PositionBalance[] memory temp =
            new INAVCalculator.PositionBalance[](ids.length * _maxLegsPerId());
        uint256 count;
        for (uint256 i; i < ids.length; ++i) {
            // Per-id fault isolation (fail-open): a revert in this id's live reads is caught here and only that id is
            // discarded; it never propagates out of getAdapterPositions.
            try this.valueTokenIdSelf(account, ids[i], underlying) returns (INAVCalculator.PositionBalance[] memory legs)
            {
                for (uint256 j; j < legs.length; ++j) {
                    temp[count++] = legs[j];
                }
            } catch {}
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i; i < count; ++i) {
            positions[i] = temp[i];
        }
    }

    /// @notice External self-call entrypoint for {_valueTokenId}, enabling the per-id try/catch isolation in
    ///         {_collect}. `msg.sender`-guarded to `address(this)` so it is not a usable external surface; it is
    ///         `external` (hence the self-call is a staticcall) ONLY to give each id's valuation its own revert frame.
    function valueTokenIdSelf(address account, uint256 tokenId, INAVCalculator.Asset calldata underlying)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        if (msg.sender != address(this)) revert NotAuthorized();
        return _valueTokenId(account, tokenId, underlying);
    }
}
