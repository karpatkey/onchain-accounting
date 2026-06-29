# Nexus Mutual staked NXM — balance-adapter verification

## 1. Adapter under test
`NexusMutualStakingPoolsAssistedBalanceAdapter` (`src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol`). Reports an account's staked NXM across Nexus Mutual V2 staking pools as NXM-denominated `Staking` (active + expired stake) and `Rewards` legs — emitted **per StakingNFT position** (`positionId = abi.encode(address stakingPool)`, where `stakingPool = StakingViewer.stakingPool(poolId)`; the StakingNFT tokenId rides in the typed `positionInstanceId` on each leg, not in `positionId` and not in the display labels).

### Inheritance + per-chain scope
- Extends `AssistedBalanceAdapter` and implements `IPositionDescribable` — an **assisted (agent-fed) adapter** in the ADR-0015 family, not a plain view adapter. Access control comes from the base (OZ `AccessControl`): `DEFAULT_ADMIN_ROLE` administers roles and `ASSISTANT_ROLE` gates the submit/clear mutators. **Mainnet (1) only** (Nexus Mutual V2 is mainnet).
- **Why agent-fed and not a self-discovering view adapter:** `StakingNFT` (`0xcafea508…e97f`) is **not** per-owner-enumerable (`tokenOfOwnerByIndex` reverts) and `StakingViewer` (`0xcafea5c7…cF81F`) has **no** staker→tokenIds view (only manager methods + `get*(uint256[] tokenIds)`). That's the same NFT wall as ether.fi/StakeWise and Uniswap V3, so it joins the assisted family: an off-chain assistant (holder of `ASSISTANT_ROLE`) submits the account's StakingNFT tokenIds via `submitTokenIds`, and the adapter values each entirely from live on-chain reads, re-verifying ownership on every read. The cache stores **ids only, never amounts** — a faulty or compromised assistant can at worst omit an id (NAV under-counts), never fabricate value.

### Cache and read path
- **`submitTokenIds(account, tokenIds)`** (`ASSISTANT_ROLE`): **replaces** the account's full cached id set (clear then re-add; duplicates dedup). **Reverts** `NotTokenOwner` for any id whose `tokenInfo` owner ≠ `account`, and `TokenIdCacheFull` past `MAX_TOKEN_IDS` (64) — writes are fail-loud and atomic, so a bad list leaves the prior set untouched. `submitTokenIdsBatch`, `clearTokenId`, and `clearAccount` are the other mutators.
- `getAdapterPositions`: `assetFilter` mismatch → empty; account zero → empty; no cached ids → empty; NXM not registered in NAVCalculator → empty. Otherwise, for each cached id it calls `this.tokenLegs(...)` behind a per-NFT try/catch (fail-open id isolation): re-verifies ownership via `StakingNFT.tokenInfo` (transferred/burned ids discarded), reads `StakingViewer.getTokens([id])`, and emits `Staking = activeStake + expiredStake` and `Rewards = rewards` (zero legs dropped), keyed by `positionId = abi.encode(address stakingPool)` with the tokenId in `positionInstanceId`.
- `getAdapterBalances` / `getAdapterBalanceForAsset` (no-arg): summed NXM total over the account's owned, cached ids via `getAggregatedTokens(ids)` (try/catch → 0) → `totalActiveStake + totalExpiredStake + totalRewards`.

## 2. Fork test coverage
`test/balances/AssistedBalanceAdapters/fork/NexusMutualStakingPoolsAssistedBalanceAdapter.fork.t.sol` (3 tests, `FOUNDRY_PROFILE=slow`, FORK_BLOCK 25,388,000). `setUp` submits the Safe's known tokenIds (`[180,184,185,186,187]`) via `submitTokenIds` (test acts as admin + assistant):
- `test_realHolder_scanMatchesAggregate` — the adapter's summed total for the Nexus Safe equals an independent `getAggregatedTokens([180,184,185,186,187])` read (delta 0) **and** the pinned values.
- `test_realHolder_perNftLegs` — per-NFT `Staking`/`Rewards` legs: 5–10 legs, each `positionId` decodes to a deployed staking-pool address (with the tokenId carried in `positionInstanceId`, and the labels asserted to be `["Staking Pools", …]`), and the per-kind sums equal the live aggregate (delta 0).
- `test_nonStaker_reportsZero` — an address with no cached ids reports nothing.

## 3. Unit test coverage
`test/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.t.sol` (mock-only, 30 tests): constructor guards (×5: zero StakingNFT / viewer / underlying / NAV, and StakingNFT not-a-contract), role wiring from constructor args, submitted-tokens summed valuation, unsubmitted-account zero, wrong-asset zero, per-NFT `Staking`+`Rewards` leg identity (`positionId = abi.encode(address stakingPool)`; tokenId in `positionInstanceId`), the `["Staking Pools", "Pool #<id>"]` labels (with the address fallback when `getPoolId` reverts), a **two-pool** case yielding distinct positionIds, single-leg (no-rewards / no-stake) and empty cases, asset-filter match/mismatch, unregistered-underlying drop (positions empty but the no-arg balance still owed), `getAdapterBalances` shape, `submitTokenIds` is `ASSISTANT_ROLE`-gated and reverts on a non-owned id, reads discard transferred/reverting ids, `clearTokenId` / `clearAccount`, the `MAX_TOKEN_IDS` (64) per-account cap reverting when full, `try/catch` never-revert when the viewer reverts, ERC165, and `underlyingAssetsSupported`. The mock `StakingViewer` returns per-token structs for exactly the ids the adapter passes, so cache → valuation is tested end-to-end.

## 4. Adapter formula recap
```text
ids = cached tokenIds for `account`, each re-verified live: keep only those whose
      StakingNFT.tokenInfo(id).owner == account   // transferred/burned ids discarded
for each id in ids:
  t = StakingViewer.getTokens([id])[0]            // { tokenId, poolId, activeStake, expiredStake, rewards }
  Staking leg = t.activeStake + t.expiredStake (NXM)   // if > 0
  Rewards leg = t.rewards (NXM)                         // if > 0
  positionId         = abi.encode(StakingViewer.stakingPool(t.poolId)) ; isDebt = false
  positionInstanceId = bytes32(t.tokenId)              // the NFT id rides here, not in positionId or the labels
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
One NXM `Staking` leg + one NXM `Rewards` leg **per StakingNFT tokenId** (zeros dropped), keyed by `positionId = abi.encode(address stakingPool)` (the tokenId rides in `positionInstanceId`); the per-kind sums equal the aggregate above. Nothing if the account stakes nothing.

## 8. Ground-truth cross-check
- **On-chain (fork test):** the adapter's per-NFT legs sum back to `getAggregatedTokens([180,184,185,186,187]).active + expired + rewards`, delta **0**, and the no-arg total getter matches the same. The adapter values exactly the 5 submitted ids, re-verifying ownership live.
- **Debank:** `nexus` shows "Staked" ≈ $3.35M NXM for this Safe (the "Yield" $250k line is RWIV, covered separately by #95/#103).

## 9. Wiring the live dev-anvil dashboard
Nexus has a live holder (the Safe), so no balance seeding. NXM must be registered (it is, in the prod asset config). Because this is an assisted adapter, an `ASSISTANT_ROLE` holder must `submitTokenIds` the Safe's StakingNFT ids before its positions surface — `getAdapterPositions` returns empty for an account with no cached ids.
```bash
bash script/development/anvil/start-forks.sh 1
bash script/development/deploy/deploy.sh 1                       # NAV + Chainlink assets
# register NXM (custom RAMM feed) + deploy NexusMutualStakingPoolsAssisted + addBalanceAdapters,
# then submitTokenIds(0x8e53…cFE3, [180,184,185,186,187]) as the assistant, then:
bash script/development/app/sync-app-env.sh 1
# start Next.js and enter 0x8e53D04644E9ab0412a8c6bd228C84da7664cFE3
```
The Safe shows a "Nexus Mutual" group with a per-pool Staking leg (+ Rewards) for each of its 5 positions.

## 10. Test verdict
- Fork: **3/3 pass** (strict delta 0 vs live `getAggregatedTokens`; per-NFT legs sum back to the aggregate). `forge build`/`fmt` clean. Pin: standalone adapter — confirm `LibraryPinConsistency` (CI is the authority).
