# ADR 0029 rollout — ordering rules and pre-upgrade checks

What must hold when the best-available stale pricing ([ADR 0029](../../docs/decisions/0029-staleness-flags-never-changes-value.md))
goes live. This file holds the rules. The full per-chain command sequence and the Safe batches are added when the
rollout is prepared.

## Rule 1 — swap the custom feeds before the implementation upgrade (or in the same batch)

Never upgrade the NAV implementation first on a chain that still has a pre-ADR-0029 NAV-sourced custom feed
registered as a primary.

- **Why:** every deployed custom feed has the old `NavBaseUsdLib` compiled in. It flags a stale base only when
  `pd.stale && !pd.sequencerDown`, which was safe only because the old library priced a stale base at 0. Under the
  new library a stale base keeps its price. So while an L2 sequencer is down, an old feed reports a stale base as
  **fresh**, and the derived asset disappears from `stalePriceAssets`. Proof of concept:
  `test/vigilo-poc/PR354_OldFeedSequencerDown.t.sol`.
- **The safe direction:** a new feed under the old library returns `(0, true)` on a stale base, exactly as today.
  So the feeds can go first, on their own.
- **How:** per chain, either execute the feed swap and confirm it on-chain before the upgrade, or put the feed
  swap and `upgradeToAndCall` in one Safe batch with the swaps first.
- **Before the upgrade, check:** every primary `Custom` feed registered on the chain is one of the newly deployed
  feeds. A primary `Custom` feed still at a retired address blocks the upgrade on that chain.

## Rule 2 — sweep the heartbeats already on-chain

`PriceFeedLib.addFeed` rejects a primary heartbeat at or above `MAX_STALE_PRICE_AGE` (7 days), but only when a
heartbeat is written. A heartbeat already stored at or above 7 days (other than `type(uint256).max`) keeps the old
fresh-to-zero cliff after the upgrade.

- **Before the upgrade, check:** for every registered asset, `getPriceFeeds(asset)` returns no primary with
  `chainlinkHeartbeat >= 604800` other than `type(uint256).max`. The committed config's largest primary heartbeat
  is 90,000 s, so a hit means the chain has drifted from the config.
- A `type(uint256).max` primary is never stale by age, so the 7-day cap does not apply to it. Use it only for a
  feed that reports its own staleness.

## Rule 3 — the library pin and the deployment records

- The `PriceFeedLib` pin in `foundry.toml` and `script/utils/LibraryPins.sol` is the NEW address. The deployment
  records (`script/config/deployments/<chainId>.json`) keep the live address until the new library is
  CREATE2-deployed on that chain; update them then. Nothing checks the records against the pin.
- Re-check the pin (CI `pin-canary` and a clean local build must agree) after any change to the library's
  sources.
