# 0014 — Agent-fed cache adapters for non-enumerable withdrawal/exit queues (ether.fi, StakeWise V3)

**Status:** accepted

> Companion to [ADR 0007](0007-merkl-trust-minimized-cache.md) (Merkl). This generalises the owner-gated, on-chain-verified cache pattern to withdrawal/exit queues whose positions cannot be enumerated from a `view`, and specifies two concrete adapters.

## Context

Two in-flight-withdrawal gaps stay invisible to NAV because the position id cannot be discovered from inside a Solidity `view`:

- **ether.fi withdrawal queue** — `requestWithdraw` burns eETH/weETH and mints a `WithdrawRequestNFT` (`0x7d57…4E2c`). Spike (2026-06-23/24): the NFT is **not** `ERC721Enumerable` and exposes **no** owner→tokenIds view; the tokenId only exists in the `Transfer`/request event. `balanceOf` gives a count, never the ids.
- **StakeWise V3 exit queue** — `enterExitQueue(shares, receiver)` moves vault shares into the queue and returns a `positionTicket`. Spike (2026-06-24): `IVaultEnterExit` identifies a position only by that `positionTicket` (emitted in `ExitQueueEntered`); every query (`getExitQueueIndex`, `calculateExitedAssets`) needs the ticket, and there is **no** per-account enumeration (confirmed on-chain against the v5 Genesis vault).

In both, the value behaves identically (see ADR-adjacent analysis in `.claude/nav-coverage-gaps.md`): on withdrawal the underlying token **leaves the wallet** (so the wallet/vault adapter reports less immediately), and the value sits in the non-enumerable NFT/ticket until claimed (~1 day to several days, bound by validator-exit queues). NAV under-reports the exiting amount for that window. Both are ~$0 in steady state — this is **correctness-on-exit** coverage, not current value.

The shipped withdrawal-queue adapters (Lido/Stader/Kelp) work only because those protocols expose an owner→requests view. ether.fi and StakeWise don't, so a pure `view` adapter is impossible — the same structural wall Merkl hit, where the data lived off-chain.

[ADR 0007](0007-merkl-trust-minimized-cache.md) resolved that for Merkl with an **owner-gated, on-chain-verified cache**: an off-chain agent (`kpk-agents/agents/automations/accounting/submit_merkl_proofs.py`) supplies the missing data, and the adapter verifies it on-chain so the agent cannot fabricate values. That agent + the `MerklRewardsBalanceAdapter` pair are now live. We reuse the pattern.

## Decision

Ship **two cache adapters** — `EtherFiWithdrawalQueueBalanceAdapter` and `StakeWiseExitQueueBalanceAdapter` — as the **third and fourth documented mutable adapters** (after `MerklRewards`, ADR 0007). Each pairs with an off-chain submitter agent in `kpk-agents` that mirrors `submit_merkl_proofs.py`. (These were initially `Ownable`; they have since been consolidated, with Merkl, under the **assisted balance-adapter family** — `AssistedBalanceAdapter` on OpenZeppelin AccessControl, where `ASSISTANT_ROLE` submits and `DEFAULT_ADMIN_ROLE` administers — see [ADR 0015](0015-assisted-balance-adapter-family.md). The "owner" framing below describes the original design; substitute `ASSISTANT_ROLE` for the submit gate.)

**Key refinement over Merkl — the cache stores *ids only*, never amounts.** Merkl caches a `(cumulativeAmount, root)` verified at write time. Here the cache stores only the **candidate id set** per account; the **amount is read live on every NAV read** and re-verified to still belong to the account. The agent therefore cannot influence the reported value *at all* — only the set of positions checked. Failure mode is strictly under-report (agent omits/lags an id), never over-report. This is a *stronger* trust model than Merkl's.

### Shared shape

- Storage: `mapping(address account => uint256[] ids)` + an index map for O(1) removal (mirror `MerklRewards._userTokens`/`_userTokenIdxPlus1`).
- Mutators (`onlyOwner`, owner = the OIV Safe / agent role, same as Merkl):
  - `submitTokenIds(address account, uint256[] ids)` (+ a batch variant) — add candidate ids. Light write-time sanity check (id currently belongs to `account`) + a per-account `MAX` cap so the read loop stays gas-bounded; not load-bearing for correctness since reads re-verify. (StakeWise's analog submits `positionTicket`s.)
  - `clearTokenId(address account, uint256 id)` / `clearAccount(account)` — GC claimed/stale ids. Idempotent; not required for correctness (stale ids read as 0).
- Reads: `getAdapterPositions(account, filter)` iterates the cached ids, **re-verifies ownership on-chain**, values each from a **live protocol read**, drops anything that fails (claimed/transferred/zero). Never reverts. Emits **one aggregated `Supplied` leg per account** — the sum across the account's live positions — denominated in the underlying staking asset (must be a registered NAV asset), matching the Lido/Stader/Kelp WQ family.
- Identity: `protocolId = keccak256("etherfi-withdrawal")` / `keccak256("stakewise-exit")` (new slugs in `ProtocolIds.sol`); **`positionId` is empty (`""`) — account-global aggregation, like the other WQ adapters** (the cached ids are an internal coordinate, not emitted). Immutable.
- Everything except the cache is immutable: queue/NPM/vault-registry addresses, NAVCalculator, identity. No upgrade path. No admin-injected amounts.

### EtherFiWithdrawalQueueBalanceAdapter

- Reads `WithdrawRequestNFT` (`0x7d57…4E2c`) — native-ETH-denominated (eETH unwinds to ETH).
- Per cached `tokenId`: `ownerOf(tokenId) == account` (the on-chain ownership check; a claimed/transferred NFT is burned/moved → drop). Then value = `getClaimableAmount(tokenId)` if `isFinalized(tokenId)`, else the request's `amountOfEEth`/share-implied ETH from `getRequest(tokenId)` (mirror the Lido WQ adapter's finalized-vs-pending valuation). Leg: `Supplied`, asset = native ETH sentinel.
- Agent: scans `Transfer(_, account, tokenId)` minus `Transfer(account, _, tokenId)` (verified working 2026-06-24: recovers live ids for holder `0xcFFab3…1Af4`) → `submitTokenIds`.

### StakeWiseExitQueueBalanceAdapter

- Reads each registered StakeWise V3 vault (reuse the `StakeWiseV3VaultsMeta` instance set, or its own governed set) — staking-asset-denominated (ETH on mainnet, GNO on Gnosis).
- Per cached `(vault, positionTicket)`: `idx = vault.getExitQueueIndex(ticket)`; `(leftTickets, exitedTickets, exitedAssets) = vault.calculateExitedAssets(account, ticket, block.timestamp, idx)`. **The `receiver=account` argument is the verification** — it returns non-zero only for tickets that genuinely belong to `account` (no `ownerOf` needed; a foreign ticket yields 0 → dropped). Value = `exitedAssets` (claimable) + the still-queued `leftTickets` converted to assets at the vault's current rate. Leg: `Supplied`, asset = staking asset.
- Agent: scans `ExitQueueEntered(_, account, positionTicket, _)` per registered vault → `submitTokenIds`.

### Config + ops

- Standalone (non-meta) adapters; wired in `04` + `06` like other simple adapters, plus the `onlyOwner` grant to the agent role (mirror Merkl). Underlying assets (ETH, GNO) already registered.
- One operator doc each under `docs/operations/` (mirror `merkl-proof-submitter.md`): SLA, the "agent down → under-report" failure mode, GC runbook.

## Consequences

**Positive:**
- Closes both correctness-on-exit gaps with a proven pattern and an existing agent framework (low marginal cost now).
- **Stronger trust than Merkl**: the cache holds no amounts, so the agent cannot inflate, suppress-by-value, or rewrite anything — only fail to list an id (→ under-report). All values are live on-chain reads, re-verified to belong to the account on every read.
- Deterministic + auditable: anyone can recompute the legs from `(cached ids, on-chain ownership, live protocol read)`.
- Stale/claimed positions auto-drop at read time — no monotonicity assumptions, no read-time decisions (same conservative posture as Merkl's root-rotation handling).

**Negative / watch:**
- Two **more** mutable adapters (3rd + 4th). CLAUDE.md + `BALANCE_ADAPTERS.md` must list them alongside `MerklRewards`.
- Owner trust extends to **completeness** only: if the agent stops/lags, those accounts under-report. Same posture + mitigation as Merkl (Karpatkey-ops SLA, runbook). Iron Law (cannot over-report) preserved — and here even tighter (no cached amounts).
- Operational dependency + storage growth per (account, id); `clearTokenId`/`clearAccount` are the GC primitives. Exit windows are short (~days), so churn is higher than Merkl — the agent must GC claimed ids promptly or storage drifts (harmless to correctness, just bloat).
- StakeWise valuation of the still-queued `leftTickets` leg needs care (the queued portion's asset conversion at the current vault rate) — pin it in the fork test with a real exiting holder.
- ~$0 steady-state value: justified mainly because the agent framework already exists; prioritise behind the pure-on-chain gaps (Nexus $3.35M, Sablier $1.19M, kUSD/kETH $1.87M).

## Trust model summary

| Capability | Who | Bound by |
|---|---|---|
| Submit candidate ids | owner/agent only | Reads re-verify ownership on-chain; cannot fabricate value (no cached amounts) |
| Refuse to submit / lag | owner/agent | Under-report only; never over-report |
| Set the amount | **nobody** | Values are live protocol reads (`getClaimableAmount` / `calculateExitedAssets`) |
| Read NAV | anyone | Pure view; deterministic from on-chain state + cached ids |
| Clear stale ids | owner/agent | Idempotent; no correctness impact (stale reads 0 anyway) |

## Alternatives considered

1. **Don't build them.** Status quo: NAV under-reports during exits (~$0 today). Acceptable but incomplete.
2. **Trust the agent to inject amounts** (Merkl option 2). Rejected — same auditability defeat as in ADR 0007; and unnecessary here since the amount is directly readable on-chain once the id is known.
3. **Brute-force enumeration in the adapter** (`ownerOf(0..N)` / scan all tickets). Infeasible — ~80k+ ids, one `eth_call` can't.
4. **App-display-only via an indexer** (no NAV). Doesn't close the NAV gap; we already show eETH/shares pre-exit.
5. **Wait for the protocols to add an owner→ids view.** Out of our control; indefinite.

Option matching ADR 0007 (owner-gated cache, on-chain-verified) is the only one that closes the NAV gap while preserving "anyone can verify the numbers" — and the ids-only refinement makes it strictly stronger than the Merkl precedent.
