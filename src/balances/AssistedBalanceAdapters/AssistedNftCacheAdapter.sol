// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AssistedBalanceAdapter} from "../AssistedBalanceAdapter.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title AssistedNftCacheAdapter
/// @author KPK
/// @notice Shared base for assisted adapters whose positions are **non-enumerable ERC-721 NFTs / per-id coordinates**
///         (Uniswap V3 / PancakeSwap V3 LP, Nexus Mutual StakingNFT, ether.fi WithdrawRequestNFT). The NFT contract
///         exposes no owner→tokenIds view, so a trusted `ASSISTANT_ROLE` submits the account's candidate `tokenId`
///         set via {submitTokenIds}; this base holds that per-account cache and its CRUD. Concrete adapters value each
///         cached id live and re-verify ownership on every read — so the cache stores **coordinates only**, never
///         amounts, and the assistant can only under-report (ADR 0015).
/// @dev The cache is the only mutable state and is `ASSISTANT_ROLE`-gated. It is an OpenZeppelin
///      `EnumerableSet.UintSet` per account (dedup + O(1) add/remove + `values()` enumeration as audited library
///      code, replacing a bespoke array + index-plus-1 map). Concrete adapters implement two hooks: {_ownerOf} (the
///      NFT's ownership read) and {_maxTokenIds} (the per-account cap).
///
///      **Submit is a delta, not a clear-and-readd.** {submitTokenIds} carries the account's COMPLETE current set
///      (full-set semantics), but {_applyReplace} reconciles it against the cached set: it only *adds* ids not already
///      cached (ownership-checked, capped — fail-loud) and *removes* cached ids absent from the submission. An
///      unchanged resubmit therefore performs **zero** external ownership reads and **zero** storage writes (the prior
///      implementation re-ran an `ownerOf` call and two `SSTORE`s per id on every resubmit). One consequence of the
///      delta: an already-cached id is **not** re-ownership-checked on resubmit — so a resubmission that still lists an
///      id the account has since transferred away does not revert (the prior clear-and-readd would have). This is safe
///      and intended: reads re-verify ownership and discard non-owned ids (the assistant can only under-report), and in
///      normal operation the assistant — which derives the list from chain state — simply omits a transferred id, so
///      the delta removes it. Events reflect the actual delta: {TokenIdSubmitted} per genuinely-added id,
///      {TokenIdCleared} per removed id (not one blanket re-emit of the whole set).
abstract contract AssistedNftCacheAdapter is AssistedBalanceAdapter {
    using EnumerableSet for EnumerableSet.UintSet;

    /// @notice Candidate tokenIds cached per account (the only thing the assistant supplies). An `EnumerableSet.UintSet`
    ///         gives dedup, O(1) membership/removal, and `values()` enumeration without hand-rolled index bookkeeping.
    mapping(address account => EnumerableSet.UintSet) private _tokenIds;

    event TokenIdSubmitted(address indexed account, uint256 indexed tokenId);
    event TokenIdCleared(address indexed account, uint256 indexed tokenId);
    event AccountCleared(address indexed account);

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
        EnumerableSet.UintSet storage set = _tokenIds[account];

        // Pass 1 — removals. Drop cached ids absent from the submitted full set FIRST. Doing removals before
        // additions means a full-set resubmit that rotates one id out and another in while the cache is AT the cap
        // frees the outgoing slot before Pass 2 adds the incoming id — otherwise the add would spuriously revert
        // `TokenIdCacheFull` even though the net size is unchanged. Snapshot `values()` first because `remove`
        // mutates the set (swap-pop reorders).
        uint256[] memory cur = set.values();
        for (uint256 i; i < cur.length; ++i) {
            if (!_contains(ids, cur[i])) {
                set.remove(cur[i]);
                emit TokenIdCleared(account, cur[i]);
            }
        }

        // Pass 2 — additions. Add only ids not already cached (ownership-checked + capped, fail-loud). A duplicate in
        // `ids` is a no-op on its second occurrence (already present after the first add).
        for (uint256 i; i < ids.length; ++i) {
            if (!set.contains(ids[i])) _addTokenId(account, ids[i]);
        }
    }

    /// @notice Drop a cached tokenId. Idempotent. GC for closed/transferred positions (stale ids already read as 0).
    function clearTokenId(address account, uint256 tokenId) external onlyRole(ASSISTANT_ROLE) {
        if (_tokenIds[account].remove(tokenId)) emit TokenIdCleared(account, tokenId);
    }

    /// @notice Drop all cached tokenIds for `account`.
    function clearAccount(address account) external onlyRole(ASSISTANT_ROLE) {
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

    /// @dev Delete the account's whole cached set (storage only, no per-id event). Repeatedly removes the current last
    ///      element (each `remove` is O(1) swap-pop). Used only by {clearAccount}; the delta path never bulk-clears.
    function _clearTokenIds(address account) private {
        EnumerableSet.UintSet storage set = _tokenIds[account];
        for (uint256 n = set.length(); n > 0; --n) {
            set.remove(set.at(n - 1));
        }
    }

    /// @dev Add a single id (cap + fail-loud ownership check). Caller guarantees the id is not already cached.
    function _addTokenId(address account, uint256 tokenId) private {
        EnumerableSet.UintSet storage set = _tokenIds[account];
        // Cap the cache so the per-account read loop stays gas-bounded (OOG there isn't caught by NAV). The assistant
        // must GC closed positions (`clearTokenId`) to make room; a real account never approaches the cap. **Revert**
        // rather than silently dropping the id — writes are fail-loud (like the ownership check below), so a full
        // cache surfaces to the assistant instead of silently omitting an owned position.
        uint256 cap = _maxTokenIds();
        if (set.length() >= cap) revert TokenIdCacheFull(account, cap);
        // Fail-loud ownership check: a non-owned / burned / non-existent id is a caller mistake.
        (address owner, bool ok) = _ownerOf(tokenId);
        if (!ok || owner != account) revert NotTokenOwner(account, tokenId);
        set.add(tokenId);
        emit TokenIdSubmitted(account, tokenId);
    }

    /// @dev Linear membership scan over a memory id list. Fine for the handful of ids a real account holds.
    function _contains(uint256[] memory list, uint256 value) private pure returns (bool) {
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
