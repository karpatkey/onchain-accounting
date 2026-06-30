// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AssistedNftCacheAdapter} from "./AssistedNftCacheAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title AssistedNftValuationAdapter
/// @author KPK
/// @notice Extends {AssistedNftCacheAdapter} with the shared **per-id fail-open read fan-out** used by the NFT-cache
///         adapters that value each cached position into one or more priced legs (Uniswap V3 / PancakeSwap V3 LP,
///         Nexus Mutual staking). EtherFi's withdrawal-queue adapter stays on the plain {AssistedNftCacheAdapter}
///         base because its per-id valuation is already internally try/catch-safe and emits a single leg, so it does
///         not need the self-call isolation this layer provides.
/// @dev The fan-out values each cached id behind an external `this.valueTokenIdSelf(...)` staticcall wrapped in
///      try/catch, so a revert in one id's live reads (slot0 / positions / ticks / getTokens / …) discards only THAT
///      id and never propagates out of `getAdapterPositions` — where NAVCalculator's per-adapter try/catch would
///      otherwise fail-open and drop the account's ENTIRE position set for this adapter. This is the fault-isolation
///      pattern that previously lived, copied verbatim, in each concrete adapter. Concrete adapters implement two
///      hooks: {_valueTokenId} (value one id into its legs) and {_maxLegsPerId} (the per-id leg upper bound, used to
///      size the scratch buffer). A read-once context (e.g. the registered-asset snapshot, or the resolved underlying
///      Asset) is fetched by the concrete `getAdapterPositions`, passed to {_collectLegs} as opaque `bytes`, and
///      threaded unchanged into each {_valueTokenId} call — so it is fetched once per read, not once per id.
abstract contract AssistedNftValuationAdapter is AssistedNftCacheAdapter {
    /// @param admin     Holder of `DEFAULT_ADMIN_ROLE`.
    /// @param assistant Initial `ASSISTANT_ROLE` holder (may be `address(0)`).
    constructor(address admin, address assistant) AssistedNftCacheAdapter(admin, assistant) {}

    /// @notice Values all of `account`'s cached ids into a flat leg array, isolating a faulty id so it cannot zero
    ///         out the whole set. The shared read template for the NFT-valuation adapters.
    /// @param account The account whose cached ids are valued.
    /// @param assetFilter Optional asset filter (`address(0)` for all), threaded to {_valueTokenId}.
    /// @param ctx Opaque read-once context (e.g. `abi.encode(registeredAssets)` or `abi.encode(underlyingAsset)`),
    ///        fetched once by the caller and passed unchanged to every {_valueTokenId} call.
    function _collectLegs(address account, address assetFilter, bytes memory ctx)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        uint256[] memory ids = _cachedTokenIds(account);
        if (ids.length == 0) return new INAVCalculator.PositionBalance[](0);

        INAVCalculator.PositionBalance[] memory temp =
            new INAVCalculator.PositionBalance[](ids.length * _maxLegsPerId());
        uint256 count;
        for (uint256 i; i < ids.length; ++i) {
            // Per-id fault isolation (fail-open, ADR 0015): a revert in this id's live reads is caught here and only
            // that id is discarded; it never propagates out of getAdapterPositions.
            try this.valueTokenIdSelf(account, ids[i], assetFilter, ctx) returns (
                INAVCalculator.PositionBalance[] memory legs
            ) {
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
    ///         {_collectLegs}. `msg.sender`-guarded to `address(this)` so it is not a usable external surface; it is
    ///         `external` (hence the self-call is a staticcall) ONLY to give each id's valuation its own revert frame.
    function valueTokenIdSelf(address account, uint256 tokenId, address assetFilter, bytes calldata ctx)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        if (msg.sender != address(this)) revert NotAuthorized();
        return _valueTokenId(account, tokenId, assetFilter, ctx);
    }

    /// @notice Values a single cached `tokenId` into its legs (empty array if it contributes nothing — not owned,
    ///         unregistered, zero amounts, filtered out). Implemented per adapter; reached only via the self-call in
    ///         {_collectLegs}, so it may revert freely (the caller isolates it). It MUST re-verify ownership live.
    /// @param ctx The read-once context built by the concrete `getAdapterPositions` (decode to the adapter's shape).
    function _valueTokenId(address account, uint256 tokenId, address assetFilter, bytes memory ctx)
        internal
        view
        virtual
        returns (INAVCalculator.PositionBalance[] memory);

    /// @notice Upper bound on legs emitted per id (scratch-buffer sizing in {_collectLegs}). E.g. Uniswap V3 emits up
    ///         to 4 (liq0/liq1/fee0/fee1); Nexus up to 2 (staking/rewards).
    function _maxLegsPerId() internal pure virtual returns (uint256);
}
