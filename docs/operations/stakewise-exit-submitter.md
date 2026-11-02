# StakeWise V3 exit-queue submitter bot — operator's guide

The `StakeWiseV3ExitQueueAssistedBalanceAdapter` (`src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.sol`) reports a portfolio's in-flight assets in StakeWise V3's exit queue by reading an on-chain cache of candidate `(vault, positionTicket, timestamp)` tuples per account. Exit positions are **not enumerable** — a position is identified only by a `positionTicket` emitted in the `ExitQueueEntered` event — so the tuple has to be fed to the adapter. Crucially, the cache stores **only the position coordinates, never amounts** — the adapter values each tuple entirely from live on-chain reads (`calculateExitedAssets` + `convertToAssets`), and the `calculateExitedAssets(receiver = account, …)` call is itself the ownership check. The feed cannot fabricate value; at worst it omits a position (NAV under-reports), never over-reports. See [`docs/decisions/0014-agent-fed-cache-adapters-for-exit-queues.md`](../decisions/0014-agent-fed-cache-adapters-for-exit-queues.md) for the trust model (generalises Merkl/ADR 0007; feeding model refined by [ADR 0018](../decisions/0018-assistant-fed-assisted-balance-adapters.md); sibling of the ether.fi submitter).

> **Access control:** this adapter is in the assisted balance-adapter family. Its **owner path** — `submit` / `remove` / `clearAccount` — is `msg.sender`-keyed (no role), so a caller only ever touches its own set (see [ADR 0015](../decisions/0015-assisted-balance-adapter-family.md) and [ADR 0018](../decisions/0018-assistant-fed-assisted-balance-adapters.md)). Because an exit position's on-chain owner is the queue `receiver`, only a call whose `msg.sender` is that account registers anything (`calculateExitedAssets(msg.sender, …)` must resolve to a non-zero owed amount) — so the feed must execute **as the OIV Safe itself**, normally via the `StakeWiseV3ExitQueueAssistant` the Safe delegatecalls. Where this guide says "owner"/"owner key" below, read it as the OIV Safe. **Keeper path ([ADR 0030](../decisions/0030-assisted-adapters-keeper-submit-and-preview.md)):** for positions the Safe did not open through its assistant, a keeper holding `SUBMITTER_ROLE` (granted by the Security Council, the adapter's `DEFAULT_ADMIN_ROLE`) can `submitFor(account, coord)`, filed only under the account the protocol says owns it; anyone can `removeFor` a position the protocol proves gone; `previewPositions` values coordinates without the cache.

This file is the contract between the on-chain adapter and the ops process that feeds it. In the normal path the position is registered **inline**: when the Safe enters (or claims) the queue it delegatecalls the `StakeWiseV3ExitQueueAssistant` (`src/balances/AssistedBalanceAdapters/assistants/StakeWiseV3ExitQueueAssistant.sol`), which `submit`s (or `remove`s) the ticket in the same transaction. An off-chain reconciliation process is a backstop for positions the inline path misses — most notably a re-queued remainder ticket (StakeWise re-queues a not-yet-checkpointed remainder under a **new** ticket, which the assistant does not track) — re-submitting them by having the Safe call `submit` directly.

---

## Responsibilities

Per cycle, two things:

1. **Discover** each tracked account's open exit positions (off-chain): the `(vault, positionTicket, timestamp)` tuples not already tracked on the adapter.
2. **Submit** each missing tuple to the deployed adapter via `submit(vault, positionTicket, timestamp)`, executed **as the account** (from the OIV Safe) — the call adds that one coordinate to the caller's own cached set.

`submit` has **incremental** semantics: each call validates and adds a single `(vault, positionTicket, timestamp)` coordinate, deduped by `keccak256` (idempotent — resubmitting a tracked, still-owned tuple is a no-op). It does **not** replace the set. A claimed position is dropped either by the assistant's inline `remove` on claim, or lazily: a stale tuple left in the cache reads as 0 (the adapter drops it at read time when `calculateExitedAssets` returns zero, i.e. the request was claimed/deleted). `remove(vault, positionTicket, timestamp)` (single coordinate) and `clearAccount()` (the caller's whole set) are the explicit GC path — optional, since reads already ignore stale tuples.

## Discovering positions (the only off-chain step)

StakeWise exposes no owner→positions view. Recover positions from event logs on each tracked vault:

```
ExitQueueEntered(address indexed owner, address indexed receiver, uint256 positionTicket, uint256 shares)
```

For each event where `receiver == account`, record `(vault, positionTicket, blockTimestamp)` — where **`blockTimestamp` is the timestamp of the block that emitted the event**. This is load-bearing: the exit-request key is `keccak256(abi.encode(receiver, timestamp, positionTicket))`, so the timestamp must be the entry block's `block.timestamp` or the adapter will value the tuple as 0. An indexer/subgraph or a bounded `eth_getLogs` scan both work. Submit only tuples **not already tracked** (resubmits are harmless no-ops, but wasteful) and only **still-live** ones. Do **not** submit already-claimed positions: write-time validation is fail-loud — a tuple whose vault is not StakeWise-registered makes `submit` **revert** `InvalidCoordinate`, and one that no longer resolves to a non-zero owed amount for the account **reverts** `CoordinateNotOwned`. Because each `submit` is a single coordinate and reverts atomically, a bad tuple never touches the rest of the account's cached set.

## Inputs

| Input | Source | Notes |
|---|---|---|
| **Account list** | Operator config | EVM addresses to track (the OIV per-chain accounts that use StakeWise V3). |
| **Vaults** | StakeWise VaultsRegistry / operator config | The vaults to scan `ExitQueueEntered` on (e.g. mainnet Genesis `0xAC0F…2885`, MetaVault `0x1563…cad3`). |
| **Chains** | Operator config | The exit-queue adapter is enabled in config on **mainnet (1)** and **Gnosis (100)** today (mainnet vaults settle in ETH, Gnosis vaults in GNO). |
| **Adapter address** | `script/config/deployments/<chainId>.json` → `balanceAdapters.StakeWiseV3ExitQueueAssisted` | Read at startup; refresh on redeploy. |
| **Assistant address** | `script/config/deployments/<chainId>.json` → `StakeWiseV3ExitQueueAssistant` | The delegatecall action the Safe uses to enter/claim and feed the adapter in one tx. |
| **Owner key** | Operator secret store | The OIV Safe (`chainConfig.admin`), which is the exit-position `receiver`. Feed via the Safe Transaction Service / a granted Zodiac role — a `submit` sent from any other key tracks that key's own (empty) set, not the Safe's. |

The `VaultsRegistry` address and all valuation/verification rules are pinned in the adapter; the reconciliation process does not need them beyond event scanning.

## Steady-state loop

Cadence: **roughly daily** is sufficient for correctness (validator exits take ~days), but more frequent tightens the window between a new `enterExitQueue` and NAV reflecting it. Per account, per vault:

```
positions = scan_exit_queue_entered(vault, receiver=account)   # (vault, positionTicket, blockTimestamp), still-live, not already tracked
for (vault, ticket, ts) in positions:
    submit(vault, ticket, ts)                                  # executed AS the Safe; adds one coordinate, reverts atomically on a bad tuple
# optional GC: remove(vault, ticket, ts) / clearAccount() — redundant once a claimed tuple reads as 0
```

## Failure modes

- **Feed down / lagging: NOT APPLICABLE to the assistant model, and the "SLA" framing is stale.** There is no feed cycle and no staleness window: the coordinate is written **atomically, in the same transaction** that enters the exit queue (ADR 0018), not by an off-chain bot on an SLA — that description belonged to the superseded `ASSISTANT_ROLE` agent-fed model. Nor can an exit be entered *without* being fed: the Safes' **roles-modifier allow-list permits `enterExitQueue` only through the assistant**, so the direct `vault.enterExitQueue` path is not a permitted call, and the cache is therefore **complete by construction** rather than merely conservative. *If* the roles configuration ever changed to permit a direct call, the consequence would be bounded — the position isn't tracked → NAV **under-reports** that account's in-flight assets, never over-reports. **That roles change is the real residual risk to review, and no tripwire in this repository would detect it.** Enforcement is in the Safe's roles configuration, outside this repo; see ADR 0015 / ADR 0018 and `src/balances/AssistedBalanceAdapters/README.md` §5.0.
- **Submitting a tuple not owned by the account** (wrong receiver/timestamp/ticket): `submit` **reverts** `CoordinateNotOwned` — `calculateExitedAssets(account, …)` returns 0, which fails the write-time check. The prior set is left untouched (atomic revert). Never corrupts NAV, but that coordinate's submit fails until the tuple is corrected, so the scan must produce the exact `(vault, ticket, timestamp)`. Even if a stale tuple somehow reached the cache, reads re-verify and value it as 0.
- **Submitting a non-StakeWise vault:** `submit` **reverts** `InvalidCoordinate` (`VaultsRegistry.vaults(vault)` is false). Atomic; the rest of the set untouched.
- **Cache full:** past `MAX_POSITIONS` (256) per account, `submit` **reverts** `CoordinateCacheFull`. `clearAccount()` or `remove` claimed tuples to make room — no normal account approaches the cap.
- **Claimed position left in the cache:** reads as 0 (the exit request is deleted on claim → `calculateExitedAssets` returns 0). GC is cosmetic (storage hygiene), not correctness. (`remove` of a still-owed tuple reverts `CoordinateStillLive`; of an untracked tuple, `CoordinateNotCached`.)

## Non-goals

The feed supplies *which* positions to check — nothing else. It cannot influence the reported amount; all values are live on-chain reads. The adapter is the single source of truth for valuation.
