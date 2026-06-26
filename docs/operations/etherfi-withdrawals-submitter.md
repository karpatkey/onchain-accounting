# ether.fi withdrawals submitter bot — operator's guide

The `EtherFiWithdrawalsBalanceAdapter` (`src/balances/protocols/EtherFiWithdrawalsBalanceAdapter.sol`) reports a portfolio's in-flight ETH in ether.fi's withdrawal queue by reading an on-chain cache of candidate `WithdrawRequestNFT` `tokenId`s per account. The NFT is **not enumerable**, so an off-chain bot discovers the account's tokenIds and submits them. Crucially, the cache stores **only ids, never amounts** — the adapter values each id entirely from live on-chain reads (`getClaimableAmount` / `getRequest` + `LiquidityPool.amountForShare`) and re-verifies `ownerOf` on every read. The bot cannot fabricate value; at worst it omits an id (NAV under-reports), never over-reports. See [`docs/decisions/0014-agent-fed-cache-adapters-for-exit-queues.md`](../decisions/0014-agent-fed-cache-adapters-for-exit-queues.md) for the trust model (generalises Merkl/ADR 0007).

This file is the contract between the on-chain adapter and the ops process that feeds it. The bot lives in `kpk-agents` (`agents/automations/accounting/`), mirroring `submit_merkl_proofs.py`.

---

## Responsibilities

Per cycle, two things:

1. **Discover** each tracked account's open `WithdrawRequestNFT` tokenIds (off-chain).
2. **Submit** the fresh ones to the deployed adapter via `submitTokenIds(account, ids)` (or `submitTokenIdsBatch`), signed by the owner key.

Garbage-collection (`clearTokenId` / `clearAccount`) for claimed/transferred ids is an occasional cleanup, not steady-state-critical — stale ids already read as 0 (the adapter drops them when `ownerOf != account` or the request is gone).

## Discovering tokenIds (the only off-chain step)

ether.fi exposes no owner→tokenIds view. Recover ownership from event logs on the `WithdrawRequestNFT` (mainnet `0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c`):

```
owned(account) = { tokenId : Transfer(_, account, tokenId) } minus { tokenId : Transfer(account, _, tokenId) }
```

i.e. ERC-721 `Transfer` events where `to == account`, minus those where `from == account` (claims burn the NFT → `Transfer(account, 0x0, id)`). This is the standard NFT-inventory derivation (how Etherscan does it). An indexer/subgraph or a bounded `eth_getLogs` scan both work. The bot may submit the full owned set every cycle — the adapter dedups, and write-time `ownerOf` hygiene drops anything not currently owned.

## Inputs

| Input | Source | Notes |
|---|---|---|
| **Account list** | Operator config | EVM addresses to track (the OIV per-chain accounts that use ether.fi). |
| **Chains** | Operator config | ether.fi withdrawals are **mainnet (1)** only today. |
| **Adapter address** | `script/config/deployments/1.json` → `balanceAdapters.EtherFiWithdrawalQueue` | Read at startup; refresh on redeploy. |
| **Owner key** | Operator secret store | Owns the adapter (`chainConfig.admin` = OIV Safe). Submit via the Safe Transaction Service / a granted Zodiac role, same as the Merkl bot. |

The `WithdrawRequestNFT` + `LiquidityPool` addresses and all valuation/verification rules are pinned in the adapter; the bot does not need them beyond event scanning.

## Steady-state loop

Cadence: **roughly daily** is sufficient for correctness (withdrawals take ~days to finalize), but more frequent (e.g. hourly) tightens the window between a new `requestWithdraw` and NAV reflecting it. Per account:

```
ids = scan_owned_tokenIds(account)        # Transfer(to=account) − Transfer(from=account)
if ids: submitTokenIds(account, ids)      # as owner; adapter dedups + re-verifies
# optional GC: clearTokenId for ids whose ownerOf no longer == account (claimed/transferred)
```

## Failure modes

- **Bot down / lagging:** newly-requested withdrawals aren't reflected until the next cycle → NAV **under-reports** that account's in-flight ETH. Never over-reports. Mitigation: same SLA as the Merkl bot.
- **Submitting a non-owned id:** rejected at write (write-time `ownerOf` check) and would read as 0 anyway. Harmless.
- **Claimed id left in the cache:** reads as 0 (the request no longer exists / `ownerOf` reverts → dropped). GC is cosmetic (storage hygiene), not correctness.

## Non-goals

The bot supplies *which* ids to check — nothing else. It cannot influence the reported amount; all values are live on-chain reads. The adapter is the single source of truth for valuation.
