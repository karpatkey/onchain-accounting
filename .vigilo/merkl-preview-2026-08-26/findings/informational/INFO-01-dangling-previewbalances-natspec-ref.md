# [INFO-01] NatSpec references a non-existent `previewBalances` function

- Severity: Informational (QA)
- Evidence: STATIC_CONFIRMED (grep — symbol does not exist)
- Direction: N/A (documentation only; no runtime effect)
- File: src/balances/AttestedBalanceAdapters/MerklRewardsAttestedBalanceAdapter.sol:275, 808, 921, 932

## Summary
Four NatSpec cross-references write `{previewPositions}/{previewBalances}`, but no
`previewBalances` function exists in the contract or in `IAttestedBalanceAdapter`.
The only cache-free preview entrypoint is `previewPositions(address,bytes)`.

## Detail
`{...}` NatSpec references are meant to resolve to a real symbol. `previewBalances`
resolves to nothing:
- L275 `DuplicateToken` error doc
- L808 `_submitProof` comment
- L921 `_unclaimedFrom` doc
- L932 `_checkProofAndCampaigns` doc

Likely a leftover from an earlier design that exposed both a positions and a balances
preview; the balances variant was collapsed into the single opaque-`bytes`
`previewPositions` (commit f60fa648). The repo's doc-accuracy rule (grep every named
fn against current code before committing docs) makes this worth fixing.

## Recommendation
Drop `/{previewBalances}` from all four references, leaving `{previewPositions}`.
