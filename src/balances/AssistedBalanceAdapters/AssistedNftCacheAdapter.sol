// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AssistedBalanceAdapter} from "../AssistedBalanceAdapter.sol";
import {NftIdCache} from "./NftIdCache.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title AssistedNftCacheAdapter
/// @author KPK
/// @notice Assistant-fed base for adapters whose positions are **non-enumerable ERC-721 NFTs / per-id coordinates**
///         (Uniswap V3 / PancakeSwap V3 LP, Nexus Mutual StakingNFT, ether.fi WithdrawRequestNFT). The NFT contract
///         exposes no owner→tokenIds view, so a trusted `ASSISTANT_ROLE` off-chain agent submits the account's
///         candidate `tokenId` set via {submitTokenIds}. It combines the role-agnostic per-account id store
///         ({NftIdCache}) with the assisted-family access control ({AssistedBalanceAdapter}, `ASSISTANT_ROLE`), and
///         adds the `ASSISTANT_ROLE`-gated CRUD surface on top of {NftIdCache}'s internal mutators. Concrete adapters
///         value each cached id live and re-verify ownership on every read — so the cache stores **coordinates only**,
///         never amounts, and the assistant can only under-report (ADR 0015).
/// @dev The cache is the only mutable state and is `ASSISTANT_ROLE`-gated. Concrete adapters implement two hooks
///      (declared on {NftIdCache}): {_ownerOf} (the NFT's ownership read) and {_maxTokenIds} (the per-account cap).
///
///      **Submit is a delta, not a clear-and-readd.** {submitTokenIds} carries the account's COMPLETE current set
///      (full-set semantics), but {_applyReplace} reconciles it against the cached set: it only *adds* ids not already
///      cached (ownership-checked, capped — fail-loud) and *removes* cached ids absent from the submission. An
///      unchanged resubmit therefore performs **zero** external ownership reads and **zero** storage writes ({_addTokenId}
///      is idempotent and short-circuits on an already-cached id). One consequence of the delta: an already-cached id
///      is **not** re-ownership-checked on resubmit — so a resubmission that still lists an id the account has since
///      transferred away does not revert. This is safe and intended: reads re-verify ownership and discard non-owned
///      ids (the assistant can only under-report), and in normal operation the assistant — which derives the list from
///      chain state — simply omits a transferred id, so the delta removes it. Events reflect the actual delta:
///      {TokenIdSubmitted} per genuinely-added id, {TokenIdCleared} per removed id (not one blanket re-emit of the
///      whole set).
abstract contract AssistedNftCacheAdapter is NftIdCache, AssistedBalanceAdapter {
    /// @param admin     Holder of `DEFAULT_ADMIN_ROLE`.
    /// @param assistant Initial `ASSISTANT_ROLE` holder (may be `address(0)`).
    constructor(address admin, address assistant) AssistedBalanceAdapter(admin, assistant) {}

    //
    // Writes (ASSISTANT_ROLE)
    //

    /// @notice Submit `account`'s **complete** candidate tokenId set. Full-set semantics: the cached set is reconciled
    ///         to exactly this list (delta — see the contract NatSpec). Duplicates collapse. **Reverts** `NotTokenOwner` if a
    ///         newly-added id is not currently owned by `account`, and `TokenIdCacheFull` if a new id would grow the set
    ///         past the cap; the revert is atomic, so a bad list leaves the prior set untouched.
    function submitTokenIds(address account, uint256[] calldata tokenIds) external onlyRole(ASSISTANT_ROLE) {
        _submit(account, abi.encode(tokenIds)); // typed wrapper → shared replace chokepoint (_applyReplace)
    }

    /// @notice Batch variant: for each account, its sublist reconciles that account's cached set. `accounts` and
    ///         `tokenIds` must have the same length.
    function submitTokenIdsBatch(address[] calldata accounts, uint256[][] calldata tokenIds)
        external
        onlyRole(ASSISTANT_ROLE)
    {
        bytes[] memory data = new bytes[](tokenIds.length);
        for (uint256 i; i < tokenIds.length; ++i) {
            data[i] = abi.encode(tokenIds[i]);
        }
        _submitBatch(accounts, data);
    }

    /// @inheritdoc AssistedBalanceAdapter
    /// @dev Decodes the `uint256[]` token-id list and reconciles `account`'s cached set against it as a **delta**:
    ///      add submitted ids not already cached (fail-loud: cap + ownership), remove cached ids absent from the
    ///      submission. Skipping already-cached ids is what makes an unchanged resubmit free (no `ownerOf`, no SSTORE).
    function _applyReplace(address account, bytes memory data) internal override {
        uint256[] memory ids = abi.decode(data, (uint256[]));

        // Pass 1 — removals. Drop cached ids absent from the submitted full set FIRST. Doing removals before
        // additions means a full-set resubmit that rotates one id out and another in while the cache is AT the cap
        // frees the outgoing slot before Pass 2 adds the incoming id — otherwise the add would spuriously revert
        // `TokenIdCacheFull` even though the net size is unchanged. Snapshot the current ids first because removal
        // mutates the underlying set (swap-pop reorders).
        uint256[] memory cur = _cachedTokenIds(account);
        for (uint256 i; i < cur.length; ++i) {
            if (!_contains(ids, cur[i])) _removeTokenId(account, cur[i]);
        }

        // Pass 2 — additions. {_addTokenId} is idempotent (a no-op for an already-cached id), so submitting the full
        // set only performs ownership-checked, capped adds for genuinely new ids. A duplicate in `ids` collapses.
        for (uint256 i; i < ids.length; ++i) {
            _addTokenId(account, ids[i]);
        }
    }

    /// @notice Drop a cached tokenId. Idempotent. GC for closed/transferred positions (stale ids already read as 0).
    function clearTokenId(address account, uint256 tokenId) external onlyRole(ASSISTANT_ROLE) {
        _removeTokenId(account, tokenId);
    }

    /// @notice Drop all cached tokenIds for `account`.
    function clearAccount(address account) external onlyRole(ASSISTANT_ROLE) {
        _clearTokenIds(account);
        emit AccountCleared(account);
    }
}
