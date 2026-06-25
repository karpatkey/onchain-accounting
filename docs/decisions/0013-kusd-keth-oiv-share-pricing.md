# ADR 0013 — kUSD / kETH (OIV share) pricing via a cross-rate custom feed

**Status:** Deferred / on hold
**Date:** 2026-06-23 (deferred 2026-06-25; not implemented in the 2026-06-26 deployment)

> **⚠ Deferred — not implemented.** kUSD / kETH pricing is **out of the 2026-06-26 deployment**; those holdings (~$1.87M, KPK DAO) are an accepted uncovered position pending this decision. The probable direction is to deploy a **Chainlink oracle on mainnet that reads the funds' NAV across all chains**, and price kUSD/kETH from that single cross-chain NAV source — rather than this repo building the `getLastSettledPrice` cross-rate custom feed described below. If that lands, kUSD/kETH would register against the Chainlink feed like any other Chainlink-priced asset, and this ADR's custom-feed design is **not** implemented. This document is retained for the on-chain analysis of the `kpkShares` settled-price source (still accurate) and as the fallback design if the cross-chain NAV oracle does not materialize. **Do not implement the feed below until the Chainlink-NAV-oracle decision is settled.**

---

## Context

KPK DAO holds **kUSD** and **kETH** (~$1.87M combined) — shares of the OIV "Alpha Fund" vehicles (`onchain-investment-vehicles`), not assets this repo produces. NAV must value these holdings.

Verified on-chain + against the `kpkShares` source (2026-06-23):

| Token | Address | Name | Decimals | ERC-4626? |
|---|---|---|--:|:--:|
| kUSD | `0x6d1a4c0878ad24793b1655ae1f78cfa4522ba765` | kpk USD Alpha Fund | 18 | **No** (`asset()` absent) |
| kETH | `0xed01a1fe4e020ca901f43e17b6203a7e0cea818c` | kpk ETH Alpha Fund | 18 | **No** |

Pricing source on the share contract:

```solidity
function getLastSettledPrice(address asset) external view returns (uint256); // 8-dec normalized
```

Key facts (verified):
- The returned value is the **price per share denominated in the subscription `asset`** (the settle input is literally `sharesPriceInAsset`), normalized to 8 decimals — **not** a direct USD price, despite a misleading "normalized USD units" comment in the source (flag to the OIV team; it is correct only when the asset is a USD stablecoin).
  - kUSD: `getLastSettledPrice(USDC)` = `100000000` → **1.0 USDC/share**.
  - kETH: `getLastSettledPrice(WETH)` = `100170332` → **1.0017 WETH/share** (≈ 1 ETH/share, *not* $1).
- The price is **per subscription asset**: `_lastSettledPrice[asset]`. Approved assets per fund are independent of whether they've been settled:
  - kUSD `getApprovedAssets()` = **[USDC, USDT]**, but only **USDC** has a settled price (USDT = `0`, approved-but-never-settled).
  - kETH settles against **WETH** (USDC returns `0`).
- The price is **operator-settled** via `settle(...)` (`isOperator`), guarded by `_validatePriceDeviation` with `MAX_PRICE_DEVIATION_BPS = 3000` (**30%** max deviation from the last settled price per settle).
- **There is no `settledAt` timestamp** stored with `_lastSettledPrice` (the only timestamps in the contract are for fees + subscription-request TTLs). So there is no on-chain freshness signal for the price.

This is a cross-layer read: a feed in this repo would read the OIV `kpkShares` deployment (a separate system).

---

## Decision

Price kUSD/kETH with a **custom `IPriceFeedCustom` cross-rate feed** (one per share token), not a balance adapter:

```
USD-per-share (8-dec) = getLastSettledPrice(canonicalAsset)  ×  canonicalAsset/USD (Chainlink)  / 1e8
```

- **kUSD** → `getLastSettledPrice(USDC) × USDC/USD`
- **kETH** → `getLastSettledPrice(WETH) × ETH/USD`

The feed **pins the canonical settlement asset** (USDC / WETH) in its constructor — it does **not** iterate `getApprovedAssets()` (USDT for kUSD is approved but unsettled → would return `0` and zero out NAV).

kUSD/kETH stay **registered NAV assets**; `ERC20DefaultAdapter` reports the 18-dec wallet balance; NAV = `balance × feedPrice`. No balance adapter is needed.

---

## Rationale

- **Convention.** "Adapters report balances; NAVCalculator/feeds do the pricing." A per-share USD price is a pricing concern → a feed, alongside `wstETH`, osToken, etc.
- **Balance side is already covered** by `ERC20DefaultAdapter` (any registered ERC-20 wallet token). The only missing piece is a price.
- **The cross-rate is mandatory, not cosmetic.** The settled price is in *asset units* (WETH/share for kETH), so it MUST be multiplied by the asset's USD price. A feed does this natively; a balance adapter would have to embed the same multiplication, duplicating pricing in the balance layer — against convention, and it would still face the identical staleness/trust problem.
- **ETH-denominated NAV.** For kETH, the `× ETH/USD` term cancels in an ETH-denominated NAV, leaving the WETH/share rate — consistent with the stETH/wstETH OIV oracle fix.
- **Canonical-asset pinning** is correct because a share's USD value is the same regardless of which stablecoin it was subscribed with; the per-asset storage only reflects per-asset settlement batches.

---

## Staleness / trust model — DECIDED (2026-06-23): rate-only, no OIV change

`getLastSettledPrice` has **no `settledAt` timestamp**, so the feed's `latestRoundData().updatedAt` has nothing real to return.

**Adding `settledAt` on-chain was considered and rejected:** `kpkShares` is already **audited** and deployed (UUPS) across chains — amending it for a NAV-side convenience would require a re-audit + a governance upgrade per chain. Disproportionate and risky relative to the benefit.

**Decision: treat the settled price as a rate-only source** — the feed returns `updatedAt = 0`. ADR 0009 already defines this path (`updatedAt == 0 → block.timestamp - 1`, participates as "fresh"); it was designed for exactly this case (a live storage rate with no external-oracle timestamp, like DSR / exchange-rate feeds). So this is the sanctioned pattern, not a workaround.

Integrity of the settled-price component rests on what's already on-chain, no new code:
- settlement is **operator-gated** (`settle` is `isOperator`),
- capped at **30% deviation per settle** (`MAX_PRICE_DEVIATION_BPS = 3000`),
- and these are **kpk's own funds**.

The Chainlink cross-rate leg (USDC/USD, ETH/USD) retains its own real staleness gate via its heartbeat, so an oracle freeze on *that* side is still caught.

Residual risk (accepted + documented): a frozen-but-valid-looking settled price, or cumulative drift across many small settles, is not time-gated. Acceptable given own-funds + operator-gating + the deviation cap.

---

## Consequences

- **Immutable feed pins the canonical asset.** If a fund changes its primary settlement asset (e.g., kUSD USDC → USDT) and stops settling the pinned one, the price silently goes stale — and with no `settledAt`, the feed cannot detect it. The feed (immutable) would need redeploy/repoint. Document the operational assumption: *the operator keeps the canonical asset settled.*
- **Cross-layer dependency** on the OIV `kpkShares` deployment. Confirm per-chain addresses before scoping deployments: mainnet is confirmed; kUSD is reportedly live on 5 chains, but KPK DAO's *holdings* (the ~$1.87M) are on mainnet — verify whether feeds are needed on other chains.
- **30% per-settle cap** bounds single-settle manipulation, not cumulative drift across many settles.
- **No new balance-layer code**; one custom feed per share token, registered like any other asset (no `addBalanceAdapter`).
- **Source comment fix:** the "normalized USD units" wording in `kpkShares.getLastSettledPrice` is misleading for non-USD assets (it is asset-denominated) — request a correction from the OIV team.

---

## Status / next steps
1. ~~Settle the staleness/trust decision with the OIV team~~ — **DONE 2026-06-23: rate-only, no OIV/shares-contract change** (the contract is audited; amending it is disproportionate). See the staleness section above.
2. Implement `KpkSharesPriceFeed` (cross-rate, canonical-asset-pinned: kUSD→USDC, kETH→WETH) under `src/prices/protocols/`, with unit + fork tests at a pinned block (assert kUSD ≈ $1, kETH ≈ ETH price). `updatedAt = 0` (rate-only).
3. Register kUSD/kETH as assets pointing at the new feeds; ship in the eventual redeploy / a config PR.
4. (Housekeeping, OIV team's call — not blocking) request a fix to the misleading "normalized USD units" comment on `getLastSettledPrice` (it is asset-denominated).
