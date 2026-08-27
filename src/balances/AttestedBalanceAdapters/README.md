# Attested balance adapters

The **attested** family — the fourth balance-adapter family, peer to plain `BalanceAdapter`s, meta-adapters
([ADR 0010](../../../docs/decisions/0010-meta-balance-adapters.md)), and the assisted family
([ADR 0015](../../../docs/decisions/0015-assisted-balance-adapter-family.md) /
[ADR 0018](../../../docs/decisions/0018-assistant-fed-assisted-balance-adapters.md)). Full rationale:
[ADR 0022](../../../docs/decisions/0022-attested-balance-adapter-family.md).

## What it is

Adapters whose positions **cannot be derived from on-chain state** and whose data is an **amount that lives
off-chain** (so there is no coordinate to cache and value live — that's the assisted family's shape). Instead an
**off-chain agent** feeds the adapter, and **every write carries an on-chain-verified proof** (an *attestation*).

Marker: **`IAttestedBalanceAdapter`** (`is IBalanceAdapter`, `src/balances/IAttestedBalanceAdapter.sol`) — advertises
the family via ERC-165 and the one universal mutator, the stale-gated `clearAccount(address)`.

## The shared base — `AttestedValueCache`

`AttestedValueCache.sol` is the family's abstract base (the peer of `AssistedCoordCache` next door). A new member
implements hooks, not machinery:

```
_liveEpoch()               -> bytes32   what the attestation epoch is (Merkl: getMerkleRoot())
_liveValue(...)            -> uint256   cached figure -> today's amount (Merkl: cumulative - claimed)
_verifyPreviewPayload(...)             decode + verify caller-supplied proofs (the proof scheme)
_assetLegs(...)            -> legs      one asset's value -> PositionBalance[]
_maxAssetsPerAccount()                 the per-account cache cap
_cachedLegCount / _previewLegCount      legs per asset (UPPER BOUND) for scratch-buffer sizing
_deleteMemberState(...)                drop member state alongside the attestation
_protocolBrand/_protocolId/_protocolSubId/_positionKind          typed identity
```

The base owns the `(value, epoch)` cache and its enumeration, stale-reads-zero, the stale-gated clears, the
NAV-version constructor probe, the per-asset gas-isolated read fan-out, the `previewPositions` skeleton with its
duplicate-asset guard, the `IBalanceAdapter` reads, and `_row`.

**Two rules a new member must not work around:**

1. `_upsertAttestation` is the **single point where a number enters the cache**, and it does not inspect a proof —
   it cannot, since the scheme is per-protocol. **Verify before calling it.**
2. The base's per-asset `catch` **drops** the failing asset. That is safe only for a **credit-only** member. A
   member that can emit a **debt** leg must override `_collectLegs` and raise instead, because a silently dropped
   debt leg makes NAV *larger* — the one direction forbidden here.


## Invariant (what makes it safe)

- **Permissionless, submit-on-behalf-of.** The submit mutator takes an explicit `account`; anyone can call it (one
  agent feeds many accounts). No roles, no `AccessControl`, no `delegatecall` assistant.
- **Proof-verified.** A write lands only if its proof validates against the protocol's live root → a faulty/malicious
  feeder can only cache an account's **real proof-bound VALUE**: **under-report, never over-report** on the number.
  The guarantee stops at what the proof commits to — auxiliary metadata cached alongside it (Merkl's campaign ids
  and split, only their SUM checked) is NOT attested and must be documented by the member.
- **Upsert, never suppress.** A submit adds/refreshes the elements it carries and **never drops** an omitted one;
  removal is only via the **stale-gated** `clearAccount` / a per-element clear (which revert while any entry is live).
  So a third party can neither inflate an account's balance nor suppress an entry **already in the cache**. It
  does NOT mean an entry can always get in: admission is capped and fails loud, so a third party holding the
  account's public proofs can squat the cap with low-value elements and keep a valuable one out (Gap 1 in the
  operator runbook) — under-report only, and an open design call rather than a closed guarantee.
- **Stale reads → 0.** A cached entry whose root ≠ the live root reads 0 (no extrapolation across a root rotation).

These adapters are documented exceptions to the immutability rule (cf.
[ADR 0005](../../../docs/decisions/0005-aave-safety-module-hardcoded-immutable.md)): narrow mutable cache state, no
admin-injected amounts, no upgrade path.

## Members

- **`MerklRewardsAttestedBalanceAdapter`** — Merkl (Angle Labs) unclaimed rewards. `submitProofs(user, Allocation[])` /
  `submitProofsBatch` upsert per-`(user, token)` merkle-proof-verified cumulative allocations; a NAV read reports
  `unclaimed = cachedCumulative − Distributor.claimed(user, token)` (0 if the cached root ≠ `Distributor.getMerkleRoot()`).
  Constructor `(distributor, navCalculator)`. Protocol-specific rationale:
  [ADR 0007](../../../docs/decisions/0007-merkl-trust-minimized-cache.md). Off-chain feeder: the kpk-agents
  `SubmitMerklProofs` automation. Implements the family's cache-free `previewPositions(account, bytes)` (decoding
  `bytes` to `Allocation[]`) — see below.

## Cache-free preview (universal read on the interface)

`IAttestedBalanceAdapter` carries one universal read: **`previewPositions(address account, bytes calldata data)` →
`PositionBalance[]`**. It is a **stateless, account-agnostic** `view` that values `account`'s positions from
**caller-supplied** proof data, with no prior submit and **without touching the cache** — each member `abi.decode`s the
opaque `data` into its own proof shape, verifies every proof against the protocol's live root, and values it with the
SAME helpers as the write path, so it can only ever surface the account's real figure (under-report, never
over-report). It writes nothing and has no effect on the NAV read (`getAdapterPositions`, which continues to read the
agent-fed cache). It is an *extra* for a portal / frontend / third party that computes proofs off-chain.

The proof `data` is opaque `bytes` **on purpose**: one signature serves every attested adapter, present and future,
with `data` being whatever that protocol needs ([ADR 0022](../../../docs/decisions/0022-attested-balance-adapter-family.md)).
Members are **fail-loud** (revert on an invalid proof) and bound the returned set by the same per-account caps as the cache.

Merkl decodes `data` as `abi.encode(Allocation[])`, returns NAV-shaped `Rewards` legs (parity with
`getAdapterPositions`), **skips** reward tokens not registered on NAVCalculator (a leg needs the asset metadata), and
reverts on `CampaignSumMismatch` / over-cap campaigns or tokens / a `DuplicateAsset`.

## Adding a member

Implement `IAttestedBalanceAdapter` (+ `IBalanceAdapter`, and `IPositionDescribable` for labels): define the
per-protocol `submit` surface (typed element shape + its on-chain proof check) **and** the universal
`previewPositions(account, bytes)` (decode `bytes` into your proof shape, verify, value — reusing the same helpers as
`submit` so proof + campaign-shape validation and valuation stay identical between the two paths; each may still add
its own extra acceptance rules). Uphold the invariant above (upsert; proof per write; stale→0; stale-gated
removal), and register it on `NAVCalculator` like any balance adapter. No assistant contract and no role grant —
unlike the assisted family.
