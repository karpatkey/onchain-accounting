# Nexus Mutual staked NXM — balance-adapter verification

## 1. Adapter under test
`NexusMutualStakingPoolsBalanceAdapter` (`src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsBalanceAdapter.sol`). Reports an account's staked NXM across Nexus Mutual V2 staking pools as NXM-denominated `Staking` (active + expired stake) and `Rewards` legs — emitted **per StakingNFT position** (`positionId = abi.encode(tokenId, poolId)`).

### Inheritance + per-chain scope (Phase 0)
- Implements `IBalanceAdapter` + `IPositionDescribable` directly — a **simple immutable view adapter** (no `Ownable`, no agent, no cache). **Mainnet (1) only** (Nexus Mutual V2 is mainnet).
- **Why a view adapter and not the ADR-0014 agent-fed cache (spike, 2026-06-24):** `StakingNFT` (`0xcafea508…e97f`) is **not** per-owner-enumerable (`tokenOfOwnerByIndex` reverts) and `StakingViewer` (`0xcafea5c7…cF81F`) has **no** staker→tokenIds view (only manager methods + `get*(uint256[] tokenIds)`). That's the same NFT wall as ether.fi/StakeWise — **except** `StakingNFT` is **mint-only** (no `burn`) with a tiny, monotonic `totalSupply` (~280 globally), so live tokenIds are exactly `1..totalSupply`. The adapter therefore self-discovers by scanning `tokenInfo(id) -> (poolId, owner)` over that range — feasible on-chain (ether.fi's ~80k supply made this impossible). No off-chain feeder needed.

### Math branches
- `_ownedTokenIds`: `balanceOf(account)` fast-path first — **`0` ⇒ skip the scan entirely** (the common non-staker case in a NAV fan-out), else collect exactly `min(balanceOf, MAX_POSITIONS_PER_ACCOUNT)` tokens and **stop early** once found (a reverting/absent `balanceOf` falls back to the plain bounded scan). Then `totalSupply()` read (try/catch → 0 ids); scan `tokenInfo` **descending** over `totalSupply..1` (newest ids first — positions cluster at recent ids, so the early-exit triggers sooner), collect `owner == account`; a reverting `tokenInfo` is caught and skipped. There is no fixed scan cap — the loop covers the full live range (`totalSupply` ~280 today); the pathological cost (only-old-id positions, or a `balanceOf` revert) scales with `totalSupply`, and the ADR-0014 agent cache is the escape if global supply ever grows large enough to risk OOG inside a NAV read. `StakingNFT` is not ERC721Enumerable (no owner→tokenIds view), which is why discovery must scan at all.
- `getAdapterPositions`: `assetFilter` mismatch → empty; NXM not registered → empty; else `StakingViewer.getTokens(ids)` (try/catch → empty) → for each token emit `Staking = activeStake + expiredStake` and `Rewards = rewards` (zeros dropped), `positionId = abi.encode(tokenId, poolId)`.
- `getAdapterBalances` / `getAdapterBalanceForAsset` (no-arg): summed NXM total via `getAggregatedTokens(ids)` (try/catch → 0) → `active + expired + rewards`.

## 2. Fork test coverage
`test/balances/AssistedBalanceAdapters/fork/NexusMutualStakingPoolsBalanceAdapter.fork.t.sol` (3 tests, `FOUNDRY_PROFILE=slow`, FORK_BLOCK 25,388,000):
- `realHolder_scanMatchesAggregate` — the adapter's **scan-derived** summed total for the Nexus Safe equals an independent `getAggregatedTokens([180,184,185,186,187])` read (delta 0) **and** the pinned values.
- `realHolder_perNftLegs` — per-NFT `Staking`/`Rewards` legs: 5–10 legs, each `positionId` decodes to a known `(tokenId, poolId)`, and the per-kind sums equal the live aggregate (delta 0).
- `nonStaker_reportsZero` — a non-staking address reports nothing (scan finds no owned ids).

## 3. Unit test coverage
`test/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsBalanceAdapter.t.sol` (mock-only): constructor guards (×5), discovery + summed valuation (owned-only, other-account-excluded, wrong-asset), per-NFT `Staking`+`Rewards` leg identity (`positionId = abi.encode(tokenId, poolId)`), a **two-pool** case yielding distinct positionIds, single-leg (no-rewards / no-stake) and empty cases, asset-filter match/mismatch, unregistered-underlying drop, `getAdapterBalances` shape, the `MAX_POSITIONS_PER_ACCOUNT` cap, a high-id position (beyond the former 5000 bound) still discovered, the `balanceOf` fast-path (zero-balance skips the scan; `balanceOf` revert falls back to the full scan), `try/catch` never-revert on `tokenInfo` / `totalSupply` / `getTokens` / `getAggregatedTokens`, ERC165, `underlyingAssetsSupported`. The mock `StakingViewer` returns per-token structs for exactly the ids the adapter passes, so discovery → valuation is tested end-to-end.

## 4. Adapter formula recap
```
if StakingNFT.balanceOf(account) == 0: return []      // non-staker fast-path, no scan
target = min(StakingNFT.balanceOf(account), MAX_POSITIONS_PER_ACCOUNT)   // (cap if balanceOf reverts)
ids = first `target`, scanning id = StakingNFT.totalSupply() down to 1, of { id : StakingNFT.tokenInfo(id).owner == account }
tokens = StakingViewer.getTokens(ids)            // per-token { tokenId, poolId, activeStake, expiredStake, rewards }
for each t in tokens:
  Staking leg = t.activeStake + t.expiredStake (NXM)   // if > 0
  Rewards leg = t.rewards (NXM)                         // if > 0
  positionId  = abi.encode(t.tokenId, t.poolId) ; isDebt = false
```
NXM (`0xd7c4…Cf3B`) is a registered + priced NAV asset (PR #71), so NAVCalculator prices the legs.

## 5. Cherry-picked account
**Nexus Mutual Safe `0x8e53D04644E9ab0412a8c6bd228C84da7664cFE3`** (a KPK-managed account) holds **5 StakingNFT positions across 5 pools** — tokenIds 180 (pool 2), 184 (pool 8), 185 (pool 22), 186 (pool 11), 187 (pool 5). It is a pure staker (not a pool manager). The ~$3.35M gap = ~74,229.5 NXM staked + ~228 NXM rewards, now surfaced as one Staking (+Rewards) leg per position.

## 6. Case files in this folder
- `case-nexus.json` — addresses, fork block, the real holder + its 5 (tokenId, poolId) positions, the per-NFT legs, ground-truth source, `delta: 0`.

## 7. Expected balances
### 7a. Aggregate detail (FORK_BLOCK 25,388,000)
| Account | Kind | Asset | Amount (summed across 5 positions) | isDebt |
|---|---|---|---|---|
| `0x8e53…cFE3` | Staking (active+expired) | NXM | `74229519750529478080348` (~74,229.5) | false |
| `0x8e53…cFE3` | Rewards | NXM | `228254616240628948835` (~228.25) | false |

### 7b. Per-position legs
One NXM `Staking` leg + one NXM `Rewards` leg **per StakingNFT tokenId** (zeros dropped), keyed by `abi.encode(tokenId, poolId)`; the per-kind sums equal the aggregate above. Nothing if the account stakes nothing.

## 8. Ground-truth cross-check
- **On-chain (fork test):** the adapter's per-NFT legs sum back to `getAggregatedTokens([180,184,185,186,187]).active + expired + rewards`, delta **0**, and the no-arg total getter matches the same. The adapter's scan independently rediscovers those exact 5 ids.
- **Debank:** `nexus` shows "Staked" ≈ $3.35M NXM for this Safe (the "Yield" $250k line is RWIV, covered separately by #95/#103).

## 9. Wiring the live dev-anvil dashboard
Nexus has a live holder (the Safe), so no seeding. NXM must be registered (it is, in the prod asset config).
```bash
bash script/development/anvil/start-forks.sh 1
bash script/development/deploy/deploy.sh 1                       # NAV + Chainlink assets
# register NXM (custom RAMM feed) + deploy NexusMutualStakingPools + addBalanceAdapters, then:
bash script/development/app/sync-app-env.sh 1
# start Next.js and enter 0x8e53D04644E9ab0412a8c6bd228C84da7664cFE3
```
The Safe shows a "Nexus Mutual" group with a per-pool Staking leg (+ Rewards) for each of its 5 positions.

## 10. Test verdict
- Fork: **3/3 pass** (strict delta 0 vs live `getAggregatedTokens`; per-NFT legs sum back to the aggregate). `forge build`/`fmt` clean. Pin: standalone adapter — confirm `LibraryPinConsistency` (CI is the authority).
