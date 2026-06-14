# 0006 — Merkl rewards adapter: owner-gated, proof-verified, trust-minimized cache

**Status:** accepted

## Context

Merkl (Angle Labs) distributes rewards via off-chain merkle trees. The on-chain Distributor at `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae` (canonical address on every supported EVM chain) only stores **claimed** amounts: `mapping(address user => mapping(address token => Claim { uint208 amount, uint48 timestamp, bytes32 merkleRoot }))`. To learn a user's *unclaimed* allocation you need the merkle leaf and proof from the off-chain Merkl API — the contract has no view function for it.

Without a Merkl adapter, NAV silently under-reports any portfolio that earns Merkl emissions (ARB DRIP, MORPHO campaigns, ANGLE, OP grants, etc.) until those rewards are claimed and land in the wallet (where `ERC20DefaultAdapter` picks them up). Building a Merkl-aware adapter bumps into a structural problem: a balance adapter is a `view` contract, but the data we need lives off-chain. Several options are on the table:

1. **Don't build the adapter.** Status quo. NAV under-reports; downstream products either tolerate the gap or claim more aggressively to materialize rewards in-wallet.
2. **Trust the off-chain bot to inject *amounts* into the adapter.** Simple, but the bot owner could quietly inflate or suppress reported balances. Defeats the auditability purpose.
3. **Trust the off-chain bot to inject *merkle proofs*; verify on-chain against the live `Distributor.getMerkleRoot()`.** The bot can only cache truthful values, because invalid proofs revert at the contract. The bot's owner cannot fabricate amounts even with full custody of the bot's key. NAV becomes deterministically derivable from `(merkle root currently published by Merkl, last cached proof, claimed[user][token].amount)` — auditable end-to-end.

Option 3 is the only path that preserves the framework's "anyone can verify the numbers" property while making unclaimed rewards visible. The cost is mutable storage on a balance adapter — a deviation from the framework convention captured in [ADR 0005](0005-aave-safety-module-hardcoded-immutable.md).

## Decision

Ship `MerklRewardsBalanceAdapter` (`src/balances/protocols/MerklRewards.sol`) as the **second documented mutable adapter**, scoped narrowly to a **proof-verified per-(user, token) allocation cache**. Concretely:

- Storage: `mapping(address user => mapping(address token => CachedAllocation { uint256 cumulativeAmount, bytes32 root, uint64 submittedAt }))` plus a per-user enumeration list.
- Mutators (`onlyOwner`):
  - `submitProof(user, token, cumulativeAmount, proof)` — verifies the leaf `keccak256(abi.encode(user, token, cumulativeAmount))` against `Distributor.getMerkleRoot()` using a faithful copy of Merkl's `_verifyProof` (sorted-pair, `keccak256(abi.encode(a, b))` — *not* OpenZeppelin's `MerkleProof`, which uses `abi.encodePacked`). Reverts on invalid proof, zero root, or amount regression below the cached value.
  - `submitProofBatch(...)` — gas-amortized loop.
  - `clearAllocation(user, token)` — idempotent garbage collection.
- Reads: `getAdapterBalanceForAsset(account, asset)` returns `cumulativeAmount - claimed[account][asset].amount`, clamped at 0, **only when** the cached `root` matches the current `Distributor.getMerkleRoot()`. Stale-cache policy is conservative: if the root has rotated, return 0 until a fresh proof is submitted. No extrapolation off cumulative-monotonicity assumptions.
- `underlyingAssetsSupported()` returns an empty array. Merkl's reward-token universe is open and not enumerable at deploy time; the interface explicitly allows empty here. NAV iterates adapters with `assetFilter == address(0)` and uses `_userTokens[user]` for per-account enumeration.
- Owner is set once in the constructor (the OIV Safe — same multisig that holds `MANAGER` on `NAVCalculator`). `Ownable.transferOwnership` is supported but expected to remain unused outside of multisig migrations.

**Scope of the deviation from ADR 0005's full-immutability convention:** mutable cache state, gated by `onlyOwner`. *No* mutable parameters (Distributor address, NAVCalculator address, identity fields (`protocolId`, `positionId`) are all immutable). *No* upgrade path. *No* admin-injected amounts — every mutation is proof-verified against the on-chain root.

## Consequences

**Positive:**

- NAV correctly counts unclaimed Merkl rewards once a bot submits proofs. The accounting is end-to-end auditable: anyone can re-run the proof verification against the on-chain root and confirm the cached amount is exactly what the merkle tree says.
- The adapter inherits Merkl's security model directly. If Merkl's multisig publishes a malicious tree, our adapter reflects that — same trust assumption as users who claim against that tree. We do not introduce *additional* trust beyond what Merkl already requires.
- The owner cannot inflate balances, redirect rewards to other addresses, or change historical values. Their power is bounded to "submit a valid proof" or "decline to submit a valid proof." Failure mode is strictly *under-counting* (NAV ≤ true), never over-counting.
- Stale-cache policy is conservative and decision-free at read time: root rotated → return 0. No need for the adapter to reason about Merkl's monotonicity invariants; it relies only on the on-chain root as authority.
- One contract per chain. Same constructor args (Distributor address is canonical at `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae` everywhere).

**Negative / things to watch:**

- Owner trust extends to *completeness*: if the owner stops running the proof-submission bot (or refuses to submit proofs for specific accounts), NAV under-reports those accounts. The Iron Law that the owner cannot inflate balances is preserved, but the owner can selectively starve the cache. Mitigation in v1: deploy the bot inside Karpatkey ops with the same SLA as the rest of the NAV stack; document the failure mode in operational runbooks. Future enhancement: open `submitProof` to anyone (permissionless mode) once we are comfortable with the spam / storage griefing surface.
- Roots rotate ~every 8 hours (with a 1–2h dispute window). The bot must re-submit at least that frequently or the cache reads as 0. This is a known operational obligation, not a design defect.
- The adapter is the **second mutable balance adapter**. Reviewers, auditors, and future contributors must remember that two adapters now have admin surface area: `AaveV3SafetyModule` (none, fully immutable per ADR 0005 — listed as the "documented exception" historically but no longer mutable) and `MerklRewards` (this one, the *actual* exception going forward). CLAUDE.md and `src/balances/BALANCE_ADAPTERS.md` are updated to reflect the new wording.
- Storage growth is per-(user, token) pair the bot has ever cached. `clearAllocation` exists as the cleanup primitive; expect the operator runbook to call it whenever a (user, token) reaches `cumulativeAmount == claimed`.
- Merkl's `_verifyProof` uses `abi.encode` (32-byte padded) rather than `abi.encodePacked` like OpenZeppelin's `MerkleProof`. The adapter MUST replicate the exact sibling-combination rule. Unit tests build synthetic 1-, 2-, and 4-leaf trees with the same hashing convention and exhaustively cover the verification math; any future drift is caught at the unit-test layer.

## Trust model summary

| Capability | Who | Bound by |
|---|---|---|
| Submit valid proofs | owner only | On-chain `getMerkleRoot()` — cannot fabricate amounts |
| Refuse to submit / submit stale | owner | Causes NAV under-count only; never over-count |
| Override the merkle root | nobody on our side | Distributor is third-party (Angle Labs); same trust as users who claim |
| Read NAV | anyone | Pure view; deterministic from on-chain state + cache |
| Clear stale cache | owner | Idempotent; no impact on correctness |

## Alternatives considered

1. **Permissionless `submitProof` (anyone can call).** Strictly more trust-minimized — completeness no longer depends on a designated owner. Rejected for v1 due to spam / storage griefing risk: any attacker can pay gas to populate `(user, token)` entries for arbitrary users, growing the per-user list without bound. A future v2 (with rate-limiting, deposit-and-refund, or per-user cap) should re-open this. The current owner-gated shape is reversible: a future ADR can drop `onlyOwner` and add the appropriate griefing defense.
2. **Hardcoded reward-token list (mirror ADR 0005's pattern).** Rejected because Merkl's universe of distributed tokens is open and changes campaign-by-campaign. Hardcoding would force per-campaign redeploys and miss new tokens between deploy windows.
3. **Adapter-as-claimer (have the adapter call `Distributor.claim` itself).** Rejected. `claim` is state-changing, transfers tokens, and would have to handle held inventory. Mixes accounting with custody. Out of scope for a balance adapter.
4. **Trust monotonicity to extrapolate cached values across root rotations.** Merkl's tree generator guarantees per-(user, token) cumulative amounts are monotonic, so a cached value from an old root is a valid *lower bound* on the current allocation. Rejected because (a) it bakes a Merkl-design assumption into our adapter rather than reading authority from on-chain state, and (b) under-counting is already the conservative direction we've chosen for failure modes — no need to extrapolate.

## Reference

- Adapter: `src/balances/protocols/MerklRewards.sol`
- Tests: `test/balances/protocols/MerklRewards.t.sol` (unit, 40 tests including synthetic merkle trees), `test/balances/protocols/fork/MerklRewards.fork.t.sol` (Mainnet integration sanity)
- Merkl Distributor source (verified leaf encoding, `_verifyProof`, `getMerkleRoot`): https://github.com/AngleProtocol/merkl-contracts/blob/main/contracts/Distributor.sol
- Merkl API (proof source for the bot): `https://api.merkl.xyz/v4/users/{address}/rewards?chainId={cid}`
- Deploy schema: `script/config/chains/<id>.json` `balanceAdapters.MerklRewards` (`distributor`); owner = `addresses.admin`.
- Operator's guide for the proof-submission bot: [`docs/operations/merkl-proof-submitter.md`](../operations/merkl-proof-submitter.md)
- Operational follow-ups (NOT in this PR): bot implementation, optional permissionless mode (see Alternative 1), price feeds for new reward tokens.
