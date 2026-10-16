// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {StaticCallLib} from "src/utils/StaticCallLib.sol";
import {IV4PositionManager} from "src/balances/MetaBalanceAdapters/uniswap/v4/IUniswapV4.sol";

/// @title V4PositionIndex
/// @author KPK
/// @notice Holder -> tokenId discovery for Uniswap V4 positions, because chain state cannot answer it. Standalone and
///         permissionless: not an adapter, not registered on NAVCalculator, holds no balances and values nothing.
///
/// @dev **THE PROBLEM.** V3's NonfungiblePositionManager is `ERC721Enumerable`, so
///      `UniswapV3PoolsMetaBalanceAdapter` walks `tokenOfOwnerByIndex(holder, i)` and is done. V4's PositionManager
///      is **Solmate ERC721 with no enumeration extension**: `balanceOf(holder)` works, `tokenOfOwnerByIndex`
///      **reverts** — measured on 4663, the selector is absent from the deployed `0x58daec31…4fa7`. A holder's
///      tokenIds exist only in `Transfer` logs, and a `view` on the NAV hot path cannot read logs, so the mapping has
///      to be materialised into storage by someone.
///
/// @dev **WHY THIS IS NOT AN `AssistedCoordCache` MEMBER OF THE ADR 0015/0018 FAMILY**, which is the first question
///      this contract should be asked, since ADR 0015's premise — an NFT manager that is not enumerable — is exactly
///      the premise here, and is the premise that was found FALSE for V3 in the 2026-07 amendment that reverted
///      Uniswap V3 and PancakeSwap V3 out of the assisted family. Four reasons, in order of weight:
///
///      1. **Ownership is verifiable on-chain, so entries are validated at write time instead of being keyed by
///         `msg.sender`.** ADR 0018's `submit`/`remove` key a cache by its caller precisely because the protocol
///         offers no way to check that a submitted coordinate belongs to the account — the caller's own namespace is
///         the only safe place to put an unverifiable claim. V4 has `ownerOf(tokenId)`. {index} therefore does not
///         take the caller's word for anything: it reads the owner and files the id under **whatever the
///         PositionManager says**, so there is no argument any caller can pass that attributes a position to a
///         holder who does not own it. A `msg.sender`-keyed cache would be strictly worse here — it would partition
///         verified truth by who happened to pay the gas.
///      2. **The holder is a Sickle, which cannot conveniently transact.** The assisted family's feeding model (ADR
///         0018) is a delegatecall `BalanceAdapterAssistant` executed BY the account, so the account is the
///         submitter. The account here is a vfat Sickle: a per-owner proxy whose calls must be routed through vfat's
///         own strategy entrypoints. Requiring the position holder to be the submitter would put NAV completeness
///         behind a vfat transaction, and the one thing the 4663 history proves is that anything standing between a
///         rebalance and the index is where the gap opens (measured: 17 to 20 Sep 2026, one unindexed tokenId hid
///         29.5% of the fund from its share price for three days).
///      3. **It is a hint, not an authority, and the consumer re-verifies.**
///         `UniswapV4SicklePoolsMetaBalanceAdapter` re-checks `ownerOf(tokenId) == holder` and re-derives the pool id
///         from the position's own PoolKey before a single wei is valued. A stale entry left by a rebalance and a
///         deliberately poisoned one are the same thing to it — skipped. The index can therefore only ever fail to
///         grow the NAV, never inflate it, which is the same **under-report-only** safety property ADR 0015 §17-21
///         requires of the assisted family, reached by a different route.
///      4. **It is one contract shared by every holder, not one cache per adapter.** `AssistedCoordCache` is both
///         cache and adapter; this is neither. Keeping it standalone means a second V4 consumer reuses the filed ids
///         instead of refilling its own copy.
///
/// @dev **WHY ENTRIES GO STALE, AND WHY THAT IS NORMAL.** A vfat rebalance BURNS the position NFT and mints a new
///      one, so an id filed today is dead tomorrow. Staleness is the expected state, not an error: {liveTokenIds} and
///      {liveCount} re-check ownership at read time, the adapter re-checks it again before valuing anything, and
///      {prune} reclaims the storage. Measured on 4663 at block 90,186,157: the kRHUSD Sickle
///      `0x6f94B45B…23Ba` has 20 filed ids of which 8 are still owned, and `balanceOf` is 8 — i.e. 12 dead entries
///      sitting next to full coverage.
///
/// @dev **WHY {prune} REFUSES A LIVE ENTRY.** It reverts `EntryStillValid` rather than skipping, so an open pruning
///      function cannot be used to blind the adapter, and a caller who got the list wrong finds out instead of
///      quietly succeeding and leaving a hole in the NAV.
///
/// @dev **KNOWN LIMIT, stated rather than left to be discovered.** {index} is unbounded, so a griefer can file junk
///      ids against a holder. Each junk id costs the adapter one `ownerOf` staticcall per instance it is asked
///      about; on 4663 that was estimated at roughly 330k gas per junk id against a 10.0M read and a ~32M per-tx
///      ceiling (**simulated**, 2 Oct 2026). That is a loud failure (the read runs out of gas and the NAV refuses)
///      rather than a wrong number, and the adapter caps its own iteration so the cap, not this contract, is what
///      bounds the valuation loop.
contract V4PositionIndex {
    /// @notice The Uniswap V4 PositionManager this index files positions from. Immutable; the ownership authority.
    IV4PositionManager public immutable POSITION_MANAGER;

    /// @dev holder -> filed ids. May contain stale ids; never duplicates.
    mapping(address => uint256[]) private _tokenIds;

    /// @dev holder -> tokenId -> 1-based position in `_tokenIds[holder]` (0 = not filed).
    mapping(address => mapping(uint256 => uint256)) private _slotOf;

    event Indexed(address indexed holder, uint256 indexed tokenId);
    event Pruned(address indexed holder, uint256 indexed tokenId);

    /// @notice `ownerOf` gave no answer: the tokenId was never minted, or has been burned.
    error NonexistentPosition(uint256 tokenId);
    /// @notice Nothing filed for this (holder, tokenId) pair.
    error NotIndexed(address holder, uint256 tokenId);
    /// @notice The entry is still owned by `holder`; pruning live data is not a thing this contract does.
    error EntryStillValid(address holder, uint256 tokenId);

    /// @param positionManager_ The Uniswap V4 PositionManager for this chain. Must be a contract.
    constructor(address positionManager_) {
        AddressCheckLib.requireContract(positionManager_, "PositionManager");
        POSITION_MANAGER = IV4PositionManager(positionManager_);
    }

    /// @notice File each tokenId under its CURRENT owner.
    /// @dev Idempotent: an id already filed under that owner is skipped, never duplicated. Note that an id whose
    ///      owner has changed is filed again under the NEW owner while the OLD holder's entry stays behind as a stale
    ///      one — that is intentional, since removing it is {prune}'s (separately callable, separately paid for) job
    ///      and coupling the two would let a transfer's gas cost grow without bound.
    /// @param tokenIds V4 position ids. Reverts on the first one that does not exist.
    function index(uint256[] calldata tokenIds) external {
        uint256 n = tokenIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 tokenId = tokenIds[i];
            address holder = _ownerOf(tokenId);
            if (holder == address(0)) revert NonexistentPosition(tokenId);
            if (_slotOf[holder][tokenId] != 0) continue;
            _tokenIds[holder].push(tokenId);
            _slotOf[holder][tokenId] = _tokenIds[holder].length;
            emit Indexed(holder, tokenId);
        }
    }

    /// @notice Drop entries that `holder` no longer owns.
    /// @dev Permissionless because it is not a privilege: the only entries it can remove are ones the chain itself
    ///      says are dead. Reverts on a still-owned entry (`EntryStillValid`) rather than skipping it, so a caller
    ///      who got the list wrong finds out instead of quietly succeeding.
    function prune(address holder, uint256[] calldata tokenIds) external {
        uint256[] storage ids = _tokenIds[holder];
        uint256 n = tokenIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 tokenId = tokenIds[i];
            uint256 slot = _slotOf[holder][tokenId];
            if (slot == 0) revert NotIndexed(holder, tokenId);
            if (_ownerOf(tokenId) == holder) revert EntryStillValid(holder, tokenId);

            uint256 last = ids.length;
            if (slot != last) {
                uint256 moved = ids[last - 1];
                ids[slot - 1] = moved;
                _slotOf[holder][moved] = slot;
            }
            ids.pop();
            delete _slotOf[holder][tokenId];
            emit Pruned(holder, tokenId);
        }
    }

    /// @notice Everything filed for `holder`, stale entries included. Discovery hint only — the consumer is expected
    ///         to re-verify ownership itself, and the adapter does.
    function indexedTokenIds(address holder) external view returns (uint256[] memory) {
        return _tokenIds[holder];
    }

    /// @notice Filed ids whose owner is still `holder`, re-checked now.
    function liveTokenIds(address holder) external view returns (uint256[] memory live) {
        uint256[] memory ids = _tokenIds[holder];
        uint256 n = ids.length;
        uint256[] memory buf = new uint256[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            if (_ownerOf(ids[i]) == holder) buf[k++] = ids[i];
        }
        live = new uint256[](k);
        for (uint256 i; i < k; ++i) {
            live[i] = buf[i];
        }
    }

    /// @notice How many filed ids `holder` still owns. The numerator of
    ///         {UniswapV4SicklePoolsMetaBalanceAdapter.coverage}.
    function liveCount(address holder) external view returns (uint256 count) {
        uint256[] memory ids = _tokenIds[holder];
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            if (_ownerOf(ids[i]) == holder) ++count;
        }
    }

    /// @notice Whether this exact (holder, tokenId) entry is filed. Cheap; does not check ownership.
    function isIndexed(address holder, uint256 tokenId) external view returns (bool) {
        return _slotOf[holder][tokenId] != 0;
    }

    /// @dev `ownerOf` reverts for a burned/unminted id, and a burned id is the common case here (every rebalance
    ///      produces one), so the revert is absorbed and reported as `address(0)`. Fail-open is correct at this
    ///      depth: the call is one SLOAD behind one staticcall, so there is no nested read whose out-of-gas could
    ///      hide inside it. Read through {StaticCallLib} rather than `try`/`catch` for the reason
    ///      `UniswapV3PoolsMetaBalanceAdapter._poolLeaf` documents — a typed call's `extcodesize` check reverts
    ///      OUTSIDE the catch arm, and `catch` does not cover a decode failure either.
    function _ownerOf(uint256 tokenId) private view returns (address) {
        (bool ok, address owner, bool malformed) = StaticCallLib.safeAddrStrict(
            address(POSITION_MANAGER), abi.encodeCall(IV4PositionManager.ownerOf, (tokenId))
        );
        // A dirty word is a broken answer, not an owner: rejected, never masked down to its low 160 bits.
        return (ok && !malformed) ? owner : address(0);
    }
}
