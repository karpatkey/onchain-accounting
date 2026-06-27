# StakeWise V3 exit-queue submitter bot — operator's guide

The `StakeWiseV3ExitQueueBalanceAdapter` (`src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueBalanceAdapter.sol`) reports a portfolio's in-flight assets in StakeWise V3's exit queue by reading an on-chain cache of candidate `(vault, positionTicket, timestamp)` tuples per account. Exit positions are **not enumerable** — a position is identified only by a `positionTicket` emitted in the `ExitQueueEntered` event — so an off-chain bot discovers the account's positions and submits them. Crucially, the cache stores **only the position coordinates, never amounts** — the adapter values each tuple entirely from live on-chain reads (`calculateExitedAssets` + `convertToAssets`) and the `calculateExitedAssets(receiver = account, …)` call is itself the ownership check. The bot cannot fabricate value; at worst it omits a position (NAV under-reports), never over-reports. See [`docs/decisions/0014-agent-fed-cache-adapters-for-exit-queues.md`](../decisions/0014-agent-fed-cache-adapters-for-exit-queues.md) for the trust model (generalises Merkl/ADR 0007; sibling of the ether.fi submitter).

> **Access control:** this adapter is in the assisted balance-adapter family — submissions are gated by `ASSISTANT_ROLE` (granted/rotated by `DEFAULT_ADMIN_ROLE`); see [ADR 0015](../decisions/0015-assisted-balance-adapter-family.md). Where this guide says "owner"/"owner key" below, read it as the `ASSISTANT_ROLE` holder.

This file is the contract between the on-chain adapter and the ops process that feeds it. The bot lives in `kpk-agents` (`agents/automations/accounting/`), mirroring `submit_merkl_proofs.py` and the ether.fi submitter.

---

## Responsibilities

Per cycle, two things:

1. **Discover** each tracked account's open exit positions (off-chain): the `(vault, positionTicket, timestamp)` tuples.
2. **Submit** the fresh ones to the deployed adapter via `submitPositions(account, positions)` (or `submitPositionsBatch`), signed by a key holding `ASSISTANT_ROLE`.

Garbage-collection (`clearPosition` / `clearAccount`) for claimed positions is an occasional cleanup, not steady-state-critical — stale tuples already read as 0 (the adapter drops them when `calculateExitedAssets` returns zero, i.e. the request was claimed/deleted).

## Discovering positions (the only off-chain step)

StakeWise exposes no owner→positions view. Recover positions from event logs on each tracked vault:

```
ExitQueueEntered(address indexed owner, address indexed receiver, uint256 positionTicket, uint256 shares)
```

For each event where `receiver == account`, record `(vault, positionTicket, blockTimestamp)` — where **`blockTimestamp` is the timestamp of the block that emitted the event**. This is load-bearing: the exit-request key is `keccak256(abi.encode(receiver, timestamp, positionTicket))`, so the timestamp must be the entry block's `block.timestamp` or the adapter will value the tuple as 0. An indexer/subgraph or a bounded `eth_getLogs` scan both work. The bot may submit the full open set every cycle — the adapter dedups, and write-time hygiene drops anything that no longer resolves to a live, account-owned position.

## Inputs

| Input | Source | Notes |
|---|---|---|
| **Account list** | Operator config | EVM addresses to track (the OIV per-chain accounts that use StakeWise V3). |
| **Vaults** | StakeWise VaultsRegistry / operator config | The vaults to scan `ExitQueueEntered` on (e.g. mainnet Genesis `0xAC0F…2885`, MetaVault `0x1563…cad3`). |
| **Chains** | Operator config | StakeWise V3 exit queues tracked here are **mainnet (1)** only today (vaults settle in ETH). |
| **Adapter address** | `script/config/deployments/1.json` → `balanceAdapters.StakeWiseV3ExitQueue` | Read at startup; refresh on redeploy. |
| **Owner key** | Operator secret store | Owns the adapter (`chainConfig.admin` = OIV Safe). Submit via the Safe Transaction Service / a granted Zodiac role, same as the Merkl bot. |

The `VaultsRegistry` address and all valuation/verification rules are pinned in the adapter; the bot does not need them beyond event scanning.

## Steady-state loop

Cadence: **roughly daily** is sufficient for correctness (validator exits take ~days), but more frequent tightens the window between a new `enterExitQueue` and NAV reflecting it. Per account, per vault:

```
positions = scan_exit_queue_entered(vault, receiver=account)   # (vault, positionTicket, blockTimestamp)
if positions: submitPositions(account, positions)             # as ASSISTANT_ROLE holder; adapter dedups + verifies on-chain
# optional GC: clearPosition for tuples whose calculateExitedAssets(account,…) is now 0 (claimed)
```

## Failure modes

- **Bot down / lagging:** newly-entered exit positions aren't reflected until the next cycle → NAV **under-reports** that account's in-flight assets. Never over-reports. Mitigation: same SLA as the Merkl bot.
- **Submitting a tuple not owned by the account** (wrong receiver/timestamp/ticket): rejected at write (`calculateExitedAssets(account,…)` returns 0) and would read as 0 anyway. Harmless.
- **Submitting a non-StakeWise vault:** rejected at write (`VaultsRegistry.vaults(vault)` is false). Harmless.
- **Claimed position left in the cache:** reads as 0 (the exit request is deleted on claim → `calculateExitedAssets` returns 0). GC is cosmetic (storage hygiene), not correctness.

## Non-goals

The bot supplies *which* positions to check — nothing else. It cannot influence the reported amount; all values are live on-chain reads. The adapter is the single source of truth for valuation.
