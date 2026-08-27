# 0007 — Merkl rewards adapter: proof-verified, trust-minimized cache

> **Naming note (2026-08-27):** the function, error and event names below are **PRE-REFACTOR**. The adapter now
> extends the shared `AttestedValueCache` base (ADR 0022) and uses the family-generic surface —
> `clearAttestation`, `assetsOf`, `attestations`, `UninitializedEpoch`, `TooManyAttestations`,
> `AttestationStillLive`, `DuplicateAsset`, `AttestationCached`. The reasoning in this ADR is unchanged; only the
> names moved. For the live ABI see `docs/operations/merkl-proof-submitter.md`.

**Status:** accepted — **amended 2026-07 (permissionless refactor; see the amendment below).** The role-gated v1
described in the body was removed in PR #141 (with the legacy `AssistantFedBalanceAdapter` base); the adapter is
re-added in the permissionless shape this ADR itself anticipated (Alternatives #1). Read the amendment first; the
body below is retained as the original context/rationale, with the role-gating superseded.

## Amendment (2026-07) — permissionless, submit-on-behalf-of

**What changed.** `submitProofs(user, Allocation[])` / `submitProofsBatch` are now **permissionless** (no
`ASSISTANT_ROLE`, no `DEFAULT_ADMIN_ROLE`, no AccessControl, no `AssistantFedBalanceAdapter` base). Submission still
takes an **explicit `user`** (submit-on-behalf-of — the intended feeder is a keeper EOA / cron job that periodically
submits a tracked set of accounts), and every write is still proof-verified against the live `Distributor.getMerkleRoot()`.
The constructor drops `admin_`/`assistant_` and is now `(distributor_, navCalculator_)`.

**Why this is safe (the griefing objection in Alternatives #1 no longer holds).** Alternatives #1 rejected
permissionless submission for v1 over "spam / storage griefing — any attacker can populate `(user, token)` entries for
arbitrary users." Proof-verification defuses this: a submission for `user` only lands if its proof validates against
Merkl's real root for that user's leaf, so a caller can only ever cache a user's **real, Merkl-attested** per-token AMOUNT —
bounded to that user's *actual* reward footprint. Worst case a griefer pays gas to report a real balance (helpful, not
harmful); they cannot fabricate or inflate the AMOUNT. **They can, however, fabricate campaign IDENTITY:** the proof
binds the per-token cumulative but not the split, so a third party holding the (public) proof can re-submit it divided into up to `MAX_CAMPAIGNS_PER_TOKEN` attacker-chosen campaign legs. Bounded, never inflating NAV, and repairable by one upsert — but it is a real fabrication of position identity, so "cannot populate fake entries" was too strong and is withdrawn. So the completeness dependency on a *trusted*
assistant is removed — anyone (a public keeper, or the account itself) can refresh — while the "cannot over-report"
Iron Law is preserved by the same proof check.

**`submitProofs` is upsert; `clearAllocation`/`clearAccount` are stale-gated (fixes L-02 and the permissionless-
suppression follow-up).** `submitProofs` **upserts** each proven `(user, token)` — it adds or refreshes the entries it
carries and never drops a token it omits — so a partial or empty submit can NOT suppress a live entry. Removal is only
via `clearAllocation`/`clearAccount`, which revert `AllocationStillLive` while an entry still contributes to NAV
(cached root == live root AND unclaimed > 0) and only delete stale (root-rotated) or fully-claimed entries. So a live
allocation can be *refreshed* but never suppressed by any caller — both the old L-02 vector (an `ASSISTANT_ROLE`
holder zeroing a valid allocation) and the clear-then-store wipe (`submitProofs(victim, [])` under the earlier
"replace whole list" draft) are structurally gone.

**A new "attested" family (`IAttestedBalanceAdapter`), NOT the coordinate-cache `IAssistedBalanceAdapter` — see
[ADR 0022](0022-attested-balance-adapter-family.md).** Merkl does **not** implement the `IAssistedBalanceAdapter`
marker ([ADR 0018](0018-assistant-fed-assisted-balance-adapters.md)): that family is `msg.sender`-keyed and caches
*coordinates, never amounts*, valuing each read from live on-chain reads + per-read ownership re-verification, fed by a
`delegatecall` assistant. Merkl is categorically different, so it gets its own marker **`IAttestedBalanceAdapter`**
(`src/balances/IAttestedBalanceAdapter.sol`): externally-fed by a **permissionless keeper EOA** (no assistant
contract) that **upserts** proven `(account, token)` allocations **on-behalf-of** (explicit `account`) — each write
adds/refreshes, never drops an omitted entry — and caches a **proof-verified amount** (the allocation is off-chain and
not derivable on-chain). Its "under-report only" guarantee rests on **proof-verification + stale-root→0** (return 0
whenever the cached root ≠ the live root), not on `msg.sender`-keying or live ownership re-verification. The family's
one universal mutator is a stale-gated `clearAccount(address)` (reverts while any element is live). Merkl
(`MerklRewardsAttestedBalanceAdapter`, `src/balances/AttestedBalanceAdapters/`) is the first attested member — an
`IAttestedBalanceAdapter` + `IPositionDescribable` adapter (the documented mutable exception), permissionless. The
fully-on-chain alternative was researched and ruled out: Merkl commits only a root + IPFS pointer on-chain and computes
allocations off-chain, so no `view` (and no on-chain recomputation) can produce an unclaimed amount without
externally-supplied leaf data — the proof-fed cache is the trust-minimized optimum.

> **Added later (not part of the original decision):** the contract described below — `MerklRewardsAssistedBalanceAdapter` — and the role-gated agent-fed base it rode on are **no longer present in this repository**; they were removed in #141 and are retrievable from git history. No contract in `src/` declares an `ASSISTANT_ROLE`, and the assisted family that remains ([ADR 0015](0015-assisted-balance-adapter-family.md) / [ADR 0018](0018-assistant-fed-assisted-balance-adapters.md)) is permissionless and `msg.sender`-keyed. **This note applies to the ASSISTED implementation only.** Merkl has since been re-added as the *attested*-family `MerklRewardsAttestedBalanceAdapter` (see the amendment above), so the Reference section below has been **rewritten to the current attested paths and they resolve** — do not read it as dead, and note in particular that the constructor schema recorded there deliberately has no `protocol`/`positionId` keys. Deploy-config entries under `script/config/contracts-deployment-config/balance-adapters/*.json` exist again, keyed `MerklRewards` (shipped `enabled: false`). The decision body below stands as recorded at the time it was taken; read it as history, not as a description of what ships today.

## Context

Merkl (Angle Labs) distributes rewards via off-chain merkle trees. The on-chain Distributor at `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae` (canonical address on every supported EVM chain) only stores **claimed** amounts: `mapping(address user => mapping(address token => Claim { uint208 amount, uint48 timestamp, bytes32 merkleRoot }))`. To learn a user's *unclaimed* allocation you need the merkle leaf and proof from the off-chain Merkl API — the contract has no view function for it.

Without a Merkl adapter, NAV silently under-reports any portfolio that earns Merkl emissions (ARB DRIP, MORPHO campaigns, ANGLE, OP grants, etc.) until those rewards are claimed and land in the wallet (where `ERC20DefaultBalanceAdapter` picks them up). Building a Merkl-aware adapter bumps into a structural problem: a balance adapter is a `view` contract, but the data we need lives off-chain. Several options are on the table:

1. **Don't build the adapter.** Status quo. NAV under-reports; downstream products either tolerate the gap or claim more aggressively to materialize rewards in-wallet.
2. **Trust the off-chain bot to inject *amounts* into the adapter.** Simple, but the bot owner could quietly inflate or suppress reported balances. Defeats the auditability purpose.
3. **Trust the off-chain bot to inject *merkle proofs*; verify on-chain against the live `Distributor.getMerkleRoot()`.** The bot can only cache truthful values, because invalid proofs revert at the contract. The bot's owner cannot fabricate amounts even with full custody of the bot's key. NAV becomes deterministically derivable from `(merkle root currently published by Merkl, last cached proof, claimed[user][token].amount)` — auditable end-to-end.

Option 3 is the only path that preserves the framework's "anyone can verify the numbers" property while making unclaimed rewards visible. The cost is mutable storage on a balance adapter — a deviation from the framework convention captured in [ADR 0005](0005-aave-safety-module-hardcoded-immutable.md).

## Decision

Ship `MerklRewardsAssistedBalanceAdapter` (`src/balances/AssistedBalanceAdapters/MerklRewardsAssistedBalanceAdapter.sol`) as the **second documented mutable adapter**, scoped narrowly to a **proof-verified per-(user, token) allocation cache**. Concretely:

- Storage: `mapping(address user => mapping(address token => CachedAllocation { uint256 cumulativeAmount, bytes32 root, uint64 submittedAt }))` plus a per-(user, token) `CampaignShare[]` breakdown and a per-user token-enumeration list.
- Mutators (`onlyRole(ASSISTANT_ROLE)` — originally `onlyOwner`; migrated to the assisted-family AccessControl model, see [ADR 0015](0015-assisted-balance-adapter-family.md)):
  - `submitProofs(user, Allocation[])` — submits the user's **complete** allocation set, which **replaces** the user's prior cached token set entirely (an omitted token is dropped). Each `Allocation { address token, uint256 cumulativeAmount, bytes32[] proof, CampaignShare[] campaigns }` is verified by recomputing the leaf `keccak256(abi.encode(user, token, cumulativeAmount))` against `Distributor.getMerkleRoot()` using a faithful copy of Merkl's `_verifyProof` (sorted-pair, `keccak256(abi.encode(a, b))` — *not* OpenZeppelin's `MerkleProof`, which uses `abi.encodePacked`). Reverts on invalid proof, zero root, amount regression below the cached value within the list, or a campaign breakdown that does not sum to the proof-verified per-token total.
  - `submitProofsBatch(address[] users, Allocation[][] allocs)` — gas-amortized loop; each user's list replaces that user's cached set.
  - `clearAllocation(user, token)` — idempotent garbage collection.
- Reads: `getAdapterBalanceForAsset(account, asset)` returns `cumulativeAmount - claimed[account][asset].amount`, clamped at 0, **only when** the cached `root` matches the current `Distributor.getMerkleRoot()`. Stale-cache policy is conservative: if the root has rotated, return 0 until a fresh proof is submitted. No extrapolation off cumulative-monotonicity assumptions.
- `underlyingAssetsSupported()` returns an empty array. Merkl's reward-token universe is open and not enumerable at deploy time; the interface explicitly allows empty here. NAV iterates adapters with `assetFilter == address(0)` and the adapter uses `_userTokens[user]` for per-account enumeration.
- Roles are set once in the constructor: `DEFAULT_ADMIN_ROLE` (administers `ASSISTANT_ROLE`) and an optional initial `ASSISTANT_ROLE` holder, both defaulting to the OIV Safe — the same multisig that holds `MANAGER` on `NAVCalculator`. Role grants/revokes flow through OZ `AccessControl`; there is no `Ownable`.

**Scope of the deviation from ADR 0005's full-immutability convention:** mutable cache state, gated by `onlyRole(ASSISTANT_ROLE)`. *No* mutable parameters (Distributor address, NAVCalculator address, and the identity fields are all immutable). *No* upgrade path. *No* admin-injected amounts — every mutation is proof-verified against the on-chain root.

## Consequences

**Positive:**

- NAV correctly counts unclaimed Merkl rewards once a bot submits proofs. The accounting is end-to-end auditable: anyone can re-run the proof verification against the on-chain root and confirm the cached amount is exactly what the merkle tree says.
- The adapter inherits Merkl's security model directly. If Merkl's multisig publishes a malicious tree, our adapter reflects that — same trust assumption as users who claim against that tree. We do not introduce *additional* trust beyond what Merkl already requires.
- The `ASSISTANT_ROLE` holder cannot inflate balances, redirect rewards to other addresses, or change historical values. Their power is bounded to "submit a valid proof" or "decline to submit a valid proof." Failure mode is strictly *under-counting* (NAV ≤ true), never over-counting.
- Stale-cache policy is conservative and decision-free at read time: root rotated → return 0. No need for the adapter to reason about Merkl's monotonicity invariants; it relies only on the on-chain root as authority.
- One contract per chain. Same constructor args (Distributor address is canonical at `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae` everywhere).

**Negative / things to watch:**

- Assistant trust extends to *completeness*: if the `ASSISTANT_ROLE` holder stops running the proof-submission bot (or refuses to submit proofs for specific accounts), NAV under-reports those accounts. The Iron Law that the assistant cannot inflate balances is preserved, but the assistant can selectively starve the cache. Mitigation in v1: deploy the bot inside Karpatkey ops with the same SLA as the rest of the NAV stack; document the failure mode in operational runbooks. Future enhancement: open `submitProofs` to anyone (permissionless mode) once we are comfortable with the spam / storage griefing surface.
- Roots rotate ~every 8 hours (with a 1–2h dispute window). The bot must re-submit at least that frequently or the cache reads as 0. This is a known operational obligation, not a design defect.
- The adapter is the **second mutable balance adapter**. Reviewers, auditors, and future contributors must remember that the immutability-exception history now spans two adapters: `AaveV3SafetyModule` (none, fully immutable per ADR 0005 — listed as the "documented exception" historically but no longer mutable) and `MerklRewardsAssisted` (this one, the *actual* exception going forward). CLAUDE.md and `src/balances/BALANCE_ADAPTERS.md` are updated to reflect the new wording.
- Storage growth is per-(user, token) pair the bot has ever cached. Each `submitProofs` call replaces a user's whole token set (dropping omitted tokens), and `clearAllocation` exists as an explicit cleanup primitive; expect the operator runbook to call it whenever a (user, token) reaches `cumulativeAmount == claimed`.
- Merkl's `_verifyProof` uses `abi.encode` (32-byte padded) rather than `abi.encodePacked` like OpenZeppelin's `MerkleProof`. The adapter MUST replicate the exact sibling-combination rule. Unit tests build synthetic 1-, 2-, and 4-leaf trees with the same hashing convention and exhaustively cover the verification math; any future drift is caught at the unit-test layer.

## Cache-free preview (added later)

Unclaimed positions are also queryable **live without feeding the cache** via the family's universal read
`previewPositions(address account, bytes calldata data)` (on `IAttestedBalanceAdapter`; ADR 0022). Merkl decodes
`data` as `abi.encode(Allocation[])`, verifies each **caller-supplied** proof against the live Distributor root, and
values it with the identical `cumulative − claimed` math the write path uses — shared via the
`_checkProofAndCampaigns` + `_unclaimedFrom` + `_buildTokenLegs` helpers, so the preview's proof + campaign-shape
checks and valuation are identical to the write path's. (Entry *acceptance* still differs by design: submit adds a
cache-only monotonicity check, `AmountRegression`; the preview rejects duplicate tokens and a zero account.) The
trust-minimized guarantee is unchanged — proof-verified, under-report-only — and it writes no
storage and does not affect the NAV read (`getAdapterPositions`, which continues to read the agent-fed cache). It
returns NAV-shaped legs and skips tokens not yet registered on NAVCalculator. This is an *extra* for a portal /
frontend / third party that computes Merkl proofs off-chain; it does **not** reduce the agent's role: NAV coverage
still depends on the keeper feeding the cache. The proof data is typed as opaque `bytes` on the interface so the same
read serves any future attested adapter (Santi, 2026-08-26).

## Trust model summary

> **Superseded — historical (original role-gated v1).** The table below and Alternatives #1 describe the original
> `ASSISTANT_ROLE`/`DEFAULT_ADMIN_ROLE` design. The shipped adapter is **permissionless** (no roles): read
> `ASSISTANT_ROLE` as "any caller" and `DEFAULT_ADMIN_ROLE` as "n/a" throughout — proof-verification, not a role, is
> the integrity guarantee, and Alternatives #1 (permissionless submit) was adopted. See the **2026-07 amendment** at the
> top of this ADR for the current model.

| Capability | Who | Bound by |
|---|---|---|
| Submit valid proofs | `ASSISTANT_ROLE` only | On-chain `getMerkleRoot()` — cannot fabricate amounts |
| Refuse to submit / submit stale | `ASSISTANT_ROLE` | Causes NAV under-count only; never over-count |
| Grant / revoke `ASSISTANT_ROLE` | `DEFAULT_ADMIN_ROLE` | OZ `AccessControl`; no effect on cached amounts |
| Override the merkle root | nobody on our side | Distributor is third-party (Angle Labs); same trust as users who claim |
| Read NAV | anyone | Pure view; deterministic from on-chain state + cache |
| Clear stale cache | `ASSISTANT_ROLE` | Idempotent; no impact on correctness |

## Alternatives considered

1. **Permissionless `submitProofs` (anyone can call).** Strictly more trust-minimized — completeness no longer depends on a designated assistant. Rejected for v1 due to spam / storage griefing risk: any attacker can pay gas to populate `(user, token)` entries for arbitrary users, growing the per-user list without bound. A future v2 (with rate-limiting, deposit-and-refund, or per-user cap) should re-open this. The current role-gated shape is reversible: a future ADR can drop the `onlyRole(ASSISTANT_ROLE)` guard and add the appropriate griefing defense.
2. **Hardcoded reward-token list (mirror ADR 0005's pattern).** Rejected because Merkl's universe of distributed tokens is open and changes campaign-by-campaign. Hardcoding would force per-campaign redeploys and miss new tokens between deploy windows.
3. **Adapter-as-claimer (have the adapter call `Distributor.claim` itself).** Rejected. `claim` is state-changing, transfers tokens, and would have to handle held inventory. Mixes accounting with custody. Out of scope for a balance adapter.
4. **Trust monotonicity to extrapolate cached values across root rotations.** Merkl's tree generator guarantees per-(user, token) cumulative amounts are monotonic, so a cached value from an old root is a valid *lower bound* on the current allocation. Rejected because (a) it bakes a Merkl-design assumption into our adapter rather than reading authority from on-chain state, and (b) under-counting is already the conservative direction we've chosen for failure modes — no need to extrapolate.

## Reference

> The refs below are the **current** (post-amendment) locations — the `attested` family (see [ADR 0022](0022-attested-balance-adapter-family.md)). The original ship lived under `AssistedBalanceAdapters/` with an `admin`/`assistant` ctor; both are superseded (see the amendment at the top).

- Adapter: `src/balances/AttestedBalanceAdapters/MerklRewardsAttestedBalanceAdapter.sol`
- Tests: `test/balances/AttestedBalanceAdapters/MerklRewardsAttestedBalanceAdapter.t.sol` (unit, including synthetic merkle trees), `test/balances/AttestedBalanceAdapters/fork/MerklRewardsAttestedBalanceAdapter.fork.t.sol` (Mainnet integration sanity)
- Merkl Distributor source (verified leaf encoding, `_verifyProof`, `getMerkleRoot`): https://github.com/AngleProtocol/merkl-contracts/blob/main/contracts/Distributor.sol
- Merkl API (proof source for the bot): `https://api.merkl.xyz/v4/users/{address}/rewards?chainId={cid}`
- Deploy schema: `script/config/contracts-deployment-config/balance-adapters/<id>.json` `MerklRewards.constructor` — exactly one key, `distributor`; `navCalculator` is supplied by the deploy script. There are **no** `protocol`/`positionId` config keys: position identity is derived on-chain (`protocolBrand`/`protocolId`/`protocolSubId` are `ProtocolIds.MERKL` constants and `positionId` is hardcoded `abi.encode(DISTRIBUTOR)`), so adding such keys to a new chain's config would configure nothing. Permissionless — **no** `admin`/`assistant` args either (that was the superseded role-gated ship).
- Operator's guide for the proof-submission bot: [`docs/operations/merkl-proof-submitter.md`](../operations/merkl-proof-submitter.md)
- Operational follow-ups (NOT in this PR): bot implementation, per-chain enablement + deploy/registration, price feeds for new reward tokens. (**Permissionless mode is no longer a follow-up — it SHIPPED**, and is the central change this ADR's 2026-07 amendment records. Alternative 1's objection to it was withdrawn there. Do not provision an `ASSISTANT_ROLE` grant or Safe wiring for this adapter: the constructor is `(distributor_, navCalculator_)`, there is no AccessControl, and the feeder is a plain funded keeper EOA.)
- Open design calls raised by review and awaiting the user (documented under "Known gaps" in the operator runbook): cache-slot squatting / un-evictable live entries at `MAX_TOKENS_PER_USER`; and the keeper's "already current" skip being unable to see a fabricated campaign split.
