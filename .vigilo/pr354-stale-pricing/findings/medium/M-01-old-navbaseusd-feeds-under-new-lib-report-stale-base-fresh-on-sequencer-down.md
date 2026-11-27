# M-01 — Old (origin/main) NavBaseUsdLib feeds under the new PriceFeedLib report a stale-base asset FRESH while the L2 sequencer is down/in grace

- Auditor lens: oracle / compatibility (rollout order "NAV library first, feeds later", or any NAV-sourced feed left un-swapped)
- Evidence: POC_VALIDATED — test/vigilo-poc/PR354_OldFeedSequencerDown.t.sol (2/2 pass)
- Location: deployed feeds' compiled-in `NavBaseUsdLib.baseUsd` at origin/main src/prices/NavBaseUsdLib.sol:44 (`bool baseStale = pd.stale && !pd.sequencerDown;`), interacting with new src/prices/PriceFeedLib.sol:180 (a stale winner now returns its positive price) and :539 (`pd.stale = stale || sequencerDown`).

## Root cause
The old library's sequencer "un-fold" (`pd.stale && !pd.sequencerDown`) was only safe because the old selector returned `price == 0` whenever the base was genuinely stale, so the subsequent `pd.price <= 0` check still zeroed. The new selector keeps the stale price. When `sequencerDown` is true the old un-fold clears the flag and the positive stale price passes, so the old feed returns `(price, stale=false)`. The NAV then checks only the custom feed's own heartbeat (86400 s on every L2 custom primary) against `updatedAt = baseUpdatedAt`, which is far shorter than that, so the feed counts as FRESH.

The PR's new NavBaseUsdLib fixes this for new feeds (`baseStale = healthyFeedCount == 0`, with a comment naming exactly this hazard). But the bytecode of every deployed NAV-sourced feed still contains the old logic. ADR 0029's "Old feeds and the new library are compatible in both directions … in any order" is therefore false for this case.

## Scenario
Base (8453) or Arbitrum (42161). After a sequencer outage, the uptime feed is in its 1 h grace window. ETH/USD (heartbeat 1200 s on Base, 1755 s on Arbitrum) or USDC/USD (255 s on Arbitrum) has not yet posted a round. The NAV library is upgraded, but the wstETH_L2, weETH_L2, cbETH_L2, rsETH_L2, ezETH_L2 and syrupUSDC_L2 feeds are still the old deployments. Result:
- `getPriceData(wstETH).healthyFeedCount == 1`.
- `NAV.stalePriceAssets` and `healthCheck().stalePriceAssets` omit wstETH, while WETH itself is listed.
- The derived asset is valued off the stale base with no per-asset flag. The only signal left is the top-level `nav.sequencerDown` (`latestPrice` still reports stale because it folds sequencerDown in).

Before this PR (old lib + old feed) the same asset was flagged stale and valued at 0. After the feeds are swapped it is flagged stale and keeps its price. Only the mixed window is wrong.

## Impact
A stale input is reported fresh at the per-asset level, which is priority concern 1. It is bounded: it needs an L2, sequencer down or in grace, a genuinely stale base, and an old feed still registered. The top-level sequencerDown flag stays true, and the value matches the intended post-ADR value. That is why this is Medium and not High.

## Recommendation
- Roll out feeds first, then the NAV library. New feeds under the old library are safe: the old library skips `internalStale`, and old NAV returns price 0 for a stale base. Alternatively, do the feed swaps and the NAV upgrade in one atomic Safe batch per L2.
- Do not leave any NavBaseUsdLib-consuming feed from origin/main registered on 8453/42161 after the upgrade. Add a preflight check, e.g. compare the runtime code hash of every registered Custom feed against the new build.
- Correct the ADR 0029 "compatible in both directions" sentence to state the order constraint on L2s.
- Add the PoC (or an equivalent test) to the suite.
