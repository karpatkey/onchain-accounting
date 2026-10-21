# Vigilo audit — PR #354 (ADR 0029, best-available stale pricing)
Branch fix/nav-stale-best-available @ d05cbcf8, scope `git diff origin/main...HEAD -- src/` (see ../SCOPE.md).
Method: recon, then oracle / logic / defi lenses (performed directly by the orchestrator because no sub-agent dispatch is available in this session), then a PoC for the one confirmed issue, then quality review. Cross-chain and flash-loan lenses were skipped as irrelevant (view-only price selection, no balance-dependent logic).

## Summary
| ID | Severity | Title | Evidence |
|---|---|---|---|
| M-01 | Medium | Old NavBaseUsdLib feeds under the new library report a stale-base asset FRESH while the L2 sequencer is down/in grace | POC_VALIDATED |
| L-01 | Low | 7-day cap not enforced on-chain; heartbeat >= 7 d (or max) keeps a price "fresh" at any age | STATIC_CONFIRMED |
| I-01 | Info | Custom feeds: latestRoundData answer 0 when stale vs getLatestPrice price | STATIC |
| I-02 | Info | Holdover can over-report for up to 7 d; only flags signal it (design) | — |
| I-03 | Info | QuoteAssetUnpriceable liveness for non-USD quote consumers (design) | — |

No Critical/High. In the new library itself, no path was found where a stale input is reported fresh, no unit mismatch, and no manipulable or unbounded-age stale price for the changed feed classes. Storage is unchanged, there is no new mutability, and EIP-170 is respected (NAVCalculator 22,707 B, PriceFeedLib 23,481 B).

## M-01 detail
See ../findings/medium/M-01-*.md. Root cause: origin/main NavBaseUsdLib.sol:44 `baseStale = pd.stale && !pd.sequencerDown` is compiled into every deployed NAV-sourced feed. It relied on the old selector zeroing a stale base. The new PriceFeedLib.sol:180 keeps the stale price, so under sequencerDown the old feed returns `(price, false)`. The NAV gates it only by the feed's 86400 s heartbeat, so it is counted fresh. Affected: Base (wstETH_L2, weETH_L2, cbETH_L2) and Arbitrum (wstETH_L2, weETH_L2, rsETH_L2, ezETH_L2, syrupUSDC_L2) until the feeds are swapped. The contradicted claim is ADR 0029 "compatible in both directions … in any order".

PoC: /home/nicol/projects/oa-stale-best-available/test/vigilo-poc/PR354_OldFeedSequencerDown.t.sol
```
forge test --match-path test/vigilo-poc/PR354_OldFeedSequencerDown.t.sol -vv
[PASS] test_control_sequencerUp_oldFeedZeroesAndFlags()
[PASS] test_exploit_oldFeed_newLib_sequencerDown_staleBaseReportedFresh()
  old-feed wstETH healthyFeedCount: 1
  new-feed wstETH healthyFeedCount: 0
```
The exploit test asserts all of the following: the base has healthyFeedCount 0 with its price kept; the old-feed asset has healthyFeedCount 1 and is priced off the stale base; it is absent from NAV.stalePriceAssets and healthCheck; the new-feed control is listed stale; and nav.sequencerDown is true.

Fix: on L2s, swap the feeds before (or atomically with) the NAV-library upgrade, since new feeds under the old library are safe. Add a preflight check that no origin/main NavBaseUsdLib feed remains registered, and amend the ADR.

## Rejected hypotheses
R-1 to R-9 in ../verification-verdicts.md (stale-as-fresh in the new lib, cap bypass via timestamps, legacy feeds signalling invalid with stale=true, quote unit mismatch, new feed x old lib, old feed x new lib on L1, divergence suppression, size/storage, manipulation).
