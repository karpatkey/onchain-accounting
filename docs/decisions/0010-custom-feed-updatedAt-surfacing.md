# 0010 — Surface custom-feed `updatedAt` through `NAVCalculator.getPriceData()`

**Status:** accepted

## Context

`PriceFeedData` is the unified shape `NAVCalculator.getPriceData(asset)` returns to off-chain callers (dashboards, monitoring, downstream contracts). It carries `priceType` (Chainlink/Custom), the registered `chainlinkHeartbeat`, an `updatedAt`, the computed `stale` flag, and the L2 `sequencerDown` flag.

Before this ADR, only Chainlink feeds populated `updatedAt` — the custom branch left it at the zero default. That asymmetry is a problem for two reasons:

1. **Observability gap.** Most custom feeds we ship today (`ETHPlus`, `ETHx`, `kUSD`, ERC-4626 wrappers, …) ultimately depend on an external oracle for at least one leg. Dashboards had no way to see that underlying-oracle freshness without bespoke per-feed integrations.
2. **The Custom branch had no consistent contract.** Adapter authors weren't told what `latestRoundData()` was *for* on a custom feed, so implementations diverged: some returned `(0, 0, 0, 0, 0)`, some echoed `block.timestamp`, some passed through a single underlying Chainlink.

The natspec on `src/prices/IPriceFeedCustom.sol::latestRoundData()` was already strengthened to specify a **worst-case across underlying oracles** convention plus a `(0, 0, 0, 0, 0)` sentinel for feeds with no trackable oracle dependency (live on-chain rates such as ERC-4626 `convertToAssets`-style feeds). That natspec change set the rule; this ADR documents the **NAVCalculator-side wiring** that consumes it, and the dashboard rendering that depends on it.

`Prices.sol`'s staleness gate semantics are explicitly out of scope. Chainlink: heartbeat compare on `latestRoundData().updatedAt`. Custom: trust the `stale` flag from `getLatestPrice()`. This ADR does not touch either path.

## Decision

1. **Adapter authors honor the natspec contract on `IPriceFeedCustom.latestRoundData()`:**
   - Single underlying Chainlink → pass that aggregator's round data through verbatim.
   - Multiple underlying oracles → return the tuple with the **lowest `updatedAt`** (worst case).
   - Indirect oracle exposure (e.g. via a protocol that does its own refresh) → return a meaningful `updatedAt` sourced from that protocol.
   - No trackable oracle dependency (live on-chain rate) → return `(0, 0, 0, 0, 0)`.
2. **`NAVCalculator.getPriceData()` reads `latestRoundData()` on both branches** and populates `PriceFeedData.updatedAt` accordingly. The Custom branch no longer leaves the field at the zero default; the value is whatever the adapter reports per the contract above.
3. **The `chainlinkHeartbeat` field is pinned for Custom feeds too** — registered at `setPriceFeed` time, surfaced through `PriceFeedData` for documentation and external monitoring. It is **not** consulted by `Prices.sol` for the Custom staleness gate; the natspec on `IPrices.PriceFeedConfig` and `INAVCalculator.PriceFeedData` says so explicitly.
4. **The dashboard renders `updatedAt == 0` as "Live"** (`app/src/components/price-feeds-table.tsx`) with a tooltip stating "Live on-chain rate — no external oracle dependency." Non-zero `updatedAt` renders as the standard relative timestamp.

## Consequences

**Positive:**

- One shape (`PriceFeedData`) describes freshness for both feed types. The dashboard, monitoring tools, and downstream contracts no longer special-case Chainlink vs Custom.
- The `0` sentinel cleanly distinguishes "live on-chain rate" from "stale or unknown" in the UI — users see a deliberate "Live" badge rather than a missing timestamp.
- New custom feeds that wrap a single Chainlink aggregator can implement `latestRoundData()` as a one-liner pass-through, and instantly inherit useful freshness telemetry.

**Negative / things to watch:**

- The "0 means live" sentinel is a contract, not a self-evident property of the return value. A buggy custom feed that erroneously returns `(0, 0, 0, 0, 0)` will be displayed as "Live" even though its underlying oracle is broken. Mitigation: PR review of every new custom feed asserts the right branch of the natspec contract is honored, and unit tests cover the chosen branch explicitly.
- `PriceFeedData.updatedAt` correctness depends on every custom feed implementing `latestRoundData()` faithfully. The check is not enforced on-chain — it is enforced at code-review time. A future enhancement could ship a `latestRoundData()`-vs-`getLatestPrice()` consistency probe (e.g. flag a feed whose `stale=true` but `updatedAt` is recent), but that is observability tooling, not protocol logic.
- Pinning `chainlinkHeartbeat` on Custom feeds is documentation-only. The dashboard displays it for parity, but no `Prices.sol` code path uses it. Adapter authors must understand this — the heartbeat **does not** gate Custom feeds, and a Custom feed's actual staleness threshold lives inside its `getLatestPrice()` implementation.

## Reference

- Interface contract: `src/prices/IPriceFeedCustom.sol::latestRoundData()` natspec — the worst-case + sentinel rule.
- Consumer: `src/nav/NAVCalculator.sol::getPriceData()` — calls `latestRoundData()` on the Custom branch.
- Struct natspec: `src/nav/INAVCalculator.sol::PriceFeedData` and `src/prices/IPrices.sol::PriceFeedConfig` — clarified semantics for both `updatedAt` and `chainlinkHeartbeat` on Custom feeds.
- Adapter author's guide: `src/prices/PRICE_ADAPTERS.md` — updated narrative on `latestRoundData()`'s purpose and the unified `PriceFeedData` flow.
- Dashboard rendering: `app/src/components/price-feeds-table.tsx` — "Live" rendering for the `updatedAt == 0` sentinel.
- Tests: `test/nav/NAVCalculator.t.sol::test_getPriceData_customOracle` (worst-case timestamp path) and `::test_getPriceData_customOracle_noTrackableOracle` (sentinel path).
