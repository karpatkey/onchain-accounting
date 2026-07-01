// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {WrapperFedBalanceAdapter} from "src/balances/WrapperFedBalanceAdapter.sol";
import {NftIdValuation} from "./NftIdValuation.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title WrapperFedNftValuationAdapter
/// @author KPK
/// @notice Wrapper-fed NFT-cache base that provides the shared **per-id fail-open read fan-out**: it combines the
///         `WRAPPER_ROLE`-gated cache CRUD with the valuation fan-out ({NftIdValuation}). It is the wrapper-fed
///         counterpart of {AssistedNftValuationAdapter} — same cache + valuation machinery ({NftIdCache} /
///         {NftIdValuation}), but the feeder is an on-chain wrapper contract holding `WRAPPER_ROLE` instead of an
///         off-chain agent holding `ASSISTANT_ROLE`, and the submit surface is **incremental** (single add / single
///         remove, driven atomically at deposit/withdraw) rather than the assistant-fed full-set replace.
/// @dev Concrete adapters implement {_valueTokenId} / {_maxLegsPerId} (from {NftIdValuation}) and {_ownerOf} /
///      {_maxTokenIds} (from {NftIdCache}). The family invariant holds exactly as in the assistant-fed case: the cache
///      stores ids only, values are read live, and ownership is re-verified per read, so the wrapper can only
///      under-report. {submit} fails loud (`NotTokenOwner` / `TokenIdCacheFull`) so a bad id surfaces to the wrapper
///      caller rather than being silently dropped; {remove} is idempotent.
abstract contract WrapperFedNftValuationAdapter is NftIdValuation, WrapperFedBalanceAdapter {
    /// @param admin   Holder of `DEFAULT_ADMIN_ROLE`.
    /// @param wrapper Initial `WRAPPER_ROLE` holder — the wrapper contract (may be `address(0)`, granted later).
    constructor(address admin, address wrapper) WrapperFedBalanceAdapter(admin, wrapper) {}

    /// @notice Track `tokenId` for `account` (idempotent). Called by the wrapper right after it forwards a deposit that
    ///         minted / topped-up the position. **Reverts** `NotTokenOwner` if `tokenId` is not currently owned by
    ///         `account`, and `TokenIdCacheFull` if a new id would grow the set past the cap.
    function submit(address account, uint256 tokenId) external onlyRole(WRAPPER_ROLE) {
        if (account == address(0)) revert InvalidArguments();
        _addTokenId(account, tokenId);
    }

    /// @notice Stop tracking `tokenId` for `account` (idempotent — a no-op if not cached). Called by the wrapper right
    ///         after it forwards a withdrawal for the position.
    function remove(address account, uint256 tokenId) external onlyRole(WRAPPER_ROLE) {
        _removeTokenId(account, tokenId);
    }

    /// @notice Drop all cached tokenIds for `account`. Admin-gated rescue (e.g. to reset a mis-fed account); the
    ///         normal path is the wrapper's per-position {submit}/{remove}.
    function clearAccount(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _clearTokenIds(account);
        emit AccountCleared(account);
    }
}
