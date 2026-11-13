# ether.fi Withdrawal Queue — balance-adapter verification

## 1. Adapter under test
`EtherFiWithdrawalQueueAssistedBalanceAdapter` (`src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol`). Reports the in-flight ETH owed to an account in ether.fi's withdrawal queue (eETH/weETH burned on `requestWithdraw`, ETH claimable from a `WithdrawRequestNFT`).

### Inheritance + per-chain scope (Phase 0)
- Extends `AssistedCoordCache` and implements `IPositionDescribable` — a documented mutable-cache adapter in the **assisted balance-adapter family** ([ADR 0015](../../../../docs/decisions/0015-assisted-balance-adapter-family.md)), now **assistant-fed** with an ADR 0030 keeper path ([ADR 0018](../../../../docs/decisions/0018-assistant-fed-assisted-balance-adapters.md), superseding the off-chain-agent `ASSISTANT_ROLE` base of ADR 0014). No `Ownable`; the only role is the ADR 0030 keeper's `SUBMITTER_ROLE` (for `submitFor`). The owner `submit`/`remove` mutators are `msg.sender`-keyed, so a caller only touches its own set (the canonical feeder is `EtherFiWithdrawalQueueAssistant`, which the owner Safe delegatecalls so the adapter sees `msg.sender = Safe = owner`). The mutability is a per-account `tokenId` cache only; identity + all addresses are immutable.
- **Mainnet (1) only.** ether.fi's `WithdrawRequestNFT` (`0x7d57…4E2c`) + `LiquidityPool` (`0x3088…F216`) are mainnet; ENS / ETH-Alpha / Nexus hold eETH there.

### Math branches (`_owedForToken`)
- `ownerOf(id) != account` (incl. burned/claimed → reverts → caught) → `0`.
- `!isValid(id)` → `0`.
- `isFinalized(id)` → `getClaimableAmount(id)` (exact). Else **pending** → `min(amountOfEEth, LiquidityPool.amountForShare(shareOfEEth)) − feeGwei·1gwei`, clamped at 0 — mirrors ether.fi's own claim math. Every external read is `try/catch`→0 so the scan never reverts.
- `getAdapterPositions`: `assetFilter` mismatch → empty; `account == address(0)` → empty; no cached ids → empty; native ETH not registered → empty; else **one native-ETH `Supplied` leg per owned cached request** (zero-amount legs skipped), each carrying its own `isLocked` (finalized → `false`, pending → `true`), all sharing the static `positionId = abi.encode(WITHDRAW_REQUEST_NFT)` with the request's `tokenId` riding in the typed `positionInstanceId`.

## 2. Fork test coverage
`test/balances/AssistedBalanceAdapters/fork/EtherFiWithdrawalQueue.fork.t.sol` (4 tests, `FOUNDRY_PROFILE=slow`, FORK_BLOCK 25,387,000):
- `test_realHolder_pendingValuation` — submit real id #80154 → adapter **== independent live read AND** pinned `253077459762665832` wei (delta 0).
- `test_getAdapterPositions_identity` — identity fields on the real holder.
- `test_unsubmitted_reportsZero`, `test_submit_revertsOnIdNotOwnedByAccount` — negative cases vs the real contracts (the submit is fail-loud: it **reverts** `CoordinateNotOwned` on an id not owned by the account).

## 3. Unit test coverage
`test/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueue.t.sol` (47 tests, mock-only): constructor guards (×7: zero NFT/LP/underlying/NAV, non-contract NFT/LP/NAV), permissionless `submit`/`remove` (dedup, non-owned revert `CoordinateNotOwned`, cache-full revert `CoordinateCacheFull`, remove of a claimed/transferred-away id, `CoordinateStillLive` on a live-owned id, `CoordinateNotCached` on an untracked id, `CoordSubmitted`/`CoordCleared`/`clearAccount` events), valuation (finalized, pending min/fee, fee-clamp, aggregation), ownership re-verify (transferred/burned/non-owned drop), `isValid` drop, per-request legs (locked, mixed claimable/locked, non-owned cached id discarded, zero-owed leg skipped), unregistered-underlying branch, asset-filter mismatch, zero-owed, pending-path `try/catch` reverts (getRequest / amountForShare / isFinalized / isValid / getClaimableAmount → drop, never revert), identity, ERC165, `underlyingAssetsSupported`.

## 4. Adapter formula recap
```text
# static positionId shared across all per-request legs:
pid = abi.encode(WITHDRAW_REQUEST_NFT)
for each cached tokenId with ownerOf(id)==account && isValid(id):
    val = isFinalized(id) ? getClaimableAmount(id)
                          : min(amountOfEEth, amountForShare(shareOfEEth)) − feeGwei·1gwei
    if val == 0: continue                     # zero-amount legs skipped
    emit PositionBalance{ native ETH (registered), val, isDebt: false,
      protocolBrand: ETHERFI, protocolId: ETHERFI, protocolSubId: ETHERFI_WITHDRAWAL,
      positionId: pid, positionKind: Supplied,
      isLocked: !isFinalized(id), positionInstanceId: bytes32(id) }
```
One native-ETH `Supplied` leg is emitted **per owned cached request** (not aggregated into claimable/locked sums); each leg's `isLocked` reflects that request's own state and its `tokenId` rides in the typed `positionInstanceId` (never in `positionId`). Native ETH (`0xEeee…EEeE`) is a registered NAV asset, so NAVCalculator prices each leg. **The cache stores ids only — never amounts** — so the assistant can only under-report, never over-report (ADR 0015).

## 5. Cherry-picked accounts
Real holder **`0xcFFab3dFdCa60d838512c41a772e799b71dF1Af4`** owns `WithdrawRequestNFT` **#80154** (pending, isValid, fee 0, ~0.2531 ETH) at FORK_BLOCK — discovered via the `Transfer`-event scan (the same scan the agent runs). No seeding needed: unlike Ethena cooldowns, real ether.fi requests persist for days. KPK Safes (ENS / ETH-Alpha / Nexus) hold eETH and use the queue on exit.

## 6. Case files in this folder
- `case-etherfi-withdrawals.json` — addresses, fork block, the real holder + tokenId, the leg, ground-truth source, `delta: 0`.

## 7. Expected balances
### 7a. Per-leg detail
| Account | Leg | Asset | Amount | type | isDebt |
|---|---|---|---|---|---|
| `0xcFFab3…1Af4` | ether.fi withdrawal #80154 (pending) | native ETH | `253077459762665832` (~0.2531 ETH) | Supplied | false |

### 7b. Per-asset summary
One native-ETH leg per owned cached request (all sharing one static positionId, each with its own `isLocked` and `positionInstanceId`) — the per-asset total is the Σ of the account's live, owned, valid requests; nothing otherwise.

## 8. Ground-truth cross-check
- **On-chain (fork test):** `adapter.getAdapterBalanceForAsset(holder, ETH)` **== `min(amountOfEEth, amountForShare(shareOfEEth)) − fee`** read live from `WithdrawRequestNFT.getRequest` + `LiquidityPool.amountForShare`, delta **0**.
- **App / protocol-UI:** the account appears under "Withdrawals" on app.ether.fi with the same pending ETH.
- **Debank:** does **not** surface ether.fi WQ (verified) — this adapter is net-new coverage beyond the Debank baseline.

## 9. Wiring the live dev-anvil dashboard
> **Outdated (2026-11):** this section used the ADR 0014-era `deploy-*`/`submit-*` dev scripts, which targeted the
> agent-fed adapters (`submitTokenIds`/`submitPositions`, since removed) and were deleted with them. Kept as a record
> of the original verification; current adapters are fed through the ADR 0030 Assistants or the keeper (`submitFor`).

ether.fi has real holders, so no seeding — the submit helper plays the agent (submits the real holder's real tokenId).
```bash
bash script/development/anvil/start-forks.sh 1
bash script/development/deploy/deploy.sh 1                          # NAV + Chainlink assets (native ETH registered)
bash script/development/deploy/deploy-etherfi-withdrawals.sh 1      # adapter + addBalanceAdapters
bash script/development/deploy/submit-etherfi-positions.sh 1        # agent step: submitTokenIds(0xcFFab3…, [80154])
bash script/development/app/sync-app-env.sh 1
# start the Next.js dev server in app/ and enter 0xcFFab3dFdCa60d838512c41a772e799b71dF1Af4
```
The Safe then shows an "ether.fi" group with a ~0.2531 ETH withdrawal-queue leg.

## 10. Test verdict
- Unit: **47/47 pass**. Fork: **4/4 pass** (strict delta 0 vs live read). `forge build`/`fmt` clean. Pin: balance-adapter (no prices-lib change) — verify with a clean local full build, or CI's `Library pins (clean build)` job. Not the Unit job: it downloads artifacts from an incrementally-built, branch-shared cache, so its pin reading is a correct hash of an arbitrary compilation scope.
