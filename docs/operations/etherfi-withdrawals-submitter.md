# ether.fi withdrawals assistant — operator's guide

The `EtherFiWithdrawalQueueAssistedBalanceAdapter` (`src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol`) reports a portfolio's in-flight ETH in ether.fi's withdrawal queue by reading an on-chain cache of candidate `WithdrawRequestNFT` `tokenId`s per account. The NFT is **not enumerable**, so its tokenId cannot be recovered from a `view` — it has to be fed to the adapter. Crucially, the cache stores **only ids, never amounts** — the adapter values each id entirely from live on-chain reads (`getClaimableAmount` / `getRequest` + `LiquidityPool.amountForShare`) and re-verifies `ownerOf` on every read. The feeder cannot fabricate value; at worst it omits an id (NAV under-reports), never over-reports. See [ADR 0018](../decisions/0018-assistant-fed-assisted-balance-adapters.md) for the shipped feeding model and [ADR 0014](../decisions/0014-agent-fed-cache-adapters-for-exit-queues.md) for the original trust-model derivation (generalises Merkl/ADR 0007).

> **Access control:** this adapter is in the assistant-fed assisted balance-adapter family. Its **owner path** — `submit`/`remove`/`clearAccount` — takes **no `account` argument and no role**; they key off `msg.sender`, so a caller only ever mutates its own cached set (the [ADR 0015](../decisions/0015-assisted-balance-adapter-family.md) family, feeding model per [ADR 0018](../decisions/0018-assistant-fed-assisted-balance-adapters.md)). Where this guide says "owner" below, read it as the owning Safe whose withdrawals are being tracked. **Keeper path ([ADR 0030](../decisions/0030-assisted-adapters-keeper-submit-and-preview.md)):** for positions the Safe did not open through its assistant, a keeper holding `SUBMITTER_ROLE` (granted by the Security Council, the adapter's `DEFAULT_ADMIN_ROLE`) can `submitFor(account, coord)`, filed only under the account the protocol says owns it; anyone can `removeFor` a position the protocol proves gone; `previewPositions` values coordinates without the cache.

The canonical feeder is not an off-chain bot but an on-chain, stateless assistant — `EtherFiWithdrawalQueueAssistant` (`src/balances/AssistedBalanceAdapters/assistants/EtherFiWithdrawalQueueAssistant.sol`) — that the owning Safe **delegatecalls**. Under delegatecall `address(this)` is the Safe, so ether.fi sees `msg.sender = Safe` and the adapter records against that same Safe. The assistant pushes the `requestId` on `requestWithdraw` and pops it on `claimWithdraw`, **atomically in the same transaction** — no discovery step, no staleness window.

---

## Responsibilities

The assistant keeps the cache current as a side effect of the Safe's own withdraw/claim actions. Two entrypoints, both **delegatecall-only** (a direct call reverts `NotDelegateCall`):

1. **`requestWithdraw(amount)`** — approves the LiquidityPool for the Safe's eETH, calls `requestWithdraw(recipient = Safe, amount)` (mints the `WithdrawRequestNFT` to the Safe), then `submit(requestId)` on the adapter. The new id is tracked the instant the withdrawal is requested.
2. **`claimWithdraw(tokenId)`** — claims the request (ether.fi's claim hard-requires `ownerOf == msg.sender`, satisfied because the Safe is the owner), which burns the NFT and sends ETH to the Safe, then `remove(tokenId)` on the adapter. It claims **first**, then removes, because the adapter's `remove` requires the request to be claimed (see below). The post-claim `remove` is best-effort and never blocks the claim.

No cron, no log scanning, no separate signing key: feeding rides on the withdrawal lifecycle itself. EOAs cannot delegatecall, so the intended callers are Safe/Avatar accounts (gated at the Safe/Zodiac layer).

## Feed surface (adapter)

The Safe (via the assistant, or directly) calls the adapter's `msg.sender`-keyed surface:

| Call | Effect | Reverts |
|---|---|---|
| `submit(uint256 tokenId)` | Track `tokenId` for the caller (idempotent; deduped by hash). | `CoordinateNotOwned` if the caller doesn't own it; `CoordinateCacheFull` past `MAX_TOKEN_IDS` (256). |
| `remove(uint256 tokenId)` | Stop tracking `tokenId` for the caller. | `CoordinateNotCached` if not tracked; `CoordinateStillLive` if still owned (not yet claimed). |
| `clearAccount()` | Drop the caller's entire cached set. | — |
| `tokenIdsOf(address account)` | View the account's cached candidate ids (display/debug; not ownership-filtered). | — |

`submit` is **add**, not replace: each call tracks one more id and dedups against the existing set. `remove` is gated on the id no longer being owned — because `claimWithdraw` **burns** the NFT, a claimed id becomes removable while a still-pending id cannot be dropped (`CoordinateStillLive`). This is why the assistant always claims before removing. Explicit `clearAccount` is an occasional reset (e.g. to prune ids acquired outside the assistant), not steady-state-critical: a claimed id left in the cache reads as 0 anyway (the adapter drops it when `ownerOf != account`), and the `MAX_TOKEN_IDS` (256) cap is one a normal account never approaches.

## Inputs

| Input | Source | Notes |
|---|---|---|
| **Owning Safe** | Operator config | The OIV per-chain Safe that holds eETH / requests ether.fi withdrawals; the account the cache is keyed on. |
| **Chains** | Operator config | ether.fi withdrawals are **mainnet (1)** only today. |
| **Adapter address** | `script/config/deployments/1.json` → `balanceAdapters.EtherFiWithdrawalQueueAssisted` | Read at startup; refresh on redeploy. |
| **Assistant address** | `script/config/deployments/1.json` → `EtherFiWithdrawalQueueAssistant` | The delegatecall target the Safe runs. |

The `WithdrawRequestNFT`, `LiquidityPool`, and `eETH` addresses and all valuation/verification rules are pinned in the adapter and assistant at construction; nothing else is needed at runtime.

## Steady-state flow

There is no polling loop. The cache stays correct because every withdrawal and claim goes through the assistant:

```text
# request: Safe delegatecalls the assistant
requestWithdraw(amount)   # mints WithdrawRequestNFT to Safe, then submit(requestId)

# claim (~days later, once finalized): Safe delegatecalls the assistant
claimWithdraw(tokenId)    # claims (burns NFT, ETH to Safe), then remove(tokenId)
```

If a Safe ever acquires a `WithdrawRequestNFT` outside the assistant, it can call the adapter's `submit(tokenId)` directly to start tracking it. In normal operation that should not arise: **the Safes' roles-modifier allow-list permits `requestWithdraw` only via the assistant**, so a direct `requestWithdraw` is not a permitted call.

## Failure modes

- **Assistant not used for a withdrawal.** **Not reachable in normal operation, and not a matter of operator discipline** — the roles-modifier permission set allows this protocol entry only through the assistant; the direct `LiquidityPool.requestWithdraw` path is not in the allow-list. So a withdrawal cannot be in flight without its id having been fed, and the cache is **complete by construction** rather than merely conservative. *If* the roles configuration ever changed to permit a direct call, the consequence would be bounded: that id isn't tracked → NAV **under-reports** the account's in-flight ETH until someone `submit`s it. Never over-reports. **That is the real residual risk to review — a roles-permission change adding a non-assistant path — and no tripwire in this repository would detect it.** Enforcement lives in the Safe's roles configuration, outside this repo; see ADR 0015 / ADR 0018 and `src/balances/AssistedBalanceAdapters/README.md` §5.0.
- **Submitting a non-owned id:** `submit` **reverts** `CoordinateNotOwned`. No NAV risk (it would read as 0 anyway); the caller must submit only ids it owns.
- **Removing a still-pending id:** `remove` **reverts** `CoordinateStillLive` — the id must be claimed (NFT burned) first. The assistant's `claimWithdraw` orders this correctly.
- **Claimed id left in the cache:** reads as 0 (the NFT is burned → `ownerOf` reverts → dropped). GC is cosmetic (storage hygiene), not correctness.

## Non-goals

The assistant supplies *which* ids to track — nothing else. It cannot influence the reported amount; all values are live on-chain reads. The adapter is the single source of truth for valuation.
