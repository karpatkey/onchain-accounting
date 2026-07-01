// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AssistedNftCacheAdapter} from "./AssistedNftCacheAdapter.sol";
import {NftIdValuation} from "./NftIdValuation.sol";

/// @title AssistedNftValuationAdapter
/// @author KPK
/// @notice Assistant-fed NFT-cache base that also provides the shared **per-id fail-open read fan-out**: it combines
///         the `ASSISTANT_ROLE`-gated cache CRUD ({AssistedNftCacheAdapter}) with the valuation fan-out
///         ({NftIdValuation}). Used by the NFT-cache adapters that value each cached position into one or more priced
///         legs (Uniswap V3 / PancakeSwap V3 LP, Nexus Mutual staking). EtherFi's withdrawal-queue adapter stays on the
///         plain {AssistedNftCacheAdapter} base because its per-id valuation is already internally try/catch-safe and
///         emits a single leg, so it does not need the self-call isolation {NftIdValuation} provides.
/// @dev Both parents ultimately derive {NftIdCache} (the per-account id store) — a diamond that Solidity linearizes to
///      a single shared storage instance. Concrete adapters implement {_valueTokenId} / {_maxLegsPerId} (from
///      {NftIdValuation}) and {_ownerOf} / {_maxTokenIds} (from {NftIdCache}).
abstract contract AssistedNftValuationAdapter is NftIdValuation, AssistedNftCacheAdapter {
    /// @param admin     Holder of `DEFAULT_ADMIN_ROLE`.
    /// @param assistant Initial `ASSISTANT_ROLE` holder (may be `address(0)`).
    constructor(address admin, address assistant) AssistedNftCacheAdapter(admin, assistant) {}
}
