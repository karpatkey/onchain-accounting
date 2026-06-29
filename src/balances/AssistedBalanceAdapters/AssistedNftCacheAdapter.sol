// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AssistedBalanceAdapter} from "../AssistedBalanceAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title AssistedNftCacheAdapter
/// @author KPK
/// @notice Shared base for assisted adapters whose positions are **non-enumerable ERC-721 NFTs** (Uniswap V3 /
///         PancakeSwap V3 LP, Nexus Mutual StakingNFT). The NFT contract exposes no owner→tokenIds view, so a
///         trusted `ASSISTANT_ROLE` submits the account's candidate `tokenId` set via {submitTokenIds}; this base
///         holds that per-account cache and its CRUD. Concrete adapters value each cached id live and re-verify
///         ownership on every read — so the cache stores **coordinates only**, never amounts, and the assistant
///         can only under-report (ADR 0015).
/// @dev The cache is the only mutable state and is `ASSISTANT_ROLE`-gated. Writes are **fail-loud**: {submitTokenIds}
///      replaces the account's whole set and reverts `NotTokenOwner` on any id the account does not currently own and
///      `TokenIdCacheFull` past the per-adapter cap. Reads (in the concrete adapter) re-verify ownership and discard
///      ids no longer owned, so correctness does not depend on the write-time check. Concrete adapters implement two
///      hooks: {_ownerOf} (the NFT's ownership read) and {_maxTokenIds} (the cap).
abstract contract AssistedNftCacheAdapter is AssistedBalanceAdapter {
    /// @notice Candidate tokenIds cached per account (the only thing the assistant supplies).
    mapping(address account => uint256[] tokenIds) private _tokenIds;

    /// @dev `idxPlus1` = index of `tokenId` in `_tokenIds[account]` plus 1. Zero ⇒ not present (dedup + O(1) removal).
    mapping(address account => mapping(uint256 tokenId => uint256)) private _tokenIdIdxPlus1;

    event TokenIdSubmitted(address indexed account, uint256 indexed tokenId);
    event TokenIdCleared(address indexed account, uint256 indexed tokenId);
    event AccountCleared(address indexed account);

    /// @param admin     Holder of `DEFAULT_ADMIN_ROLE`.
    /// @param assistant Initial `ASSISTANT_ROLE` holder (may be `address(0)`).
    constructor(address admin, address assistant) AssistedBalanceAdapter(admin, assistant) {}

    //
    // Writes (ASSISTANT_ROLE)
    //

    /// @notice Submit `account`'s **complete** candidate tokenId set — this **replaces** the account's cached set
    ///         (full-set semantics, not a delta). Duplicates collapse. **Reverts** `NotTokenOwner` if any id is not
    ///         currently owned by `account` and `TokenIdCacheFull` past the cap; the revert is atomic, so a bad list
    ///         leaves the prior set untouched.
    function submitTokenIds(address account, uint256[] calldata tokenIds) external onlyRole(ASSISTANT_ROLE) {
        _submit(account, abi.encode(tokenIds)); // typed wrapper → shared replace chokepoint (_applyReplace)
    }

    /// @notice Batch variant: for each account, its sublist **replaces** that account's cached set. `accounts` and
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
    /// @dev Decodes the `uint256[]` token-id list and replaces `account`'s cached set (clear then re-add, fail-loud).
    function _applyReplace(address account, bytes memory data) internal override {
        uint256[] memory ids = abi.decode(data, (uint256[]));
        _clearTokenIds(account);
        for (uint256 i; i < ids.length; ++i) {
            _addTokenId(account, ids[i]);
        }
    }

    /// @notice Drop a cached tokenId. Idempotent. GC for closed/transferred positions (stale ids already read as 0).
    function clearTokenId(address account, uint256 tokenId) external onlyRole(ASSISTANT_ROLE) {
        if (_tokenIdIdxPlus1[account][tokenId] == 0) return;
        _removeTokenId(account, tokenId);
        emit TokenIdCleared(account, tokenId);
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
        return _tokenIds[account];
    }

    /// @dev The cached candidate ids for `account`, for the concrete adapter's per-NFT valuation loop (which
    ///      re-verifies ownership live and discards ids no longer owned).
    function _cachedTokenIds(address account) internal view returns (uint256[] memory) {
        return _tokenIds[account];
    }

    //
    // Internal — cache mutation
    //

    /// @dev Delete the account's cached id set (storage only, no event). Shared by `clearAccount` and the
    ///      replace-on-submit path.
    function _clearTokenIds(address account) private {
        uint256[] storage ids = _tokenIds[account];
        for (uint256 i; i < ids.length; ++i) {
            delete _tokenIdIdxPlus1[account][ids[i]];
        }
        delete _tokenIds[account];
    }

    function _addTokenId(address account, uint256 tokenId) private {
        if (_tokenIdIdxPlus1[account][tokenId] != 0) return; // already cached (idempotent no-op)
        // Cap the cache so the per-account read loop stays gas-bounded (OOG there isn't caught by NAV). The assistant
        // must GC closed positions (`clearTokenId`) to make room; a real account never approaches the cap. **Revert**
        // rather than silently dropping the id — writes are fail-loud (like the ownership check below), so a full
        // cache surfaces to the assistant instead of silently omitting an owned position.
        uint256 cap = _maxTokenIds();
        if (_tokenIds[account].length >= cap) revert TokenIdCacheFull(account, cap);
        // Fail-loud ownership check: a non-owned / burned / non-existent id is a caller mistake.
        (address owner, bool ok) = _ownerOf(tokenId);
        if (!ok || owner != account) revert NotTokenOwner(account, tokenId);
        _tokenIds[account].push(tokenId);
        _tokenIdIdxPlus1[account][tokenId] = _tokenIds[account].length;
        emit TokenIdSubmitted(account, tokenId);
    }

    function _removeTokenId(address account, uint256 tokenId) private {
        uint256 idxPlus1 = _tokenIdIdxPlus1[account][tokenId];
        if (idxPlus1 == 0) return;
        uint256 idx = idxPlus1 - 1;
        uint256[] storage list = _tokenIds[account];
        uint256 lastIdx = list.length - 1;
        if (idx != lastIdx) {
            uint256 lastId = list[lastIdx];
            list[idx] = lastId;
            _tokenIdIdxPlus1[account][lastId] = idx + 1;
        }
        list.pop();
        delete _tokenIdIdxPlus1[account][tokenId];
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
