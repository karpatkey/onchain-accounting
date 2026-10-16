// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {StaticCallLib} from "src/utils/StaticCallLib.sol";
import {InvalidArgumentsWithContext} from "src/errors.sol";
import {IFablesHook} from "src/balances/MetaBalanceAdapters/fables/IFablesHook.sol";

/// @title FablesRangeIndex
/// @author KPK
/// @notice Holder → (hook, rangeId) discovery for Fables positions, because chain state cannot answer it.
///
/// @dev **THE PROBLEM, AND WHY IT IS WORSE THAN UNISWAP V4's.** A Fables position is an ERC-6909 balance.
///      V4-core's `ERC6909` is a bare `mapping(address => mapping(uint256 => uint256)) balanceOf` with no
///      enumeration and, unlike ERC-721, no `balanceOf(holder)` COUNT either — there is no number anywhere on
///      chain that says how many ranges a holder has. So this index is required for discovery, and unlike the
///      Uniswap V4 sibling there is no second number to check it against. That is not hidden: see
///      {FablesSickleRangesMetaBalanceAdapter.coverage}, which returns `(live, filed)` and says plainly that
///      no held-total exists.
///
/// @dev **WHY THIS IS SAFE TO LEAVE OPEN.** {index} takes nothing on the caller's word. It reads
///      `hook.balanceOf(holder, rangeId)` and `hook.rangeKey(rangeId).set` and files the entry only if the
///      chain agrees. There is no argument that attributes a position to a holder who does not have the
///      balance, so there is nothing for an owner or an allowlist to protect — hence neither exists, and the
///      operator never becomes a bottleneck. The most a griefer can do is file a holder's own genuine ranges
///      (the desired outcome) or spend gas re-filing what is already there (a no-op).
///
///      Filing an entry that names a HOSTILE hook is possible and is deliberately not defended here: it
///      cannot inflate a NAV, because the adapter re-derives the pool id from the returned PoolKey and refuses
///      any entry whose `key.hooks` is not the hook it just called. Defending it twice would mean an
///      allowlist, and an allowlist is the operator bottleneck this contract exists to avoid.
///
/// @dev **CORRECTION, 24 Sep 2026 (review of PR #46).** "Cannot inflate" was true, but a hostile entry COULD
///      BLIND. A contract that answers this index (so {prune} refuses it) and reverts for the adapter made the
///      adapter's read of that holder fail for every pool, real ranges included, while the coverage read still
///      looked healthy. Reproduced on a live chain-4663 fork: a fixture holder's 4 rows went to 0 after one
///      stranger's entry. Still no allowlist — entries are now ALSO kept per `(holder, hook)`, and the adapter
///      reads only the bucket of the hook a governed pool's own PoolKey names ({indexedRangeIds}). A hostile
///      hook's entries sit in their own bucket, which nothing that values a position ever loads.
///
/// @dev **WHY ENTRIES GO STALE, AND WHY THE HOLDER IS AN ARGUMENT.** A vfat re-centre withdraws a range to
///      zero and deposits a new one, so a filed rangeId is routinely dead. Staleness is the normal state, not
///      an error: {liveRanges} and {liveCount} re-check the balance at read time, the adapter re-checks it
///      again before valuing anything, and {prune} reclaims the storage. `prune` refuses to touch an entry
///      whose balance is still non-zero, so an open pruning function cannot be used to blind the adapter.
///
///      The holder is an explicit argument rather than derived (as an ERC-721 index derives it from
///      `ownerOf`) for the same reason the whole contract exists: a balance has no owner to ask for. It is
///      validated, not trusted.
///
/// @dev **WHAT IS STILL OPEN, STATED RATHER THAN PAPERED OVER.** Two residuals, both recorded against the
///      chain-4663 build and neither closed by the bucketing above:
///        1. Dust. Someone can send a holder dust shares in many REAL ranges on a real governed hook and file
///           them; those land in the governed hook's own bucket. This is the ERC-6909 analogue of NFT dust.
///        2. Unbounded writes (medium finding, 2 Oct 2026, open). {index} has no per-holder or per-bucket cap,
///           so a bucket grows with what is filed into it. SIMULATED on the Uniswap V4 sibling of this index:
///           roughly 330k gas per junk entry against a 10.0M read, so about 100 junk entries push a vault's
///           NAV read past the chain's per-transaction limit. That is a LOUD failure — the meta framework
///           classifies it as {INAVCalculator.InstanceGasExhausted} and reverts rather than returning a short
///           answer — not a wrong number, which is the direction this family chooses every time.
contract FablesRangeIndex {
    /// @notice One filed position: which hook, which range on it.
    struct Entry {
        address hook;
        uint256 rangeId;
    }

    /// @dev holder → filed entries. May contain stale entries; never duplicates.
    mapping(address => Entry[]) private _entries;

    /// @dev holder → keccak256(hook, rangeId) → 1-based position in `_entries[holder]` (0 = not filed).
    mapping(address => mapping(bytes32 => uint256)) private _slotOf;

    /// @dev holder → hook → the rangeIds filed under that hook. The same entries as `_entries`, bucketed so a
    ///      reader can load one hook's ranges without touching anyone else's. See the 24 Sep 2026 correction.
    mapping(address => mapping(address => uint256[])) private _idsByHook;

    /// @dev holder → keccak256(hook, rangeId) → 1-based position in `_idsByHook[holder][hook]`.
    mapping(address => mapping(bytes32 => uint256)) private _hookSlotOf;

    event Indexed(address indexed holder, address indexed hook, uint256 indexed rangeId);
    event Pruned(address indexed holder, address indexed hook, uint256 indexed rangeId);

    /// @notice `holder` has no shares in this range, so there is nothing to file.
    error NoBalance(address holder, address hook, uint256 rangeId);
    /// @notice The hook has no preimage for this id: it was never deposited into.
    error UnknownRange(address hook, uint256 rangeId);
    /// @notice Nothing filed for this (holder, hook, rangeId) triple.
    error NotIndexed(address holder, address hook, uint256 rangeId);
    /// @notice The entry still carries a balance; pruning live data is not a thing this contract does.
    error EntryStillValid(address holder, address hook, uint256 rangeId);

    /// @notice File each entry under `holder`, after the chain confirms the balance exists.
    /// @dev Idempotent: an entry already filed for that holder is skipped, never duplicated. Reverts on the
    ///      first entry the chain does not confirm, rather than skipping it, so a caller who got the list
    ///      wrong finds out instead of quietly succeeding and leaving a hole in the NAV.
    ///
    ///      Both reads here are TYPED calls, deliberately unlike {_balanceOf} below: this is a write path with
    ///      a human behind it, where a hook that will not answer must be an error the caller sees, not an
    ///      entry silently dropped.
    /// @param holder The address holding the shares — for a deployed portfolio, the Sickle, not the Safe.
    /// @param entries The (hook, rangeId) pairs to file.
    function index(address holder, Entry[] calldata entries) external {
        if (holder == address(0)) revert InvalidArgumentsWithContext("holder: zero address");
        uint256 n = entries.length;
        for (uint256 i; i < n; ++i) {
            address hook = entries[i].hook;
            uint256 id = entries[i].rangeId;
            if (hook == address(0)) revert InvalidArgumentsWithContext("hook: zero address");

            bytes32 slotKey = _key(hook, id);
            if (_slotOf[holder][slotKey] != 0) continue;

            (,,, bool set) = IFablesHook(hook).rangeKey(id);
            if (!set) revert UnknownRange(hook, id);
            if (IFablesHook(hook).balanceOf(holder, id) == 0) revert NoBalance(holder, hook, id);

            _entries[holder].push(Entry({hook: hook, rangeId: id}));
            _slotOf[holder][slotKey] = _entries[holder].length;
            _idsByHook[holder][hook].push(id);
            _hookSlotOf[holder][slotKey] = _idsByHook[holder][hook].length;
            emit Indexed(holder, hook, id);
        }
    }

    /// @notice Drop entries whose balance has gone to zero.
    /// @dev Permissionless because it is not a privilege: the only entries it can remove are ones the chain
    ///      itself says are empty. Reverts {EntryStillValid} on a non-zero balance rather than skipping, so an
    ///      open pruning function can never be the way someone blinds the adapter.
    function prune(address holder, Entry[] calldata entries) external {
        Entry[] storage filed = _entries[holder];
        uint256 n = entries.length;
        for (uint256 i; i < n; ++i) {
            address hook = entries[i].hook;
            uint256 id = entries[i].rangeId;
            bytes32 slotKey = _key(hook, id);

            uint256 slot = _slotOf[holder][slotKey];
            if (slot == 0) revert NotIndexed(holder, hook, id);
            if (_balanceOf(hook, holder, id) != 0) revert EntryStillValid(holder, hook, id);

            uint256 last = filed.length;
            if (slot != last) {
                Entry memory moved = filed[last - 1];
                filed[slot - 1] = moved;
                _slotOf[holder][_key(moved.hook, moved.rangeId)] = slot;
            }
            filed.pop();
            delete _slotOf[holder][slotKey];
            _dropFromBucket(holder, hook, slotKey);
            emit Pruned(holder, hook, id);
        }
    }

    /// @dev Swap-and-pop the entry out of its per-hook bucket, mirroring what {prune} does to `_entries`.
    ///      A function of its own so the two swap-and-pops read side by side rather than as one long body.
    function _dropFromBucket(address holder, address hook, bytes32 slotKey) private {
        uint256[] storage bucket = _idsByHook[holder][hook];
        uint256 slot = _hookSlotOf[holder][slotKey];
        uint256 last = bucket.length;
        if (slot != last) {
            uint256 movedId = bucket[last - 1];
            bucket[slot - 1] = movedId;
            _hookSlotOf[holder][_key(hook, movedId)] = slot;
        }
        bucket.pop();
        delete _hookSlotOf[holder][slotKey];
    }

    /// @notice Everything filed for `holder`, stale entries included. Discovery hint only — the consumer is
    ///         expected to re-verify the balance itself.
    function indexedRanges(address holder) external view returns (Entry[] memory) {
        return _entries[holder];
    }

    /// @notice The rangeIds filed for `holder` under `hook` alone, stale ones included.
    /// @dev What {FablesSickleRangesMetaBalanceAdapter} values from, with `hook` taken from a governed pool's
    ///      own PoolKey. Loads nothing filed under any other address, so entries a stranger files under a
    ///      hostile contract cannot make that read revert or grow. This is the 24 Sep 2026 fix.
    function indexedRangeIds(address holder, address hook) external view returns (uint256[] memory) {
        return _idsByHook[holder][hook];
    }

    /// @notice Filed entries that still carry a balance, re-checked now.
    function liveRanges(address holder) external view returns (Entry[] memory live) {
        Entry[] memory filed = _entries[holder];
        uint256 n = filed.length;
        Entry[] memory buf = new Entry[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            if (_balanceOf(filed[i].hook, holder, filed[i].rangeId) != 0) buf[k++] = filed[i];
        }
        live = new Entry[](k);
        for (uint256 i; i < k; ++i) {
            live[i] = buf[i];
        }
    }

    /// @notice How many filed entries still carry a balance.
    function liveCount(address holder) external view returns (uint256 count) {
        Entry[] memory filed = _entries[holder];
        uint256 n = filed.length;
        for (uint256 i; i < n; ++i) {
            if (_balanceOf(filed[i].hook, holder, filed[i].rangeId) != 0) ++count;
        }
    }

    /// @notice How many entries are filed for `holder`, live or stale.
    function indexedCount(address holder) external view returns (uint256) {
        return _entries[holder].length;
    }

    /// @notice Whether this exact (holder, hook, rangeId) entry is filed. Cheap; does not check the balance.
    function isIndexed(address holder, address hook, uint256 rangeId) external view returns (bool) {
        return _slotOf[holder][_key(hook, rangeId)] != 0;
    }

    function _key(address hook, uint256 rangeId) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(hook, rangeId));
    }

    /// @dev A hostile or non-conforming hook must not be able to revert a read that spans many entries, so a
    ///      failed `balanceOf` reads as ZERO: the entry is treated as empty, which makes it prunable and keeps
    ///      it out of {liveRanges}. Fail-open is correct at this depth — one SLOAD behind one bounded
    ///      staticcall, so there is no nested read whose out-of-gas could hide inside it. {StaticCallLib}
    ///      rather than `try`/`catch` for the usual two reasons: a typed call to a CODE-LESS address reverts
    ///      before the `catch` arm can see it, and `catch` does not cover a decode failure either.
    function _balanceOf(address hook, address holder, uint256 rangeId) private view returns (uint256) {
        (, uint256 balance) = StaticCallLib.safeUint(hook, abi.encodeCall(IFablesHook.balanceOf, (holder, rangeId)));
        return balance;
    }
}
