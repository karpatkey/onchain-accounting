# sGHO (Aave Savings GHO) — balance-adapter verification

## 1. Adapter under test

`src/balances/protocols/ERC4626Wrap.sol` — the immutable generic `ERC4626WrapBalanceOracle`, instantiated for **sGHO**. Constructor: `(wrapper, navCalculator)` where `wrapper = sGHO` (`0xE1753F2e00940cC31213dd92013cF019DFE4ca1d`) and the wrapper's `asset()` is **GHO** (`0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f`). The constructor **reverts unless GHO is already registered on NAVCalculator** — wiring errors are loud, not silently zero-valued. Identity is derived on-chain: `positionId = abi.encode(wrapper)`, `protocolId = keccak256("erc4626")`, `positionKind = Supplied`.

### Inheritance + per-chain scope (Phase 0)

- **Inheritance:** none — `ERC4626WrapBalanceOracle` implements `IBalanceOracleAdapter` + `IPositionDescribable` directly. sGHO needs **no bespoke contract**: it is the generic ERC-4626 wrapper adapter pointed at the sGHO vault.
- **Per-chain scope:** the **sGHO savings vault is mainnet-only**. GHO the token exists on Gnosis / Arbitrum / Base too, but the sGHO vault (`0xE1753F2e…`) is not deployed there — so `chains/1.json` is the only chain config with `ERC4626Wrap_sGHO`. A single mainnet fork test is sufficient; no per-chain branches.
- **Yield mechanics:** sGHO is a yield-bearing savings vault — the share price rises over time (`convertToAssets(1 share) > 1 GHO`), accruing **per second** (so the GHO value is `block.timestamp`-dependent, not just block-number). There is **no exit fee, cooldown, or withdrawal delay** — redemption is instant and 1:1 (proven in §8), so `convertToAssets` is the correct, non-over-reporting read of redeemable value.
- **Math branch:** single leg. `amount = sGHO.convertToAssets(sGHO.balanceOf(account))`, denominated in GHO, `isDebt = false`, `PositionKind.Supplied`. Reports nothing if GHO is unregistered (defensive runtime check) or balance is zero.

## 2. Existing fork test coverage

`test/balances/protocols/fork/ERC4626Wrap.fork.t.sol` already had two sGHO suites:
- `ERC4626WrapBalanceOracleForkTest_sGHO` (block `25_220_000`) — synthetic: deals + deposits 100k GHO, asserts the oracle value ≈ `convertToAssets(shares)`, and — critically — **redeems 100% of the shares and asserts the GHO received ≈ the oracle-reported amount** (the no-exit-fee/cooldown proof).
- `ERC4626WrapBalanceOracleForkTest_sGHO_RealHolder` (block `25_230_126`) — pins a real holder's exact on-chain GHO value.

Both kept as regression nets.

## 3. What this case adds

- A **second real-holder pin at the verification block `25_287_877`** (`ERC4626WrapBalanceOracleForkTest_sGHO_RealHolder_Fresh`) — augments, doesn't replace. The holder hasn't moved (share count identical), so it is a pure yield-accrual delta vs the `25_230_126` pin. This README's §7 figures and the fork test pin the **same** block; the live dev-anvil dashboard (§9) forks at *latest* and is a sanity check that drifts from these numbers by design.
- This evidence pack: README + case JSON + query script + dev deploy helper, bringing sGHO up to the same 10-section structure as the other verified protocols.

## 4. Adapter formula recap

```
shares = sGHO.balanceOf(account)
amount = sGHO.convertToAssets(shares)            # redeemable GHO (share price >= 1, accrues per second)
emit PositionBalance(GHO, amount, isDebt=false, Supplied, positionId=abi.encode(sGHO))   if amount > 0
```

`convertToAssets` is the redeemable value: `4_575_878 sGHO shares → 4_589_154 GHO` at the block below (share price ≈ 1.0029, the ~0.29% being accrued savings yield).

## 5. Cherry-picked account

| Holder | Address | Rationale |
|---|---|---|
| `HOLDER` | `0x5eF87DeC00a19d2b47EE0073d869F7d7feFF26ef` | Large real sGHO holder (~4.59M GHO) — biggest realistic single position; the share-vs-underlying gap is clearly visible (shares 4.575878M vs GHO 4.589154M). |

### Setup

| Field | Value |
|---|---|
| Chain | Ethereum mainnet (chainId 1) |
| Block | **25,287,877** |
| Block timestamp | 1781104487 (`0x6a297f67`) — **2026-06-10 15:14:47 UTC** |
| sGHO vault (wrapper) | `0xE1753F2e00940cC31213dd92013cF019DFE4ca1d` |
| Underlying (`asset()`) | GHO `0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f` |
| Adapter under test | `ERC4626WrapBalanceOracle` |
| Fork-test contract | `ERC4626WrapBalanceOracleForkTest_sGHO_RealHolder_Fresh` in `test/balances/protocols/fork/ERC4626Wrap.fork.t.sol` |

## 6. Case files in this folder

| File | Purpose |
|---|---|
| `case-real-holder-mainnet.json` | Machine-readable evidence pack: holder, shares, redeemable GHO, identity, ground-truth method |
| `query-live-balances.s.sol` | Forge script that deploys the adapter against a dev NAV and prints the sGHO leg for ad-hoc cross-checks |
| `script/development/deploy/deploy-sgho.sh` | Dev-anvil deploy helper: `forge create` the adapter + `addBalanceOracle` on the local NAV |

## 7. Expected balances

Single leg. Captured at the fork block in §5 (`vm.rollFork` value — exact at the block's timestamp; a live dev anvil reads marginally higher as it advances `block.timestamp` while mining).

| Holder | Leg | Token | sGHO shares (raw) | GHO value (raw) | GHO (humanised) | isDebt |
|---|---|---|---|---|---|---|
| `0x5eF87DeC…` | Supplied | GHO | `4575878017851927061694571` | `4589154643764641667853774` | 4,589,154.643764641667853774 GHO | false |

`getOracleBalanceForAsset(holder, GHO)`, `getOracleBalances(holder)`, and the single `getOraclePositions` entry all return this same GHO value.

## 8. Ground-truth cross-check

Two independent checks pin the value:

| Check | Method |
|---|---|
| **No over-reporting** (synthetic suite) | Deposit a known amount, then **redeem 100% of the shares** and assert the GHO actually received ≈ the oracle-reported amount → proves `convertToAssets` carries **no exit fee / cooldown / withdrawal haircut**. |
| **Exact real value** (real-holder suites) | `oracle.getOracleBalanceForAsset == sGHO.convertToAssets(holder shares)` at the pinned block, with the share balance also pinned. |

**Why no Python:** the value is the vault's own `convertToAssets` of a live share balance — there is no closed-form re-derivation to do; the strongest ground truth is the redemption round-trip (what you'd actually receive) plus the exact pinned conversion. The tests also assert `protocolId == erc4626`, `positionId == abi.encode(sGHO)`, and `PositionKind.Supplied`.

## 9. Wiring the live dev-anvil dashboard

`script/development/deploy/deploy-sgho.sh` deploys + registers the adapter on the local mainnet anvil so the dashboard renders the holder's sGHO position for a side-channel cross-check. Run after the dev anvil is up and the NAV proxy is deployed (GHO must be registered — `register-assets.sh` does this for chain 1):

```bash
bash script/development/anvil/start-forks.sh 1     # fresh fork at latest
bash script/development/deploy/deploy.sh 1         # NAV + Chainlink assets (incl. GHO)
bash script/development/deploy/deploy-sgho.sh 1
bash script/development/app/sync-app-env.sh 1
# then start the Next.js dev server in app/
```

`start-forks.sh` forks at the **latest** block (not pinned to `25_287_877`), and `convertToAssets` is `block.timestamp`-dependent, so the dashboard value will read marginally higher than §7's pinned numbers — this is an expected, sub-bp live-drift sanity check, not a mismatch. For strict alignment, fork anvil at the pinned block directly (`anvil --fork-url <rpc> --fork-block-number 25287877`). The position renders under **Aave / Savings** as a single **Supplied** leg denominated in GHO. **Reconciling against the Aave UI:** Aave's "Savings GHO (sGHO)" tile shows the **sGHO share count** (~4.58M), while the **withdraw preview shows the redeemable GHO** (~4.59M) — the adapter reports the latter (`convertToAssets`), matching "you'll receive 4.59M GHO". The ~0.29% gap between the two is real accrued savings yield, not an error.

## 10. Test verdict

| Aspect | Status |
|---|---|
| `convertToAssets(balanceOf)` reports redeemable GHO | ✅ |
| No exit fee / cooldown — redemption 1:1 (redeem-100% round-trip) | ✅ |
| Real holder: oracle == exact pinned `convertToAssets` value | ✅ (2 pinned blocks: 25_230_126 + 25_287_877) |
| Identity: `protocolId == erc4626`, `positionId == abi.encode(sGHO)`, `Supplied` | ✅ |
| Constructor reverts if GHO unregistered | ✅ |
| Mainnet-only scope (vault not on other chains) | ✅ |

**Mainnet: sGHO fork suites pass (synthetic + 2 real-holder pins).** Single mainnet deployment → no cross-chain surface. sGHO is verified.

Run via:

```
FOUNDRY_PROFILE=slow forge test --match-path "test/balances/protocols/fork/ERC4626Wrap.fork.t.sol" -vv
```
