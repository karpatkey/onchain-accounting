# Ethena sUSDe Cooldown — balance-adapter verification

## 1. Adapter under test
`EthenaCooldownBalanceAdapter` (`src/balances/BalanceAdapters/EthenaCooldownBalanceAdapter.sol`). Reports the USDe owed to an account that is in the sUSDe unstaking cooldown.

### Inheritance + per-chain scope (Phase 0)
- Implements `IBalanceAdapter` + `IPositionDescribable` directly (a simple, single-instance adapter — like the Stader/Lido/Kelp withdrawal-queue adapters). No base class, no overrides → the only verification surface is this contract's own logic.
- **Mainnet (1) only.** Ethena's `StakedUSDeV2` (sUSDe `0x9D39…3497`) is mainnet; the USD/ETH Alpha Safes hold sUSDe on mainnet. No per-chain ABI shims.

### Math branches
- `_pendingUsde(account)`: `account == 0` → `0`; else `cooldowns(account).underlyingAmount`. **No enumeration** — sUSDe keeps exactly one `UserCooldown {uint104 cooldownEnd; uint152 underlyingAmount}` per account (a new cooldown adds to it), zeroed on `unstake`.
- `getAdapterPositions`: `assetFilter` mismatch → empty; USDe not registered on NAV → empty; pending amount `0` → empty; else one leg.

## 2. Fork test coverage
`test/balances/BalanceAdapters/fork/EthenaCooldownBalanceAdapter.fork.t.sol` (5 tests, `FOUNDRY_PROFILE=slow`, FORK_BLOCK 25,380,000):
- `…matchesCooldown` (×3: `getAdapterBalanceForAsset` / `getAdapterPositions` / `getAdapterBalances`) — strict equality vs the seeded `cooldowns().underlyingAmount`.
- `noCooldown_emptyPositions`, `zeroAddress` — empty/negative cases against the real fork.

## 3. Unit test coverage
`test/balances/BalanceAdapters/EthenaCooldownBalanceAdapter.t.sol` (23 tests, mock-only): constructor guards (×4), interface/describe (×3), `getAdapterBalanceForAsset` (×6 incl. active/elapsed cooldown), `getAdapterBalances` (×3), `getAdapterPositions` (×7 incl. unregistered-asset drop, asset filter, identity, and the `isLocked` cases — locked while cooling, unlocked after the cooldown elapsed, unlocked when cooldown disabled).

## 4. Adapter formula recap
```
pending = sUSDe.cooldowns(account).underlyingAmount      // USDe, 18-dec, 0 when no cooldown
position = PositionBalance{
  balanceAsset: USDe (registered), amount: pending, isDebt: false,
  protocolBrand: keccak256("ethena"), protocolId: keccak256("ethena"), protocolSubId: keccak256("ethena-cooldown"),
  positionId: abi.encode(address sUSDe), positionKind: Supplied, positionInstanceId: bytes32(0),
  isLocked: true while cooling (block.timestamp < cooldownEnd), false once elapsed   // ADR 0016
}
```
USDe (`0x4c9E…68B3`) is a registered NAV asset (Chainlink USDe/USD), so NAVCalculator prices the leg. Correctness-on-exit: non-zero only while an unstake is in flight.

## 5. Cherry-picked accounts
No KPK Safe held a **live** cooldown at the fork block (cooldowns are transient, ~24h; checked the USD/ETH-Alpha avatars → all `0`). The fork test therefore **seeds** a real cooldown on the fork: `deal` USDe → `deposit` into sUSDe → `cooldownShares(allShares)`, then reads `cooldowns(holder)` as ground truth. This exercises the real `StakedUSDeV2` accounting (not a mock).

## 6. Case files in this folder
- `case-ethena-cooldown.json` — machine-readable: contract addresses, fork block, seed parameters, the leg, ground-truth source, `delta: 0`.

## 7. Expected balances
### 7a. Per-leg detail
| Account | Leg | Asset | Amount | type | isDebt |
|---|---|---|---|---|---|
| seeded holder | sUSDe cooldown | USDe | `cooldowns(holder).underlyingAmount` (≈ 10,000e18 from a 10,000 USDe seed, minus rate rounding) | Supplied | false |

### 7b. Per-asset summary
One USDe leg per account with an open cooldown; nothing otherwise.

## 8. Ground-truth cross-check
- **On-chain (fork test):** `adapter.getAdapterBalanceForAsset(holder, USDe)` **== `sUSDe.cooldowns(holder).underlyingAmount`**, delta **0**. The adapter reads exactly what StakedUSDeV2 records.
- **App / protocol-UI:** an account mid-cooldown appears under "Withdraw" on app.ethena.fi with the same USDe amount.

## 9. Wiring the live dev-anvil dashboard
No real KPK Safe is mid-cooldown (transient ~24h), so the demo **seeds** one.
```bash
bash script/development/anvil/start-forks.sh 1
bash script/development/deploy/deploy.sh 1                       # NAV + Chainlink assets (USDe registered)
bash script/development/deploy/deploy-ethena-cooldown.sh 1       # EthenaCooldown adapter + addBalanceAdapters
bash script/development/deploy/seed-ethena-cooldown.sh 1         # seed a cooldown onto the ETH Alpha Safe (default)
bash script/development/app/sync-app-env.sh 1
# start the Next.js dev server in app/ and enter the seeded Safe (default 0x99b9…768b)
```
The seeded Safe then shows its real portfolio **plus** the new Ethena "USDe Cooldown" leg.

## 10. Test verdict
- Unit: **23/23 pass**. Fork: **5/5 pass** (strict delta 0). `LibraryPinConsistencyTest`: 3/3 (no pin shift). `forge build`/`fmt` clean.
