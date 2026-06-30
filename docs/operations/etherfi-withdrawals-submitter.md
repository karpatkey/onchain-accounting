# ether.fi withdrawals submitter bot — operator's guide

The `EtherFiWithdrawalQueueAssistedBalanceAdapter` (`src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol`) reports a portfolio's in-flight ETH in ether.fi's withdrawal queue by reading an on-chain cache of candidate `WithdrawRequestNFT` `tokenId`s per account. The NFT is **not enumerable**, so an off-chain bot discovers the account's tokenIds and submits them. Crucially, the cache stores **only ids, never amounts** — the adapter values each id entirely from live on-chain reads (`getClaimableAmount` / `getRequest` + `LiquidityPool.amountForShare`) and re-verifies `ownerOf` on every read. The bot cannot fabricate value; at worst it omits an id (NAV under-reports), never over-reports. See [`docs/decisions/0014-agent-fed-cache-adapters-for-exit-queues.md`](../decisions/0014-agent-fed-cache-adapters-for-exit-queues.md) for the trust model (generalises Merkl/ADR 0007).

> **Access control:** this adapter is in the assisted balance-adapter family — submissions are gated by `ASSISTANT_ROLE` (granted/rotated by `DEFAULT_ADMIN_ROLE`); see [ADR 0015](../decisions/0015-assisted-balance-adapter-family.md). Where this guide says "owner"/"owner key" below, read it as the `ASSISTANT_ROLE` holder.

This file is the contract between the on-chain adapter and the ops process that feeds it. The bot lives in `kpk-agents` (`agents/automations/accounting/`), mirroring `submit_merkl_proofs.py`.

---

## Responsibilities

Per cycle, two things:

1. **Discover** each tracked account's open `WithdrawRequestNFT` tokenIds (off-chain).
2. **Submit** the fresh ones to the deployed adapter via `submitTokenIds(account, ids)` (or `submitTokenIdsBatch`), signed by a key holding `ASSISTANT_ROLE`.

Garbage-collection (`clearTokenId` / `clearAccount`) for claimed/transferred ids is an occasional cleanup, not steady-state-critical — each `submitTokenIds` reconciles the account's cached set to exactly the submitted list (new ids are added, cached ids absent from the list are removed), so submitting only the currently-owned ids each cycle already purges stale ones; and even an uncollected stale id reads as 0 (the adapter drops it when `ownerOf != account` or the request is gone). Explicit GC matters only when the bot stops submitting for an account (e.g. its last id was claimed and the bot skips the empty list) or to keep the cache under the `MAX_TOKEN_IDS` (256) cap — neither of which a normal account approaches.

## Discovering tokenIds (the only off-chain step)

ether.fi exposes no owner→tokenIds view. Recover ownership from event logs on the `WithdrawRequestNFT` (mainnet `0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c`):

```
owned(account) = { tokenId : Transfer(_, account, tokenId) } minus { tokenId : Transfer(account, _, tokenId) }
```

i.e. ERC-721 `Transfer` events where `to == account`, minus those where `from == account` (claims burn the NFT → `Transfer(account, 0x0, id)`). This is the standard NFT-inventory derivation (how Etherscan does it). An indexer/subgraph or a bounded `eth_getLogs` scan both work. The bot may submit the full owned set every cycle — `submitTokenIds` reconciles the cached set to exactly the submitted list (new ids are ownership-checked and added; cached ids absent from the list are removed; dedup is handled), so no delta tracking is needed. The write-time `ownerOf` check applies only to **newly-added ids**: any id being added to the cache for the first time that is not currently owned by `account` reverts the whole submission (`NotTokenOwner`), so the bot should submit only ids it derived as owned (a revert signals a race — an id claimed/transferred between scan and submit — to retry on the next cycle). Already-cached ids being resubmitted are not re-ownership-checked (an id transferred away since it was cached stays in the cache until a future submission omits it; reads discard it).

## Inputs

| Input | Source | Notes |
|---|---|---|
| **Account list** | Operator config | EVM addresses to track (the OIV per-chain accounts that use ether.fi). |
| **Chains** | Operator config | ether.fi withdrawals are **mainnet (1)** only today. |
| **Adapter address** | `script/config/deployments/1.json` → `balanceAdapters.EtherFiWithdrawalQueueAssisted` | Read at startup; refresh on redeploy. |
| **Owner key** | Operator secret store | Owns the adapter (`chainConfig.admin` = OIV Safe). Submit via the Safe Transaction Service / a granted Zodiac role, same as the Merkl bot. |

The `WithdrawRequestNFT` + `LiquidityPool` addresses and all valuation/verification rules are pinned in the adapter; the bot does not need them beyond event scanning.

## Steady-state loop

Cadence: **roughly daily** is sufficient for correctness (withdrawals take ~days to finalize), but more frequent (e.g. hourly) tightens the window between a new `requestWithdraw` and NAV reflecting it. Per account:

```
ids = scan_owned_tokenIds(account)        # Transfer(to=account) − Transfer(from=account)
if ids: submitTokenIds(account, ids)      # as ASSISTANT_ROLE holder; adapter dedups + re-verifies
# (submit reconciles the whole set, so stale ids self-purge; clearAccount only if you stop submitting an account)
```

## Failure modes

- **Bot down / lagging:** newly-requested withdrawals aren't reflected until the next cycle → NAV **under-reports** that account's in-flight ETH. Never over-reports. Mitigation: same SLA as the Merkl bot.
- **Submitting a newly-added non-owned id:** the write **reverts** (`NotTokenOwner`) and is atomic — the whole submission fails, leaving the prior cached set untouched. (Already-cached ids in the same list are not re-ownership-checked and do not trigger this revert; they stay cached until a future submission omits them, and reads discard non-owned ids either way.) Never an NAV risk (a non-owned id reads as 0), but when a new id fails the check the bot must filter to currently-owned ids and retry, or that account's update is skipped for the cycle.
- **Claimed id left in the cache:** reads as 0 (the request no longer exists / `ownerOf` reverts → dropped). GC is cosmetic (storage hygiene), not correctness.

## Non-goals

The bot supplies *which* ids to check — nothing else. It cannot influence the reported amount; all values are live on-chain reads. The adapter is the single source of truth for valuation.
