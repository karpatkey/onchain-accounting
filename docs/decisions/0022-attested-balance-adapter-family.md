# 0022 — Attested balance-adapter family (proof-verified, agent-fed cache)

Status: accepted

> Peer ADRs: the **assisted** family — [ADR 0015](0015-assisted-balance-adapter-family.md) + [ADR 0018](0018-assistant-fed-assisted-balance-adapters.md) — and the meta family ([ADR 0010](0010-meta-balance-adapters.md)). Immutability-exception context: [ADR 0005](0005-aave-safety-module-hardcoded-immutable.md). The first (and currently only) member is the Merkl rewards adapter — protocol-specific rationale in [ADR 0007](0007-merkl-trust-minimized-cache.md).

## Context

A minority of balance adapters cannot derive a position from on-chain state alone — the data needed to *locate or value* the position is not readable from a `view` without external help. The **assisted** family (ADR 0015/0018) covers one shape of this: positions keyed by per-account **coordinates** the protocol does not index (ether.fi/StakeWise withdrawal tickets, Nexus staking NFTs). Its trust model is: cache **coordinates only, never amounts**; value every read **live on-chain**; **re-verify ownership per read** — fed by a `msg.sender`-keyed delegatecall assistant (so the adapter sees `msg.sender = the owner`).

**Merkl rewards are categorically different and do not fit that model.** Merkl (Angle Labs) distributes rewards via an **off-chain** merkle tree; the on-chain Distributor stores only cumulative *claimed* amounts + the current root. An account's *allocation* is an **amount that lives off-chain** and is **not derivable or valuable on-chain** — there is no coordinate to cache and value live. So the assisted invariant ("coordinates only, value live") cannot apply: the adapter must cache a **proof-verified amount**, and an independent **off-chain agent** (a keeper, not the owner) must feed it on behalf of many accounts. This is a distinct, recurring shape with its own safety argument, and it had no name or shared marker.

## Decision

Introduce a fourth balance-adapter family, peer to plain `BalanceAdapter`s, meta-adapters (ADR 0010), and the assisted family (ADR 0015/0018):

- **`IAttestedBalanceAdapter`** (`is IBalanceAdapter`) — a marker interface (ERC-165) identifying the family and exposing the universal mutator (stale-gated `clearAccount(address)`) **and a universal read (`previewPositions(address account, bytes calldata data)`)**. It deliberately does **not** prescribe the per-protocol `submit` surface (typed element shape + proof), because that differs by protocol — but the preview's proof data is opaque `bytes` (each member `abi.decode`s it into its own shape), so a single read signature serves every attested adapter.
- The family is named **attested** because its defining trait is that **every write carries a protocol-specific validity proof verified on-chain** (an *attestation*) — integrity comes from the proof, not from who submitted or from live-ownership re-verification.

**Trust model / invariant (what makes it safe):**
1. **Permissionless, submit-on-behalf-of.** The submit mutator takes an explicit `account` and is callable by anyone — no roles, no `AccessControl`, no `delegatecall` assistant. One off-chain agent feeds many tracked accounts.
2. **Proof-verified — of the proof-bound VALUE, and only that.** A write only lands if its proof validates against the protocol's live root (e.g. Merkl `Distributor.getMerkleRoot()`), so a faulty or malicious feeder can only ever cache an account's **real** figure — **under-report, never over-report** on the number. **The attestation does not extend to auxiliary metadata a member caches beside that value.** Merkl's `campaignId`/`subCampaignId` and the per-campaign split are submitter-controlled: the proof binds the per-token cumulative and the contract checks only that the shares SUM to it, so position *identity* is not attested even though the *amount* is. **Rule for new members: state explicitly which cached fields the proof commits to, and treat every other cached field as attacker-controlled.**
3. **Per-element upsert — never suppress.** A submit **adds or refreshes** the elements it carries and **leaves omitted elements untouched**; it can never drop a live entry. Removal is only via the **stale-gated** `clearAccount` / a per-protocol per-element clear (which revert while any entry is still live). Together these mean a third party can neither inflate an account's balance nor suppress it. *(This upsert rule is load-bearing: an earlier "clear-then-store whole list" draft let anyone wipe a victim's live rewards with an empty submit — see ADR 0007's amendment. Upsert closes that.)*
4. **Stale reads → 0.** Whenever a cached entry's root ≠ the protocol's live root, the read returns 0 (conservative), rather than extrapolating across a root rotation.

These adapters are documented exceptions to the immutability rule (like the assisted family; cf. ADR 0005) — narrowly-scoped mutable cache state, no admin-injected amounts, no upgrade path.

**First member:** `MerklRewardsAttestedBalanceAdapter` (`src/balances/AttestedBalanceAdapters/`), constructor `(distributor, navCalculator)`, permissionless `submitProofs(user, Allocation[])` / `submitProofsBatch`. See ADR 0007.

## Attested vs assisted (why they are separate families)

| | **Assisted** (ADR 0015/0018) | **Attested** (this ADR) |
|---|---|---|
| Caches | coordinates only, **never amounts** | a **proof-verified amount** |
| Valued | **live on-chain** each read | the cached (proven) amount, minus on-chain `claimed`; 0 if stale |
| Fed by | the **owner**, via a `msg.sender`-keyed delegatecall assistant | an independent **agent**, submit-**on-behalf-of** (explicit `account`), permissionless |
| Integrity from | `msg.sender`-keying + live ownership re-verification | the **on-chain proof** carried by every write |
| Suppression-safe via | per-element `msg.sender`-keyed removal | per-element **upsert** (never drops omitted) + stale-gated clear |
| Under-report-only via | value-live + re-verify | proof-verification + stale-root→0 |

## Consequences

- On-chain identifiability: `supportsInterface(type(IAttestedBalanceAdapter).interfaceId)` marks the family (it is NOT an `IAssistedBalanceAdapter` — it advertises neither that marker nor `ASSISTANT_ROLE`).
- Deploy: a plain immutable adapter (CREATE via `04_DeployBalanceAdapters`), **no assistant contract** and **no role grant** — unlike the assisted family. Registered on `NAVCalculator` like any balance adapter.
- Correctness depends on agent **freshness** (a root rotation reads 0 until the agent resubmits) — an intentional under-count tradeoff, not a bug; documented in the operational runbook.
- Read gas is bounded per account by a family-member cap (Merkl: `MAX_TOKENS_PER_USER`), since the read loop iterates the cached element set. Every cached element carries a valid proof — but **only of the field the proof commits to**. For Merkl that is the per-token cumulative amount, so the cache can never hold a *token* the account does not really have a leaf for; it **can** hold campaign sub-elements the account does not really own, because the proof does not bind them. Read the next bullet before sizing anything off this one.
- **A per-element cap is not automatically the leg bound**, and a family member must state its real one. Merkl's read emits one leg per cached *campaign share*, so its bound is the PRODUCT `MAX_TOKENS_PER_USER × MAX_CAMPAIGNS_PER_TOKEN` = **512 legs** (64 × 8), never either cap alone. This matters because proof-bounding is only as tight as what the proof actually commits to: Merkl's proof binds the per-token cumulative total but **not** the campaign split (only the shares' sum is checked), so the campaign multiplier is third-party amplifiable — anyone holding an account's public per-token proof can inflate a real token's leg count 8×. **Rule for new members: identify which parts of a cached element the proof does NOT commit to, and treat those as attacker-controlled when sizing the read.**
  - **Size the product against GAS, not against arithmetic.** An over-large leg count cannot produce a *wrong* figure here — amounts are proof-bounded, the share sum is checked arithmetic, and `mulDiv` floors — it produces an *unaffordable* one. Read cost is strongly super-linear in legs (measured on the Merkl member at 104 registered assets: 4,183,404 gas at 256 legs, 10,341,288 at 512, 30,005,724 at 1024, 98,675,920 at 2048 — each doubling costing 2.47×, 2.90×, 3.29×). An earlier 8192-leg bound was therefore order 1e9 gas, which no read could pay; 512 is ~10.3M worst case.
  - **Correction, previously stated the other way:** an inflated split *can* be undone within a root epoch. Removal is not the only route — the per-protocol submit is an upsert that replaces the cached breakdown wholesale, so re-submitting the same proof with the correct (or empty) breakdown repairs it in one transaction, at the same root, callable by anyone. The stale-gate blocks *deletion* of a live entry; it does not block *refreshing* one. The earlier text said this could not be undone, which would have sent an incident responder to de-register the adapter — dropping every account's value for that protocol — when one submit would have fixed it.
- Read-path failures are loud, not silent, and that is worth knowing when choosing caps: `PriceFeedLib._getAdapterPositions` forwards a stipend and classifies a bubbled out-of-gas via `GasStipendLib.exhausted`, so an over-large fan-out reverts `AdapterGasExhausted` and takes down the account's **whole** NAV read rather than just dropping this adapter. (A plain revert, by contrast, still fails open to an empty position set — a silent under-report.)
  - **That is what happens to an UNISOLATED member. A member may contain it, and Merkl now does.** Valuing each element in its own stipended `try … {gas: stipend}` frame turns both failures into the loss of that one element instead of the whole set (plain revert) or the whole account read (exhaustion). Merkl **drops** the failing element rather than re-raising, and the licence for that is narrow: it emits credit legs exclusively (`positionKind` is always `Rewards`, `isDebt` never set), so a dropped leg can only make NAV *smaller*. `AssistedCoordCache` re-raises `CoordinateGasExhausted` instead precisely because it is a **base** a future debt-emitting member could inherit, where a silently dropped debt leg would make NAV *larger*. **Rule for new members: isolate per element, then choose drop only if the member cannot emit a debt leg — otherwise raise.**
  - Isolation and the cap product are **not substitutes**: stipends partition read cost, they do not shrink it, so an isolated-but-oversized fan-out is still unaffordable; and a bounded-but-unisolated one still loses the whole set to a single failing element. Members need both.
- **Universal cache-free preview — `previewPositions(address account, bytes calldata data)`.** The interface carries a
  stateless, account-agnostic `view` that verifies **caller-supplied** proofs against the live root and returns
  positions **without touching the cache** — an *extra* read for a portal / frontend / third party that has proofs
  off-chain and wants a live answer without waiting for the agent. It writes nothing and has no effect on the NAV read
  (`getAdapterPositions`, which still reads the agent-fed cache). The proof data is **opaque `bytes` on the interface**
  (each member `abi.decode`s it into its own shape — Merkl: `Allocation[]`), so the single signature serves every
  attested adapter, present and future, with `bytes` being whatever the protocol needs. Members reuse their own verify
  + value helpers (so the preview's proof + campaign-shape validation and valuation are identical to the write path's —
  each path may still apply its own extra acceptance rules, e.g. a submit's cache-only monotonicity check), are
  fail-loud on an invalid proof, and
  bound the returned set by the same per-account caps. (This deliberately supersedes an earlier draft that kept the
  preview off the marker as "protocol-specific": typing the data as `bytes` makes one interface method generic without
  losing per-member decoding.)
