# Nexus Mutual staked NXM — balance-adapter verification

## 1. Adapter under test
`NexusStakedNxmBalanceAdapter` (`src/balances/protocols/NexusStakedNxm.sol`). Reports an account's staked NXM across Nexus Mutual V2 staking pools as NXM-denominated `Staking` (active + expired stake) and `Rewards` legs.

### Inheritance + per-chain scope (Phase 0)
- Implements `IBalanceAdapter` + `IPositionDescribable` directly — a **simple immutable view adapter** (no `Ownable`, no agent, no cache). **Mainnet (1) only** (Nexus Mutual V2 is mainnet).
- **Why a view adapter and not the ADR-0014 agent-fed cache (spike, 2026-06-24):** `StakingNFT` (`0xcafea508…e97f`) is **not** per-owner-enumerable (`tokenOfOwnerByIndex` reverts) and `StakingViewer` (`0xcafea5c7…cF81F`) has **no** staker→tokenIds view (only manager methods + `get*(uint256[] tokenIds)`). That's the same NFT wall as ether.fi/StakeWise — **except** `StakingNFT` is **mint-only** (no `burn`) with a tiny, monotonic `totalSupply` (~280 globally), so live tokenIds are exactly `1..totalSupply`. The adapter therefore self-discovers by scanning `tokenInfo(id) -> (poolId, owner)` over that range — feasible on-chain (ether.fi's ~80k supply made this impossible). No off-chain feeder needed.

### Math branches
- `_ownedTokenIds`: `totalSupply()` read (try/catch → 0 ids); scan `tokenInfo(1..min(totalSupply, MAX_TOKEN_SCAN))`, collect `owner == account` up to `MAX_POSITIONS_PER_ACCOUNT`; a reverting `tokenInfo` is caught and skipped. Cost scales with **global** supply (not the account's position count) — bounded by `MAX_TOKEN_SCAN` so the read loop can't OOG (NAV's try/catch wouldn't catch it).
- `_stakeAndRewards`: `getAggregatedTokens(ids)` (try/catch → 0) → `Staking = totalActiveStake + totalExpiredStake`, `Rewards = totalRewards`.
- `getAdapterPositions`: `assetFilter` mismatch → empty; NXM not registered → empty; both amounts 0 → empty; else up to 2 legs (`Staking`, `Rewards`), zeros dropped, `positionId = ""`.

## 2. Fork test coverage
`test/balances/protocols/fork/NexusStakedNxm.fork.t.sol` (3 tests, `FOUNDRY_PROFILE=slow`, FORK_BLOCK 25,388,000):
- `realHolder_scanMatchesAggregate` — the adapter's **scan-derived** total for the Nexus Safe equals an independent `getAggregatedTokens([180,184,185,186,187])` read (delta 0) **and** the pinned values.
- `realHolder_positionLegs` — `Staking`/`Rewards` legs + identity fields on the real holder.
- `nonStaker_reportsZero` — a non-staking address reports nothing (scan finds no owned ids).

## 3. Unit test coverage
`test/balances/protocols/NexusStakedNxm.t.sol` (22 tests, mock-only): constructor guards (×4), discovery + aggregation (owned-only, other-account-excluded, wrong-asset), `Staking`+`Rewards` leg identity, single-leg (no-rewards / no-stake) and empty cases, asset-filter match/mismatch, unregistered-underlying drop, `getAdapterBalances` shape, the `MAX_POSITIONS_PER_ACCOUNT` + `MAX_TOKEN_SCAN` caps, `try/catch` never-revert on `tokenInfo` / `totalSupply` / `getAggregatedTokens`, ERC165, `underlyingAssetsSupported`. The mock `StakingViewer` aggregates exactly the ids the adapter passes, so discovery → valuation is tested end-to-end.

## 4. Adapter formula recap
```
ids = { id in 1..min(StakingNFT.totalSupply(), MAX_TOKEN_SCAN) : StakingNFT.tokenInfo(id).owner == account }
(active, expired, rewards) = StakingViewer.getAggregatedTokens(ids)
Staking leg = active + expired (NXM) ; Rewards leg = rewards (NXM) ; positionId = "" ; isDebt = false
```
NXM (`0xd7c4…Cf3B`) is a registered + priced NAV asset (PR #71), so NAVCalculator prices the legs.

## 5. Cherry-picked account
**Nexus Mutual Safe `0x8e53D04644E9ab0412a8c6bd228C84da7664cFE3`** (a KPK-managed account) holds **5 StakingNFT positions across 5 pools** — tokenIds 180 (pool 2), 184 (pool 8), 185 (pool 22), 186 (pool 11), 187 (pool 5). It is a pure staker (not a pool manager). The ~$3.35M gap = ~74,229.5 NXM staked + ~228 NXM rewards.

## 6. Case files in this folder
- `case-nexus.json` — addresses, fork block, the real holder + its 5 (tokenId, poolId) positions, the legs, ground-truth source, `delta: 0`.

## 7. Expected balances
### 7a. Per-leg detail (FORK_BLOCK 25,388,000)
| Account | Leg | Asset | Amount | type | isDebt |
|---|---|---|---|---|---|
| `0x8e53…cFE3` | Staked NXM (active+expired, 5 pools) | NXM | `74229519750529478080348` (~74,229.5) | Staking | false |
| `0x8e53…cFE3` | Accrued rewards | NXM | `228254616240628948835` (~228.25) | Rewards | false |

### 7b. Per-asset summary
One NXM `Staking` leg + one NXM `Rewards` leg per account = the aggregate across all the account's StakingNFT positions; nothing if it stakes nothing.

## 8. Ground-truth cross-check
- **On-chain (fork test):** `adapter.getAdapterBalanceForAsset(safe, NXM)` **== `getAggregatedTokens([180,184,185,186,187]).active + expired + rewards`**, delta **0**. The adapter's scan independently rediscovers those exact 5 ids.
- **Debank:** `nexus` shows "Staked" ≈ $3.35M NXM for this Safe (the "Yield" $250k line is RWIV, covered separately by #95/#103).

## 9. Wiring the live dev-anvil dashboard
Nexus has a live holder (the Safe), so no seeding. NXM must be registered (it is, in the prod asset config).
```bash
bash script/development/anvil/start-forks.sh 1
bash script/development/deploy/deploy.sh 1                       # NAV + Chainlink assets
# register NXM (custom RAMM feed) + deploy NexusStakedNxm + addBalanceAdapters, then:
bash script/development/app/sync-app-env.sh 1
# start Next.js and enter 0x8e53D04644E9ab0412a8c6bd228C84da7664cFE3
```
The Safe shows a "Nexus Mutual" group with a ~74,229 NXM Staked leg + ~228 NXM Rewards leg.

## 10. Test verdict
- Unit: **22/22 pass**. Fork: **3/3 pass** (strict delta 0 vs live `getAggregatedTokens`). `forge build`/`fmt` clean. Pin: standalone adapter — confirm `LibraryPinConsistency` (CI is the authority).
