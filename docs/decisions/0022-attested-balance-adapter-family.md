# 0022 — Attested balance-adapter family (proof-verified, agent-fed cache)

Status: accepted

> Peer ADRs: the **assisted** family — [ADR 0015](0015-assisted-balance-adapter-family.md) + [ADR 0018](0018-assistant-fed-assisted-balance-adapters.md) — and the meta family ([ADR 0010](0010-meta-balance-adapters.md)). Immutability-exception context: [ADR 0005](0005-aave-safety-module-hardcoded-immutable.md). The first (and currently only) member is the Merkl rewards adapter — protocol-specific rationale in [ADR 0007](0007-merkl-trust-minimized-cache.md).

## Context

A minority of balance adapters cannot derive a position from on-chain state alone — the data needed to *locate or value* the position is not readable from a `view` without external help. The **assisted** family (ADR 0015/0018) covers one shape of this: positions keyed by per-account **coordinates** the protocol does not index (ether.fi/StakeWise withdrawal tickets, Nexus staking NFTs). Its trust model is: cache **coordinates only, never amounts**; value every read **live on-chain**; **re-verify ownership per read** — fed by a `msg.sender`-keyed delegatecall assistant (so the adapter sees `msg.sender = the owner`).

**Merkl rewards are categorically different and do not fit that model.** Merkl (Angle Labs) distributes rewards via an **off-chain** merkle tree; the on-chain Distributor stores only cumulative *claimed* amounts + the current root. An account's *allocation* is an **amount that lives off-chain** and is **not derivable or valuable on-chain** — there is no coordinate to cache and value live. So the assisted invariant ("coordinates only, value live") cannot apply: the adapter must cache a **proof-verified amount**, and an independent **off-chain agent** (a keeper, not the owner) must feed it on behalf of many accounts. This is a distinct, recurring shape with its own safety argument, and it had no name or shared marker.

## Decision

Introduce a fourth balance-adapter family, peer to plain `BalanceAdapter`s, meta-adapters (ADR 0010), and the assisted family (ADR 0015/0018):

- **`IAttestedBalanceAdapter`** (`is IBalanceAdapter`) — a marker interface (ERC-165) identifying the family and exposing the one universal mutator, the stale-gated `clearAccount(address)`. It deliberately does **not** prescribe the per-protocol `submit` surface (element shape + proof), because that differs by protocol.
- The family is named **attested** because its defining trait is that **every write carries a protocol-specific validity proof verified on-chain** (an *attestation*) — integrity comes from the proof, not from who submitted or from live-ownership re-verification.

**Trust model / invariant (what makes it safe):**
1. **Permissionless, submit-on-behalf-of.** The submit mutator takes an explicit `account` and is callable by anyone — no roles, no `AccessControl`, no `delegatecall` assistant. One off-chain agent feeds many tracked accounts.
2. **Proof-verified.** A write only lands if its proof validates against the protocol's live root (e.g. Merkl `Distributor.getMerkleRoot()`), so a faulty or malicious feeder can only ever cache an account's **real** data — **under-report, never over-report**.
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
- Read gas is bounded per account by a family-member cap (Merkl: `MAX_TOKENS_PER_USER`), since the read loop iterates the cached element set; every cached element is proof-verified, so the cache can never hold an element the account does not really own.
- **A per-element cap is not automatically the leg bound**, and a family member must state its real one. Merkl's read emits one leg per cached *campaign share*, so its bound is `MAX_TOKENS_PER_USER × MAX_CAMPAIGNS_PER_TOKEN` = **8192 legs**, not 256. This matters because proof-bounding is only as tight as what the proof actually commits to: Merkl's proof binds the per-token cumulative total but **not** the campaign split (only the shares' sum is checked), so the campaign multiplier is third-party amplifiable — anyone holding an account's public per-token proof can inflate a real token's leg count 32×, and cannot be undone within a root epoch because live entries are un-clearable by design. **Rule for new members: identify which parts of a cached element the proof does NOT commit to, and treat those as attacker-controlled when sizing the read.**
- Read-path failures are loud, not silent, and that is worth knowing when choosing caps: `PriceFeedLib._getAdapterPositions` forwards a stipend and classifies a bubbled out-of-gas via `GasStipendLib.exhausted`, so an over-large fan-out reverts `AdapterGasExhausted` and takes down the account's **whole** NAV read rather than just dropping this adapter. (A plain revert, by contrast, still fails open to an empty position set — a silent under-report.)
