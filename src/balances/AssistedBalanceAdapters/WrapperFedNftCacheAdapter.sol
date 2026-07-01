// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {WrapperFedBalanceAdapter} from "src/balances/WrapperFedBalanceAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title WrapperFedNftCacheAdapter
/// @author KPK
/// @notice Wrapper-fed base for assisted adapters whose positions are **non-enumerable ERC-721 NFTs / per-id
///         coordinates** and are fed **on-chain** by a trusted wrapper contract (holder of `WRAPPER_ROLE`). It holds a
///         per-account `EnumerableSet.UintSet` of candidate `tokenId`s and exposes the wrapper-fed submit surface:
///         an **incremental** single {submit} / single {remove}, driven atomically by the wrapper at
///         deposit/withdraw time (versus the assistant-fed full-set replace of {AssistedNftCacheAdapter}). Concrete
///         adapters value each cached id live and re-verify ownership on every read, so the cache stores
///         **coordinates only** (never amounts) and the feeder can only under-report (ADR 0015 / 0020).
/// @dev Mirrors {AssistedNftCacheAdapter} but gates the mutators on `WRAPPER_ROLE` and adds a **permissionless**
///      {pruneStale} for cache GC of ids that are provably no longer owned by the account (e.g. burned on claim). The
///      permissionless prune is what lets a claim executed *outside* the wrapper's `WRAPPER_ROLE` context — an
///      ether.fi `claimWithdraw` delegatecalled by the owning Safe — still clean the cache: it can only *remove* an
///      id, and only one that fails the live ownership check, so it can never delete a live position (a claim burns
///      the NFT, so `_ownerOf` returns `(0, false)`). Storage is an OpenZeppelin `EnumerableSet.UintSet` per account
///      (dedup + O(1) add/remove + `values()` enumeration as audited library code). Concrete adapters implement two
///      hooks: {_ownerOf} (the NFT's ownership read) and {_maxTokenIds} (the per-account cap).
abstract contract WrapperFedNftCacheAdapter is WrapperFedBalanceAdapter {
    using EnumerableSet for EnumerableSet.UintSet;

    /// @notice Candidate tokenIds cached per account (the only thing the wrapper supplies). An `EnumerableSet.UintSet`
    ///         gives dedup, O(1) membership/removal, and `values()` enumeration without hand-rolled index bookkeeping.
    mapping(address account => EnumerableSet.UintSet) private _tokenIds;

    event TokenIdSubmitted(address indexed account, uint256 indexed tokenId);
    event TokenIdCleared(address indexed account, uint256 indexed tokenId);
    event AccountCleared(address indexed account);

    /// @param admin   Holder of `DEFAULT_ADMIN_ROLE`.
    /// @param wrapper Initial `WRAPPER_ROLE` holder — the wrapper contract (may be `address(0)`, granted later).
    constructor(address admin, address wrapper) WrapperFedBalanceAdapter(admin, wrapper) {}

    //
    // Writes (WRAPPER_ROLE)
    //

    /// @notice Track `tokenId` for `account` (idempotent). Called by the wrapper right after it forwards a request that
    ///         minted / topped-up the position. **Reverts** `NotTokenOwner` if `tokenId` is not currently owned by
    ///         `account`, and `TokenIdCacheFull` if a new id would grow the set past the cap.
    function submit(address account, uint256 tokenId) external onlyRole(WRAPPER_ROLE) {
        if (account == address(0)) revert InvalidArguments();
        _addTokenId(account, tokenId);
    }

    /// @notice Stop tracking `tokenId` for `account` (idempotent — a no-op if not cached). Called by the wrapper right
    ///         after it forwards a withdrawal/claim for the position.
    function remove(address account, uint256 tokenId) external onlyRole(WRAPPER_ROLE) {
        _removeTokenId(account, tokenId);
    }

    //
    // Writes (WRAPPER_ROLE — GC of provably-stale ids)
    //

    /// @notice Drop `tokenId` from `account`'s cache **only if** it is no longer owned by `account` (burned on claim,
    ///         transferred away, or non-existent). Like {remove} it is `WRAPPER_ROLE`-gated — so the wrapper is the
    ///         only mutator of the adapter — but it additionally verifies the id is provably stale, so it can only ever
    ///         GC a dead entry (never delete a live position). The wrapper exposes this as its own `pruneStale`, which
    ///         a delegatecalled `claimWithdraw` reaches by a regular self-call so the adapter is mutated *by the
    ///         wrapper*, not by the (role-less) depositor Safe.
    /// @dev **Reverts** `NotTokenOwner` if `tokenId` is still owned by `account` (nothing to prune) so a mistaken call
    ///      is loud rather than silently pruning a live position — the check is `_ownerOf(...) == (account, true)`.
    function pruneStale(address account, uint256 tokenId) external onlyRole(WRAPPER_ROLE) {
        (address owner, bool ok) = _ownerOf(tokenId);
        if (ok && owner == account) revert NotTokenOwner(account, tokenId);
        _removeTokenId(account, tokenId);
    }

    /// @notice Drop all cached tokenIds for `account`. Admin-gated rescue (e.g. to reset a mis-fed account); the
    ///         normal path is the wrapper's per-position {submit}/{remove}.
    function clearAccount(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _clearTokenIds(account);
        emit AccountCleared(account);
    }

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

    //
    // Internal — cache mutation
    //

    /// @dev Add a single id (idempotent; cap + fail-loud ownership check). Re-adding an already-cached id is a no-op
    ///      (no cap/ownership re-check, no event) so the wrapper can safely resubmit an id it already tracks. A new id
    ///      is capped ({_maxTokenIds}) and ownership-checked fail-loud: a full cache **reverts** `TokenIdCacheFull` and
    ///      a non-owned / burned / non-existent id **reverts** `NotTokenOwner`, rather than silently omitting an owned
    ///      position.
    function _addTokenId(address account, uint256 tokenId) private {
        EnumerableSet.UintSet storage set = _tokenIds[account];
        if (set.contains(tokenId)) return; // idempotent — nothing to validate or emit
        uint256 cap = _maxTokenIds();
        if (set.length() >= cap) revert TokenIdCacheFull(account, cap);
        (address owner, bool ok) = _ownerOf(tokenId);
        if (!ok || owner != account) revert NotTokenOwner(account, tokenId);
        set.add(tokenId);
        emit TokenIdSubmitted(account, tokenId);
    }

    /// @dev Drop a cached tokenId. Idempotent — no event when the id was not cached.
    function _removeTokenId(address account, uint256 tokenId) private {
        if (_tokenIds[account].remove(tokenId)) emit TokenIdCleared(account, tokenId);
    }

    /// @dev Delete the account's whole cached set (storage only, no per-id event). Repeatedly removes the current last
    ///      element (each `remove` is O(1) swap-pop). Callers emit {AccountCleared} themselves.
    function _clearTokenIds(address account) private {
        EnumerableSet.UintSet storage set = _tokenIds[account];
        for (uint256 n = set.length(); n > 0; --n) {
            set.remove(set.at(n - 1));
        }
    }

    //
    // Hooks (concrete adapter)
    //

    /// @notice Reads the NFT's owner for the write-time ownership check and the {pruneStale} liveness check. MUST NOT
    ///         revert — return `(0, false)` for a burned / non-existent id (e.g. wrap the NFT contract call in
    ///         try/catch).
    /// @return owner The current owner (meaningful only when `ok`).
    /// @return ok    True if the id exists / the read succeeded.
    function _ownerOf(uint256 tokenId) internal view virtual returns (address owner, bool ok);

    /// @notice The per-account cache cap (read-loop gas bound).
    function _maxTokenIds() internal pure virtual returns (uint256);
}
