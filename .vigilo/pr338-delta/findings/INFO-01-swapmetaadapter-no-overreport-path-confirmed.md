# INFO-01: `SwapMetaAdapter.plan()`/`run()` — no reachable over-report (double-count) path found

## Summary
After tracing every ordering, skip, and array-trim path in `script/manage/SwapMetaAdapter.s.sol` (`plan()`, `run()`,
`_assertSameProtocol`, and the `mstore(batch,k)` trim), **no sequence was found that leaves a token reported by two
adapters at any point a reader can observe.** This is a confirmation finding, not a vulnerability — recorded per the
audit brief's requirement to explicitly state a clean result.

## Analysis

### `plan()` (production path — atomic Safe MultiSend)
- File: `script/manage/SwapMetaAdapter.s.sol:352-460`
- Per adapter it pushes, ADJACENT: `removeMetaInstances(old,set)` (skipped when `set.length==0`), then
  `removeBalanceAdapters([old])`, then `addMetaBalanceAdapter(newA,set)` (`SwapMetaAdapter.s.sol:414-422`).
- Because these three (or two) calls land inside **one Safe MultiSend transaction**, no external caller — including
  another view call inside the same transaction — can observe the intermediate state in which `old` is deregistered
  but `newA` is not yet registered, or vice versa. The whole batch is all-or-nothing at the EVM transaction boundary.
  There is therefore no window in which a token could be read as reported by two adapters, nor by neither, from
  outside the transaction.
- The trailing `assembly { mstore(batch, k) }` (`SwapMetaAdapter.s.sol:432-434`) only ever shrinks the pre-allocated
  `names.length*3`-element array down to the `k` slots actually written (`k` is only ever incremented, by at most 3
  per loop iteration, immediately before/at each push) — it cannot alias into or expose uninitialized elements, and
  it cannot reorder anything: iteration order over `names` is preserved 1:1 into `batch`, and `SafeTxBuilder`'s
  `writeSafeTx`/`encodeMultiSend` iterate `transactions` in array order without any reordering
  (`script/utils/SafeTxBuilder.sol:60-75`, `149-156`).
- Skip conditions (`newA==0`, `old==0`, `old==newA`, `!isAdapterRegistered(old)`) only ever cause a *pair* to be
  omitted entirely from the batch — they cannot cause a partial (2-of-3) emission for a pair that IS processed,
  because the fail-closed integrity checks (`_isMetaAdapter(old)`, code-length, `supportsInterface`, NAV pin) all
  `revert` the whole script rather than skip, once a pair has passed the skip gate
  (`SwapMetaAdapter.s.sol:399-406`).
- A stale/partially-stale `set` (read once at plan-time from `getMetaInstances(old)`, frozen into the batch) can
  only cause the on-chain execution to **revert whole** (`MetaInstanceNotFound`/`DuplicateMetaInstance`, per the
  docstring at `SwapMetaAdapter.s.sol:350-351`) or to **drop** a newly-added instance that isn't in the frozen set
  (under-report, the licensed direction) — never to register it twice.

### `run()` (EOA fallback — sequential broadcast, not atomic)
- File: `SwapMetaAdapter.s.sol:198-266`
- Same remove-then-add ordering, but as separate broadcast transactions, so there IS an inter-transaction window —
  explicitly documented (`SwapMetaAdapter.s.sol:335-339`) as a transient **under-report** window (nobody reports the
  token between the remove and the add), never an over-report window, because remove is always first.
- `verify()` (`SwapMetaAdapter.s.sol:288-333`) is a separate, non-broadcasting invocation that reads only live
  post-execution state and explicitly reverts `BothRegistered` first, ahead of every other check
  (`SwapMetaAdapter.s.sol:305-306`) — "the over-report state first: it is the one that is silent on every other
  surface."

## Conclusion
No over-report / double-count path was found in this file. See INFO-02/LOW-01/LOW-02 for adjacent, narrower gaps
found while tracing this script and its NAVRegistryLib dependencies — none of them produce a double-count either,
but they are worth closing for defense in depth / documentation accuracy.

## Recommended Mitigation
None required for this finding; recorded as a clean result.
