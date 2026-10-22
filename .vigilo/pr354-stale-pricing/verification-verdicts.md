# Verification verdicts — PR #354

| ID | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| M-01 | Old NavBaseUsdLib feed x new library x sequencerDown => stale base reported fresh | CONFIRMED, Medium | POC_VALIDATED: `forge test --match-path test/vigilo-poc/PR354_OldFeedSequencerDown.t.sol -vv` → 2 passed (control + exploit; old-feed healthyFeedCount 1 vs new-feed 0; old-feed asset missing from NAV.stalePriceAssets and healthCheck) |
| L-01 | Cap bypassed by heartbeat >= 7d | CONFIRMED, Low | STATIC: addFeed checks only heartbeat==0; the fresh branch skips the cap |
| I-01 | answer=0 vs getLatestPrice price | CONFIRMED, Info | STATIC |
| I-02 | Holdover over-report | Design, Info | ADR 0029 |
| I-03 | Unpriceable quote revert | Design, Info | existing test_quoteAssetUnpriceable_revertsOnEveryEntrypoint |

## Rejected hypotheses
- R-1 Stale reported fresh in the NEW library: in _selectFeedCore, `fresh` requires !internalStale && age < heartbeat, and healthyFeedCount counts only fresh feeds. A fresh feed always outranks a stale one (`_outranks` returns `fresh` on tier mismatch), so `stale == !best.fresh` and a stale winner implies healthyFeedCount == 0 (also fuzzed by testFuzz_staleImpliesNoHealthyFeed). New NavBaseUsdLib keys on healthyFeedCount, so it is correct under sequencerDown (test_sequencerDown_withStaleFeed_isStale).
- R-2 Custom feed bypasses the 7-day cap with a fresh-looking timestamp: every changed feed reports updatedAt from the stale input (base updatedAt; TwoFeed min(rate, base); Inverted leg updatedAt). A missing timestamp makes the feed rate-only, and stale rate-only feeds are unusable. ETHPlus still zeroes on stale. No in-scope feed reports `stale = true` with a self-fresh timestamp.
- R-3 Existing (unchanged) feeds that use `stale=true, price>0` to mean "invalid": all 40 protocol feeds inherit the 4 changed bases or zero explicitly (ETHPlus basket-not-SOUND, Inverted decimals/band). None found.
- R-4 Unit mismatch (USD labelled quote): `_getQuoteAssetInfo` reverts on price <= 0. calculateValue / computeNav / computeAccountPositions / computeNavAndPositions all route through it, and the USD branch of `_priceConversion` is now reachable only for address(0). Quote and derived-feed base use the same `_selectFeedCore` in the same block, so ADR 0019's base cancellation still holds during a stale holdover.
- R-5 New feeds x OLD library: the old selector skips internalStale Custom feeds (primary and monitor). Old NAV returns price 0 for a stale base, so new NavBaseUsdLib zeroes; under sequencerDown with a fresh base, healthyFeedCount > 0 keeps it fresh. PriceFeedData already had healthyFeedCount, so the ABI is unchanged. Safe.
- R-6 Old feeds x new library WITHOUT sequencerDown: pd.stale is true, so the old lib zeroes and the feed is unusable (test_oldShapeFeed_zeroStale_isUnusable). Safe. Only the sequencerDown case breaks (M-01).
- R-7 Divergence on a stale primary: `_monitorDivergence(…, suppressed=sequencerDown)` with primaryPrice8 > 0. Monitors still require freshness. monitorsUnhealthy now also fires for a stale-priced primary with dead monitors (tested). No false suppression.
- R-8 Mutability / storage / EIP-170: no new state, setters or roles. Prices.sol diff is comments only. NAVCalculator is 22,707 B and PriceFeedLib 23,481 B (both < 24,576). irregularForSelected public: it takes storage-ref params, so it is only meaningful via DELEGATECALL, and a direct CALL reads the library's own empty storage (harmless view).
- R-9 Flash-loan / manipulation of the stale fallback: the stale price is the last pushed oracle answer, and the tier order is fixed. Rate-only (spot-readable) custom feeds can no longer be the stale fallback at all. Out of attacker control.
