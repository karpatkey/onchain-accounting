// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title NftIdCache
/// @author KPK
/// @notice Role-agnostic per-account cache of **non-enumerable ERC-721 tokenIds / per-id coordinates**, shared by the
///         assistant-fed and wrapper-fed NFT adapter families. The NFT contract exposes no owner→tokenIds view, so a
///         trusted feeder (an off-chain `ASSISTANT_ROLE` agent, or an on-chain `WRAPPER_ROLE` contract) supplies the
///         account's candidate `tokenId` set; this base holds that per-account cache and its CRUD. Concrete adapters
///         value each cached id live and re-verify ownership on every read — so the cache stores **coordinates only**,
///         never amounts, and the feeder can only under-report (ADR 0015).
/// @dev This base contributes **no access control** — it exposes only `internal` mutators (`_addTokenId`,
///      `_removeTokenId`, `_clearTokenIds`). The role-specific bases layered on top ({AssistedNftCacheAdapter} with
///      `ASSISTANT_ROLE`, {WrapperFedNftValuationAdapter} with `WRAPPER_ROLE`) expose the public, role-gated submit
///      surface and route into these mutators, so the per-account validation and the cap/ownership rules live in one
///      place regardless of feeder. Storage is an OpenZeppelin `EnumerableSet.UintSet` per account (dedup + O(1)
///      add/remove + `values()` enumeration as audited library code). Concrete adapters implement two hooks: {_ownerOf}
///      (the NFT's ownership read) and {_maxTokenIds} (the per-account cap).
abstract contract NftIdCache {
    using EnumerableSet for EnumerableSet.UintSet;

    /// @notice Candidate tokenIds cached per account (the only thing the feeder supplies). An `EnumerableSet.UintSet`
    ///         gives dedup, O(1) membership/removal, and `values()` enumeration without hand-rolled index bookkeeping.
    mapping(address account => EnumerableSet.UintSet) private _tokenIds;

    event TokenIdSubmitted(address indexed account, uint256 indexed tokenId);
    event TokenIdCleared(address indexed account, uint256 indexed tokenId);
    event AccountCleared(address indexed account);

    //
    // Reads
    //

    /// @notice Candidate tokenIds currently cached for `account` (display/debug; not ownership-filtered).
    function tokenIdsOf(address account) external view returns (uint256[] memory) {
        return _tokenIds[account].values();
    }

    /// @dev The cached candidate ids for `account`, for the concrete adapter's per-NFT valuation loop (which
    ///      re-verifies ownership live and discards ids no longer owned).
    function _cachedTokenIds(address account) internal view returns (uint256[] memory) {
        return _tokenIds[account].values();
    }

    /// @dev Whether `tokenId` is currently cached for `account`.
    function _isCachedTokenId(address account, uint256 tokenId) internal view returns (bool) {
        return _tokenIds[account].contains(tokenId);
    }

    //
    // Internal — cache mutation (called by the role-gated public wrappers in the role-specific bases)
    //

    /// @dev Add a single id (idempotent; cap + fail-loud ownership check). Re-adding an already-cached id is a no-op
    ///      (no cap/ownership re-check, no event) so a feeder can safely resubmit an id it already tracks. A new id is
    ///      capped ({_maxTokenIds}) and ownership-checked fail-loud: a full cache **reverts** `TokenIdCacheFull` (the
    ///      feeder must GC closed positions to make room; a real account never approaches the cap) and a non-owned /
    ///      burned / non-existent id **reverts** `NotTokenOwner` (a caller mistake), rather than silently omitting an
    ///      owned position.
    function _addTokenId(address account, uint256 tokenId) internal {
        EnumerableSet.UintSet storage set = _tokenIds[account];
        if (set.contains(tokenId)) return; // idempotent — nothing to validate or emit
        uint256 cap = _maxTokenIds();
        if (set.length() >= cap) revert TokenIdCacheFull(account, cap);
        (address owner, bool ok) = _ownerOf(tokenId);
        if (!ok || owner != account) revert NotTokenOwner(account, tokenId);
        set.add(tokenId);
        emit TokenIdSubmitted(account, tokenId);
    }

    /// @dev Drop a cached tokenId. Idempotent — returns false (no event) when the id was not cached. GC for
    ///      closed/transferred positions (stale ids already read as 0).
    function _removeTokenId(address account, uint256 tokenId) internal returns (bool removed) {
        if (_tokenIds[account].remove(tokenId)) {
            emit TokenIdCleared(account, tokenId);
            return true;
        }
        return false;
    }

    /// @dev Delete the account's whole cached set (storage only, no per-id event). Repeatedly removes the current last
    ///      element (each `remove` is O(1) swap-pop). Callers emit {AccountCleared} themselves.
    function _clearTokenIds(address account) internal {
        EnumerableSet.UintSet storage set = _tokenIds[account];
        for (uint256 n = set.length(); n > 0; --n) {
            set.remove(set.at(n - 1));
        }
    }

    /// @dev Linear membership scan over a memory id list. Fine for the handful of ids a real account holds. Shared by
    ///      the delta-reconciliation feeders (e.g. the assistant-fed full-set replace).
    function _contains(uint256[] memory list, uint256 value) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == value) return true;
        }
        return false;
    }

    //
    // Hooks (concrete adapter)
    //

    /// @notice Reads the NFT's owner for the write-time ownership check. MUST NOT revert — return `(0, false)` for a
    ///         burned / non-existent id (e.g. wrap the NFT contract call in try/catch).
    /// @return owner The current owner (meaningful only when `ok`).
    /// @return ok    True if the id exists / the read succeeded.
    function _ownerOf(uint256 tokenId) internal view virtual returns (address owner, bool ok);

    /// @notice The per-account cache cap (read-loop gas bound).
    function _maxTokenIds() internal pure virtual returns (uint256);
}
