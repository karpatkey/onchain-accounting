# ether.fi Withdrawal Queue — balance-adapter verification

## 1. Adapter under test
`EtherFiWithdrawalQueueAssistedBalanceAdapter` (`src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol`). Reports the in-flight ETH owed to an account in ether.fi's withdrawal queue (eETH/weETH burned on `requestWithdraw`, ETH claimable from a `WithdrawRequestNFT`).

### Inheritance + per-chain scope (Phase 0)
- Implements `IBalanceAdapter` + `IPositionDescribable` directly, **plus `Ownable`** — the 3rd documented mutable-cache adapter (after Merkl), per **ADR 0014**. The mutability is a per-account `tokenId` cache only; identity + all addresses are immutable.
- **Mainnet (1) only.** ether.fi's `WithdrawRequestNFT` (`0x7d57…4E2c`) + `LiquidityPool` (`0x3088…F216`) are mainnet; ENS / ETH-Alpha / Nexus hold eETH there.

### Math branches (`_owedForToken`)
- `ownerOf(id) != account` (incl. burned/claimed → reverts → caught) → `0`.
- `!isValid(id)` → `0`.
- `isFinalized(id)` → `getClaimableAmount(id)` (exact). Else **pending** → `min(amountOfEEth, LiquidityPool.amountForShare(shareOfEEth)) − feeGwei·1gwei`, clamped at 0 — mirrors ether.fi's own claim math. Every external read is `try/catch`→0 so the scan never reverts.
- `getAdapterPositions`: `assetFilter` mismatch → empty; native ETH not registered → empty; total `0` → empty; else up to **two native-ETH legs** — claimable (`isLocked=false`, sum of finalized ids) + locked (`isLocked=true`, sum of pending ids) — sharing the static `positionId = abi.encode(address withdrawRequestNFT)` (ADR 0016; like Lido/Stader/Kelp).

## 2. Fork test coverage
`test/balances/AssistedBalanceAdapters/fork/EtherFiWithdrawalQueueAssisted.fork.t.sol` (4 tests, `FOUNDRY_PROFILE=slow`, FORK_BLOCK 25,387,000):
- `realHolder_pendingValuation` — submit real id #80154 → adapter **== independent live read AND** pinned `253077459762665832` wei (delta 0).
- `getAdapterPositions_identity` — identity fields on the real holder.
- `unsubmitted_reportsZero`, `submit_skipsIdNotOwnedByAccount` — negative cases vs the real contracts.

## 3. Unit test coverage
`test/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssisted.t.sol` (23 tests, mock-only): constructor guards (×4), owner-gating + submit/dedup/clear (×4), valuation (finalized, pending min/fee, fee-clamp, aggregation), ownership re-verify (transferred/burned/non-owned drop), `isValid` drop, unregistered-underlying branch, pending-path `try/catch` reverts (getRequest / amountForShare → drop, never revert), identity, ERC165, `underlyingAssetsSupported`.

## 4. Adapter formula recap
```
for each cached tokenId with ownerOf(id)==account && isValid(id):
    val = isFinalized(id) ? getClaimableAmount(id)
                          : min(amountOfEEth, amountForShare(shareOfEEth)) − feeGwei·1gwei
    if isFinalized(id): claimable += val      # claimable leg
    else:               locked    += val      # locked (pending) leg
# static positionId, split into up to two legs sharing it (ADR 0016):
pid = abi.encode(address(WITHDRAW_REQUEST_NFT))
if claimable > 0: emit PositionBalance{ native ETH (registered), claimable, isDebt:false,
  protocolId: keccak256("etherfi-withdrawal"), positionId: pid, positionKind: Supplied, isLocked: false }
if locked    > 0: emit PositionBalance{ native ETH (registered), locked,    isDebt:false,
  protocolId: keccak256("etherfi-withdrawal"), positionId: pid, positionKind: Supplied, isLocked: true }
```
Native ETH (`0xEeee…EEeE`) is a registered NAV asset, so NAVCalculator prices the leg. **The cache stores ids only — never amounts** — so the owner can only under-report, never over-report (ADR 0014).

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
Up to two native-ETH legs per account (claimable + locked, sharing one static positionId) — Σ of its live, owned, valid requests split by finalization; nothing otherwise.

## 8. Ground-truth cross-check
- **On-chain (fork test):** `adapter.getAdapterBalanceForAsset(holder, ETH)` **== `min(amountOfEEth, amountForShare(shareOfEEth)) − fee`** read live from `WithdrawRequestNFT.getRequest` + `LiquidityPool.amountForShare`, delta **0**.
- **App / protocol-UI:** the account appears under "Withdrawals" on app.ether.fi with the same pending ETH.
- **Debank:** does **not** surface ether.fi WQ (verified) — this adapter is net-new coverage beyond the Debank baseline.

## 9. Wiring the live dev-anvil dashboard
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
- Unit: **23/23 pass**. Fork: **4/4 pass** (strict delta 0 vs live read). `forge build`/`fmt` clean. Pin: balance-adapter (no prices-lib change) — CI's `LibraryPinConsistency` is the source of truth.
