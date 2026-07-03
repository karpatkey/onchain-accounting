# Stader withdrawal-queue griefing & NAV-read gas — operator's note

The `StaderWithdrawalQueueBalanceAdapter` (`src/balances/BalanceAdapters/StaderWithdrawalQueueBalanceAdapter.sol`) is a **plain** balance adapter (not assisted): it enumerates an account's open Stader unstake requests **on-chain** via `getRequestIdsByUser(account)` and values each. There is **no adapter-level cap** on how many requests it reads — the only bound is Stader's own `maxNonRedeemedUserRequestCount` (1000 on mainnet). This note documents the residual griefing/gas surface that the absence of a cap leaves, and why it is acceptable.

## The griefing vector

Stader's `requestWithdraw(ethXAmount, _owner)` pulls the **caller's** ETHx but records the request under an **arbitrary** `_owner` (claimable only by `_owner`). So anyone can plant withdrawal requests owned by one of our accounts by burning their own ETHx.

Key properties:

- **The injected value is real, claimable, and self-funded.** The griefer donates their ETHx; the resulting ETH is claimable **only by the victim account**, never recoverable by the griefer. Economically it is an airdrop (which the plain wallet ERC20 adapter would also report).
- **It is cheap to do, but pointless.** The per-request minimum is small (`minWithdrawAmount` ≈ 0.0001 ETH on mainnet), so filling an account toward the 1000 ceiling costs the griefer only ~0.1 ETH of donated ETHx plus gas for ~1000 `requestWithdraw` txs. There is **no profit** — the griefer permanently loses the donated ETH and the victim can claim it.

## The residual: NAV-read gas

The adapter loops every live request (one external `userWithdrawRequests` read + one `previewWithdraw` per request). Measured on mainnet against the deployed adapter:

| requests | `getAdapterBalances` | `getAdapterPositions` |
|---|---|---|
| per-request marginal | ~17k gas | ~20k gas |
| 1000 (protocol ceiling) | ~17M gas | ~20.5M gas |

So a maximally-griefed account (≈1000 requests) makes **its own** NAV read cost ~20M gas. Standalone that is under Geth's default 50M `eth_call` cap and under a 30M block limit, but as one leg of an aggregate on-chain `getAccountNav` — which also iterates every other balance adapter and prices every position — a ~20M Stader leg can push the whole call over a constrained gas budget and **OOG**.

## Why no cap — the failure is liveness-only and safe

We deliberately do **not** skip/zero the account above any threshold. Two reasons:

1. **Skipping would silently zero a real, claimable balance.** Reporting 0 for a griefed account is an under-report of value the account genuinely owns. Reading the full list is always the honest, over-report-safe answer.
2. **A reverting NAV read does not harm the consumer.** NAV reads are async/off-chain (ADR 0017). If a griefed account's `getAccountNav` OOGs, the consumer (the kpk-shares layer) **does not process that account's subscription/redemption** — it acts on a *successful* read or not at all. There is no path where an OOG causes a mis-valuation, an over-report, or any effect on **other** accounts. The blast radius is: that one account cannot sub/redeem until its queue shrinks.

The account restores its own read simply by **claiming / pruning** its finalized requests (Stader swap-and-pops each claimed id out of `getRequestIdsByUser`), which brings the request count — and the read cost — back down.

## Operator actions

- **Monitoring.** Alert if any tracked account's `getRequestIdsByUser(account).length` grows abnormally (e.g. > ~50), which is the signature of griefing (a real user rarely holds more than a handful of open requests).
- **Remediation.** Have the account **claim** its finalized requests to prune the array; the claimed ETH is the account's to keep (the griefer funded it). No contract change or redeploy is needed — the adapter is immutable and correct regardless of list size.
- **Do not** treat a griefed account's transiently-reverting NAV read as a valuation error; it is the designed fail-safe. Re-read after pruning.

## Sibling withdrawal-queue adapters (same no-cap stance)

The same reasoning applies to the other queue adapters; the decisive factor is NAVCalculator's **fail-open** per-adapter try/catch (`PriceFeedLib._getAdapterPositions`): a reverting or capped adapter is caught and contributes an empty set, so NAV *succeeds with a silent under-report* rather than failing. A cap therefore buys no safety — it only converts would-be-honest reads into deterministic zeros/truncations. So none of these cap:

- **`LidoWithdrawalQueueBalanceAdapter`** — like Stader, third-party griefable (Lido's `requestWithdrawals(amounts, _owner)` takes an arbitrary owner, and withdrawal NFTs are transferable ERC721), and **unbounded** (no protocol per-account ceiling). An O(1) `balanceOf` still short-circuits the common zero case. Worst case is a bigger version of Stader's: a cheap, unbounded, hard-to-remediate per-account NAV-read cost — but still liveness-only and safe.
- **`KelpWithdrawalQueueBalanceAdapter`** — **not** third-party griefable: Kelp records requests under the unstaking `msg.sender` (no arbitrary-owner param), so a large per-(asset,account) count is purely self-inflicted. Its old cap did silent *truncation* (read first N, drop the rest) — the worst failure mode — now removed.

## Related

- Contract NatSpec on `StaderWithdrawalQueueBalanceAdapter` (the "On-chain enumeration vs. third-party injection — no adapter-level cap" block).
- [ADR 0017](../decisions/0017-lp-valuation-instantaneous-amounts.md) — establishes that NAV is a read-only `eth_call` oracle with **no atomic on-chain consumer** (async / off-chain settled share layer), so a reverting read is a non-event for that account, not a DoS of the system.
- The M-1 live-rate cap on *pending* requests (`_cappedPending`) is a separate, unrelated safety measure (guards a stale request-time estimate against a rate drop); it is retained.
