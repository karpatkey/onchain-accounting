# StakeWise V3 Exit Queue — balance-adapter verification

## 1. Adapter under test
`StakeWiseV3ExitQueueAssistedBalanceAdapter` (`src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.sol`). Reports the in-flight assets owed to an account in StakeWise V3's exit queue (`enterExitQueue(shares, receiver)` moves vault shares into the queue and returns a `positionTicket`; the queued value is claimable once validator exits complete).

### Inheritance + per-chain scope (Phase 0)
- Extends the shared `AssistedCoordCache` base (permissionless, `msg.sender`-keyed `submit`/`remove` — no roles, no `AccessControl`) and implements `IPositionDescribable` — a member of the **assisted balance-adapter family** (**ADR 0015**), the documented mutable-cache exception, fed on-chain by a delegatecall `BalanceAdapterAssistant` (**ADR 0018**; sibling of `EtherFiWithdrawalQueueAssistedBalanceAdapter` and `NexusMutualStakingPoolsAssistedBalanceAdapter`). The mutability is a per-account `(vault, positionTicket, timestamp)` coordinate cache only; identity + all addresses are immutable.
- **Mainnet (1) only.** Every StakeWise V3 vault on mainnet settles in ETH, so the single `UNDERLYING_TOKEN` (native-ETH sentinel) is correct. Do not deploy against this underlying on a chain with a non-ETH staking asset (e.g. GNO on Gnosis).

### Math branches (`_owedForPosition`)
- `getExitQueueIndex(ticket)` reverts → `0`.
- `idx == -1` (not yet checkpointed, fully pending) → pass `type(uint256).max` to `calculateExitedAssets`, which early-returns `(leftShares = full queued shares, 0, 0)` without reverting → value `convertToAssets(leftShares)`.
- `idx >= 0` → `calculateExitedAssets(account, ticket, ts, idx)` → `exitedAssets` (claimable) `+ convertToAssets(leftShares)` (still-queued remainder).
- `calculateExitedAssets(receiver = account, …)` returns `(0,0,0)` for a tuple that is not the account's exit request (wrong receiver/timestamp/ticket, or claimed) → `0`. **This is the on-chain ownership check** (no `ownerOf` exists for exit positions).
- Claimable/locked split is gated on `EXIT_CLAIM_DELAY` (StakeWise's post-checkpoint claim delay, `86400` = 24h on V3 mainnet, pinned at construction): the exited portion (`exitedAssets`) counts as claimable only once `block.timestamp >= timestamp + EXIT_CLAIM_DELAY`; before that, and the still-queued remainder always, it is locked. The owed *total* is unaffected by the gate.
- Every external read is `try/catch`→0 so the scan never reverts.
- `getAdapterPositions`: `assetFilter` mismatch → empty; native ETH not registered → empty; total `0` → empty; else, **per cached position (per `positionTicket`)**, up to two native-ETH legs — a claimable leg (`isLocked=false`) and a locked/pending leg (`isLocked=true`) — both carrying the ticket id in the typed `positionInstanceId` field and sharing the static per-vault `positionId = abi.encode(address vault)` (ADR 0016; like Lido/Stader/Kelp/ether.fi).

## 2. Fork test coverage
`test/balances/AssistedBalanceAdapters/fork/StakeWiseV3ExitQueueAssistedBalanceAdapter.fork.t.sol` (6 tests, `FOUNDRY_PROFILE=slow`):
- `test_realHolder_claimableValuation` — at block 25,380,000 the real holder self-submits its ENS-Safe tuple → adapter **== independent live read AND** pinned `1000033196791603018908` wei (delta 0).
- `test_realHolder_pendingValuation` — rolls to block 25,376,000 (idx == -1) → adapter values the still-queued shares via the out-of-range-index path, **== live read AND** pinned `999999999999999999999` wei (the subtle branch ADR 0014 flagged).
- `test_getAdapterPositions_identity` — identity fields on the real holder (`positionId == abi.encode(GENESIS_VAULT)`, `positionInstanceId == bytes32(TICKET)`).
- `test_realHolders_multipleAccounts_valuedLive` — two more independent real holders each self-submit their own checkpointed ticket at block 25,440,928; each is valued against an independent live recompute and the per-account sets stay isolated.
- `test_unsubmitted_reportsZero`, `test_submit_revertsOnTupleNotOwnedByAccount` — negative cases vs the real contracts (the submit path is fail-loud: a stranger submitting a ticket it does not own resolves to zero owed for the caller and **reverts** `CoordinateNotOwned`).

## 3. Unit test coverage
`test/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.t.sol` (43 tests, mock-only): constructor guards (×6, incl. zero claim-delay + registry-not-contract + nav-not-contract), permissionless `msg.sender`-keyed submit/dedup + `remove` (drops when claimed; reverts while still owed, when not tracked, or when tracked by another account) + `clearAccount`, valuation (claimable, fully-pending via convertToAssets, partially-exited sum, aggregation), claim-delay split (checkpointed-but-within-delay reported locked), ownership re-verify (wrong-receiver submit revert + claimed-after-submit drop), unregistered-vault submit revert, zero-owed submit revert, `try/catch` reverts on getExitQueueIndex / calculateExitedAssets / convertToAssets (→ drop, never revert), MAX_POSITIONS cap (submit reverts when full), unregistered-underlying branch, identity, `getAdapterPositions` locked leg + mixed claimable/locked + two-positions-same-vault distinct ticket instance ids, ERC165, `underlyingAssetsSupported`, getAdapterBalances shape, assetFilter-matches-underlying accept path, and `clearAccount` empty-set no-op. The mock forces the adapter to pass `type(uint256).max` when `idx < 0` (else it reverts), proving the fully-pending index logic.

## 4. Adapter formula recap
```text
for each cached (vault, ticket, ts):
    idx = vault.getExitQueueIndex(ticket)
    queryIdx = idx < 0 ? type(uint256).max : uint256(idx)
    (leftShares, _, exitedAssets) = vault.calculateExitedAssets(account, ticket, ts, queryIdx)
    queued = leftShares > 0 ? vault.convertToAssets(leftShares) : 0     # still-queued remainder
    if block.timestamp >= ts + EXIT_CLAIM_DELAY:                        # post-checkpoint claim delay elapsed
        claimable = exitedAssets;  locked = queued                      # exited → claimable, queued → locked
    else:
        claimable = 0;  locked = exitedAssets + queued                 # within delay → everything locked
    # static positionId PER VAULT; ticket id rides in positionInstanceId; up to two legs (ADR 0016):
    pid = abi.encode(address(vault)); instanceId = bytes32(ticket)
    if claimable > 0: emit PositionBalance{ native ETH, claimable, isDebt:false,
      protocolBrand: keccak256("stakewise"), protocolId: keccak256("stakewise-v3"),
      protocolSubId: keccak256("stakewise-v3-exit"), positionId: pid, positionInstanceId: instanceId,
      positionKind: Supplied, isLocked: false }
    if locked > 0:    emit PositionBalance{ native ETH, locked,    isDebt:false,
      protocolBrand: keccak256("stakewise"), protocolId: keccak256("stakewise-v3"),
      protocolSubId: keccak256("stakewise-v3-exit"), positionId: pid, positionInstanceId: instanceId,
      positionKind: Supplied, isLocked: true }
```
Native ETH (`0xEeee…EEeE`) is a registered NAV asset, so NAVCalculator prices the leg. **The cache stores coordinates only — never amounts** — so the assistant can only under-report, never over-report (ADR 0014).

## 5. Cherry-picked account
Real holder **`0x4F2083f5fBede34C2714aFfb3105539775f7FE64`** (ENS DAO Safe — a KPK-managed account) entered the Genesis vault's exit queue at block 25,375,501 with ticket `241843370089062440762194` (ts `1782159731`), ~1000 ETH. Discovered via the `ExitQueueEntered` event scan (the same scan the agent runs). The position is read both fully-pending (block 25,376,000) and claimable-but-unclaimed (block 25,380,000); it was claimed by ~block 25,384,000.

## 6. Case files in this folder
- `case-stakewise-exit.json` — addresses, the real holder + tuple, both lifecycle states with their fork blocks and pinned amounts, ground-truth source, `delta: 0`.

## 7. Expected balances
### 7a. Per-state detail
| Account | State | Block | Asset | Amount | type | isDebt |
|---|---|---|---|---|---|---|
| `0x4F20…FE64` | fully pending | 25,376,000 | native ETH | `999999999999999999999` (~1000 ETH) | Supplied | false |
| `0x4F20…FE64` | claimable | 25,380,000 | native ETH | `1000033196791603018908` (~1000.03 ETH) | Supplied | false |

### 7b. Per-asset summary
Up to two native-ETH legs per cached exit position (claimable + locked, gated on `EXIT_CLAIM_DELAY`, sharing one static positionId per vault and carrying the ticket in `positionInstanceId`) — Σ of the account's live, account-owned exit positions; nothing otherwise.

## 8. Ground-truth cross-check
- **On-chain (fork test):** `adapter.getAdapterBalanceForAsset(holder, ETH)` **== `exitedAssets + convertToAssets(leftShares)`** read live from the vault, delta **0**, at both lifecycle blocks.
- **App / protocol-UI:** the account appears under "Exit requests" on app.stakewise.io with the same pending/claimable ETH.
- **Debank:** does not surface StakeWise exit-queue positions — this adapter is net-new coverage beyond the Debank baseline.

## 9. Wiring the live dev-anvil dashboard
StakeWise has real holders, so no seeding — the submit helper plays the agent. The exact ENS position only renders while open, so pin the anvil fork in its open window (~block 25,378,000–25,382,000), or pass a currently-open tuple.
```bash
bash script/development/anvil/start-forks.sh 1
bash script/development/deploy/deploy.sh 1                          # NAV + Chainlink assets (native ETH registered)
bash script/development/deploy/deploy-stakewise-exit.sh 1           # adapter + addBalanceAdapters
bash script/development/deploy/submit-stakewise-positions.sh 1      # agent step: submitPositions(0x4F20…, [(vault,ticket,ts)])
bash script/development/app/sync-app-env.sh 1
# start the Next.js dev server in app/ and enter 0x4F2083f5fBede34C2714aFfb3105539775f7FE64
```
The Safe then shows a "StakeWise V3" group with a ~1000 ETH exit-queue leg.

## 10. Test verdict
- Unit: **43/43 pass**. Fork: **6/6 pass** (strict delta 0 vs live read, both lifecycle states). `forge build`/`fmt` clean. Pin: balance-adapter (no prices-lib change) — verify with a clean local full build, or CI's `Library pins (clean build)` job. Not the Unit job: it downloads artifacts from an incrementally-built, branch-shared cache, so its pin reading is a correct hash of an arbitrary compilation scope.
