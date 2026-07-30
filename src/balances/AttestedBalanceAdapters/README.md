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

## Invariant (what makes it safe)

- **Permissionless, submit-on-behalf-of.** The submit mutator takes an explicit `account`; anyone can call it (one
  agent feeds many accounts). No roles, no `AccessControl`, no `delegatecall` assistant.
- **Proof-verified.** A write lands only if its proof validates against the protocol's live root → a faulty/malicious
  feeder can only cache an account's **real** data: **under-report, never over-report**.
- **Upsert, never suppress.** A submit adds/refreshes the elements it carries and **never drops** an omitted one;
  removal is only via the **stale-gated** `clearAccount` / a per-element clear (which revert while any entry is live).
  So a third party can neither inflate nor suppress an account's balance.
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
  `SubmitMerklProofs` automation.

## Adding a member

Implement `IAttestedBalanceAdapter` (+ `IBalanceAdapter`, and `IPositionDescribable` for labels), define the
per-protocol `submit` surface (element shape + its on-chain proof check), uphold the invariant above (upsert; proof
per write; stale→0; stale-gated removal), and register it on `NAVCalculator` like any balance adapter. No assistant
contract and no role grant — unlike the assisted family.
