# I-01 — submitForBatch is all-or-nothing and re-validates already-cached coordinates
Location: AssistedCoordCache.sol:124-131, 315-320.
`_addEntry` calls `_validateCoord` before the idempotent early-return, so a coordinate claimed or transferred between planning and sending, or one account in the chunk that is at its keeper limit, reverts the whole multi-account chunk. That matters for the time-critical seeding around the swap (S10/S11). This is documented ("keep chunks small, re-run right before sending").
Suggestion: chunk per account in seed_assisted.py, or use a best-effort batch variant that skips and emits on a per-item failure.
