# 0026 — Adapters may report positions held by an account's vfat Sickle, admitted by a two-way check

- Status: proposed

## Context

Every balance adapter in this repo so far answers one question: *what does `account` itself hold?* That
assumption is wired into the family — `MetaBalanceAdapter._positionsForInstances` passes the queried
`account` straight through to `_instancePositions`, and `NAVCalculator` is strictly account-scoped
(`getAccountNav(account, quote)`; there is no sub-account aggregation anywhere in its surface).

KPK's three index vaults on Robinhood Chain (chain id 4663) break that assumption. They route
concentrated liquidity through [vfat](https://vfat.io), whose deposit path moves the portfolio's tokens
out of the Avatar Safe into that Safe's **Sickle** — a per-owner proxy the vfat `SickleFactory` deploys —
and the Sickle is what ends up owning the LP position. An adapter that only inspected `account` reports
**zero** for a fully deployed portfolio, and the NAV *fails open*: `PriceFeedLib._getAdapterPositions`
reads an adapter revert as "nothing to report" and an unregistered leg is dropped silently, so the
failure mode is a confidently wrong number, not an error.

MEASURED (chain 4663, block 90,186,157, 16 Oct 2026): the kRHUSD Avatar Safe
`0x01F18eadd996e41235A9155Ec9aF5878c6ED6294` holds its entire working book through Sickle
`0x6f94B45B68d9d446706436eB9D55E3a600a723Ba`; `SickleFactory.sickles(avatar)` returns that Sickle and
`Sickle.owner()` returns that Avatar.

The nearest precedent in this repo is `GearboxV3CreditAccountsMetaBalanceAdapter`, which values positions
held by a separate factory-created contract. It does **not** resolve that contract from the account: the
Credit Account is the governed instance coordinate, curated by `MANAGER`, and the adapter then checks
ownership in the other direction (`creditAccountInfo(ca).borrower == account`, else empty). That shape was
considered here and rejected — see below.

## Decision

Introduce `SickleHeldPositions` (`src/balances/MetaBalanceAdapters/vfat/`), an abstract mixin over
`MetaBalanceAdapter`. A Sickle-aware adapter implements `_holderPositions(holder, instance, assetFilter)`
instead of `_instancePositions`; the mixin calls it once for the account and once for the account's
admitted Sickle, and concatenates.

**An address is admitted as a second holder only when both immutable vfat contracts agree, in both
directions:**

    SICKLE_FACTORY.sickles(account) == sickle   AND   ISickle(sickle).owner() == account

The forward map alone would make the factory a single point of authority over what an account appears to
own. The reverse attestation alone would admit any contract that returns the right address. Together they
have no third-party-reachable satisfying assignment for an account that does not own that Sickle:
deploying a Sickle, transferring an NFT into someone else's Sickle, or calling anything on either contract
moves neither read.

Both reads are bounded `StaticCallLib` probes and **fail open to "no second holder"** — no Sickle, a
factory that does not answer, a mismatched owner, and an address with no code all resolve to
`address(0)`. The direction of that failure is the family's: an unresolvable Sickle **under-reports**. The
alternative is not "report an error", it is "price the whole fund at zero", because of the fail-open
behaviour described above.

**Isolation stays the base's.** Both holder reads happen inside one `_instancePositions` frame, so the
per-instance `try`/`catch` and the `GasStipendLib` exhaustion classification apply to the pair exactly as
they do for every single-holder adapter. The fan-out is not widened and no shared code changes shape; the
only edit to an existing contract is one `virtual` keyword on
`UniswapV3PoolsMetaBalanceAdapter._instancePositions`, so the Sickle variant reuses that valuation rather
than copying it.

### Why not the Gearbox shape (Sickle as a governed instance)

It would need no new pattern, but it costs a `MANAGER` transaction per vault and per re-deployment, and it
puts the instance set — the thing the NAV reads on every single call — in the path of an operational event
that happens without warning. It also does not fit the coordinate: the governed instance here is the
**pool**, shared across vaults, while the Sickle is per-account. Encoding `(pool, holder)` pairs would
multiply the governed set by the number of funds and make every new fund a NAV governance action before
its first deposit could be priced.

## Consequences

**Positive**

- A portfolio whose positions sit behind a vfat Sickle is priced correctly, with no NAV configuration per
  fund and no privileged key in the read path.
- The admission rule is a two-line check a reviewer can evaluate in isolation, and it is testable without
  a fork (both contracts are mockable).
- The mixin is protocol-agnostic. Three adapters use it today (Uniswap V3, Uniswap V4, Fables); a fourth
  venue is a subclass, not a new pattern.

**Negative**

- This is the first place in the repo where `getAccountNav(A)` can include value an address other than `A`
  holds. That is a real widening of what an adapter is allowed to say, and it rests on the correctness of
  two vfat reads. If vfat ever ships a factory whose `sickles` mapping is writable by its owner, the
  forward half of the check degrades to "the factory says so" and only the `owner()` attestation remains.
- Two extra staticcalls per instance. A `view` adapter has nowhere to cache the resolution, so it repeats
  for every instance in the governed set; both calls hit the same two addresses, so only the first pays
  cold-account pricing.
- Per-(holder, instance) isolation, which the original chain-4663 build had, is deliberately **not**
  carried over: a reverting instance now costs that instance's legs for both holders rather than for one.
  The narrower boundary is the one every other adapter in this repo lives with, and the case it protected
  against (a hostile pool reverting only for the Sickle) is defended at its source in the Fables adapter
  instead.
