# Aave Umbrella — balance-adapter verification

## 1. Adapter under test

`src/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.sol` — the immutable `AaveUmbrellaBalanceAdapter`. Constructor: `(rewardsController, navCalculator)`. It pins **only** the Umbrella `RewardsController` as a trust anchor and discovers everything else at runtime — the full stake-token set, each stake token's bare reserve, and the reward-token→bare-reserve mapping. Identity is derived on-chain: `positionId = abi.encode(stakeToken)`, the three-level taxonomy `protocolBrand = keccak256("aave")` / `protocolId = keccak256("aave-v3")` / `protocolSubId = keccak256("aave-v3-umbrella")` (the `ProtocolIds.AAVE` / `AAVE_V3` / `AAVE_V3_UMBRELLA` constants), `positionInstanceId = bytes32(0)`, and `positionLabels(positionId) = ["Umbrella Module"]`.

### Inheritance + per-chain scope (Phase 0)

- **Inheritance:** `AaveUmbrellaBalanceAdapter` extends `BalanceAdapterBase` (the plain-adapter base that declares the `IBalanceAdapter` + `IPositionDescribable` surface and supplies the shared `supportsInterface`) — it is *not* a meta-adapter; the live set is discovered, not governed via `addMetaInstances`/`removeMetaInstances`.
- **Dynamic discovery:** `RewardsController.getAllAssets()` enumerates every stake token. Aave governance can add a stake token (or reconfigure its reward token) and the adapter picks it up automatically, provided the bare reserve it resolves to is registered on NAVCalculator. Unregistered reserves are silently skipped (same convention as the Aave lending adapters).
- **Per-chain scope:** Umbrella is deployed **only on Ethereum mainnet**. `script/config/contracts-deployment-config/balance-adapters/1.json` is the only balance-adapter config with an `AaveUmbrella` entry (RewardsController `0x4655Ce3D625a63d30bA704087E52B4C31E38188B`). No per-chain code branches → a single mainnet fork test is sufficient.
- **Today's stake-token set** (`getAllAssets()` at the fork block):

  | Stake token | Address | Underlying chain | Bare reserve | Reward token |
  |---|---|---|---|---|
  | `stkwaEthUSDC.v1` | `0x6bf183243FdD1e306ad2C4450BC7dcf6f0bf8Aa6` | stk → waEthUSDC → USDC | USDC | aEthUSDC (→ USDC) |
  | `stkwaEthUSDT.v1` | `0xA484Ab92fe32B143AEE7019fC1502b1dAA522D31` | stk → waEthUSDT → USDT | USDT | aEthUSDT (→ USDT) |
  | `stkwaEthWETH.v1` | `0xaAFD07D53A7365D3e9fb6F3a3B09EC19676B73Ce` | stk → waEthWETH → WETH | WETH | aEthWETH (→ WETH) |
  | `stkGHO.v1` | `0x4f827A63755855cDf3e8f3bcD20265C833f15033` | stk → GHO (one hop) | GHO | GHO (plain) |

- **Math branches** (per stake token, summed onto the bare reserve):
  - **Staking leg(s)** — `balanceOf(account)` shares → `convertToAssets` → at most one further ERC4626 wrapper hop (`stk → waToken → bare reserve`, or `stk → bare reserve` for `stkGHO`). `PositionKind.Staking`, `isDebt = false`. `getAdapterPositions` further **splits the principal by withdrawability** via Umbrella's per-user cooldown snapshot (`getStakerCooldown`): a locked leg (`isLocked = true` — active stake plus any cooldown still cooling or past its withdrawal window) and an unlocked leg (`isLocked = false` — a cooldown that has elapsed and is inside its withdrawal window). Both share `positionId = abi.encode(stakeToken)` and are told apart by `isLocked`, so a stake token can emit up to two Staking legs. The balance methods (`getAdapterBalanceForAsset` / `getAdapterBalances`) ignore the split and report the full staked principal.
  - **Rewards leg** — `RewardsController.calculateCurrentUserRewards`, each reward token mapped to its bare reserve via `IAToken.UNDERLYING_ASSET_ADDRESS()` (or itself for plain tokens like GHO). `PositionKind.Rewards`, `isDebt = false`.
  - Zero-amount legs are skipped; a stake token may emit a Rewards leg with no Staking leg (unstaked but unclaimed rewards) or vice-versa. Worst case is three legs per stake token (locked Staking + unlocked Staking + Rewards).

## 2. Existing fork test coverage

`test/balances/BalanceAdapters/fork/AaveUmbrellaBalanceAdapter.fork.t.sol` → `AaveUmbrellaBalanceAdapterForkTest` already covers, at the pinned block, against four real holders (one per stake token):
- holders have non-zero stake balances; `underlyingAssetsSupported` dedupes to the registered bare reserves;
- every stake token reports the same RewardsController;
- per-holder `getAdapterBalanceForAsset` equals an independent staked+rewards recomputation (§8);
- `getAdapterPositions` emits the Staking + Rewards legs (incl. the same-asset stkGHO case where both legs are GHO);
- the assetFilter restricts/excludes correctly; `getAdapterBalances` returns one entry per underlying.

All kept as regression nets.

## 3. What this case adds

- **Mock-based unit test** (`test/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.t.sol` → `AaveUmbrellaBalanceMathTest`, + `test/balances/BalanceAdapters/AaveUmbrellaMocks.sol`) — closes the both-unit-and-fork convention gap. Drives the ERC4626 walk (two-hop vs one-hop), reward bare-reserve resolution (aToken vs plain), leg emission/identity, the cooldown-driven locked/unlocked Staking split (`isLocked`), zero-leg skipping, dedup across stake tokens sharing a reserve, and the documented asymmetry (balance methods report an unregistered reserve; `getAdapterPositions` skips it). 13 tests, no fork. (The same file also carries the 10 early-exit / constructor / ERC165 tests in `AaveUmbrellaBalanceAdapterTest`, for 23 unit tests total.)
- **Fork block** set to the verification block `25_287_877` — the fork test and this README's §7 figures pin the **same** block. The live dev-anvil dashboard (§9) forks at *latest* and is a sanity check that drifts from these numbers by design.
- This evidence pack: the per-leg ground truth for a comprehensive all-four-stake-token holder, plus a dashboard wiring helper.

## 4. Adapter formula recap

For each stake token `stk` in `getAllAssets()` whose resolved bare reserve is registered on NAV:

```python
# Staking leg(s) — split by withdrawability in getAdapterPositions
shares  = stk.balanceOf(account)
(amount, endOfCooldown, withdrawalWindow) = stk.getStakerCooldown(account)
cooldownShares = min(amount, shares)
inWindow       = endOfCooldown <= now <= endOfCooldown + withdrawalWindow
unlockedShares = inWindow ? cooldownShares : 0     # withdrawable now
lockedShares   = shares - unlockedShares           # active stake + cooling/expired cooldown

def toBareReserve(s):
    staked = stk.convertToAssets(s)                # shares -> first-level asset
    first  = stk.asset()
    if isErc4626Wrapper(first):                    # stkwaEth* family
        staked = first.convertToAssets(staked)     # waToken -> bare reserve
    return staked                                  # else first IS the bare reserve (stkGHO)

emit (bareReserve, amount=toBareReserve(lockedShares),   Staking, isLocked=true,  isDebt=false)   if > 0
emit (bareReserve, amount=toBareReserve(unlockedShares), Staking, isLocked=false, isDebt=false)   if > 0

# Rewards leg
(tokens, amounts) = RewardsController.calculateCurrentUserRewards(stk, account)
reward = sum(amounts[i] where resolveBareReserve(tokens[i]) == bareReserve)
emit (bareReserve, amount=reward, Rewards, isLocked=false, isDebt=false)    if reward > 0

# positionId = abi.encode(stk); positionInstanceId = bytes32(0)
# protocolBrand=keccak256("aave"); protocolId=keccak256("aave-v3"); protocolSubId=keccak256("aave-v3-umbrella")
```

Slashing-correct automatically: Umbrella stake tokens reduce `totalAssets` (not `totalSupply`) on slash, so the chained `convertToAssets` is post-slash-correct. Cooldown / unstake-window state does not affect `balanceOf`, so principal is always reported in full.

## 5. Cherry-picked accounts

| Holder | Address | Rationale |
|---|---|---|
| `STK_WA_WETH_HOLDER` | `0x000000000004444c5dc75cB358380D2e3dE08A90` | **Holds all four stake tokens** → 8 legs (Staking + Rewards across USDC, USDT, WETH, GHO). Exercises both the two-hop wa-walk (USDC/USDT/WETH) and the one-hop GHO walk, plus aToken-reward and plain-GHO-reward resolution in one account. |
| `STK_GHO_HOLDER` | `0x6Ca0D65fe5c8700a5cc7A2C3bfE801111A1dEd1a` | stkGHO staking + rewards **both in GHO** → two GHO entries distinguished only by `positionKind` (the same-asset disambiguation). Also a stkwaEthUSDT **rewards-only** leg (unstaked, unclaimed) → exercises the no-Staking-leg branch. |
| `STK_WA_USDC_HOLDER` | `0xd0002c648CCa8DeE2f2b8D70D542Ccde8ad6EC03` | Clean single-stake-token holder (stkwaEthUSDC): one Staking + one Rewards leg, both USDC. |
| `STK_WA_USDT_HOLDER` | `0x7FE4b2632f5AE6d930677D662AF26Bc0a06672b3` | Holds stkwaEthUSDC **and** stkwaEthUSDT → two reserves, four legs. |

### Setup

| Field | Value |
|---|---|
| Chain | Ethereum mainnet (chainId 1) |
| Block | **25,287,877** |
| Block timestamp | 1781104487 (`0x6a297f67`) — **2026-06-10 15:14:47 UTC** |
| RewardsController (trust anchor) | `0x4655Ce3D625a63d30bA704087E52B4C31E38188B` |
| Adapter under test | `AaveUmbrellaBalanceAdapter` |
| Fork-test contract | `AaveUmbrellaBalanceAdapterForkTest` in `test/balances/BalanceAdapters/fork/AaveUmbrellaBalanceAdapter.fork.t.sol` |
| Unit-test contract | `AaveUmbrellaBalanceMathTest` in `test/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.t.sol` |

## 6. Case files in this folder

| File | Purpose |
|---|---|
| `case-stake-holders-mainnet.json` | Machine-readable evidence pack: holders, per-leg amounts, kinds, positionIds, ground-truth method |
| `query-live-balances.s.sol` | Forge script that deploys the adapter against a dev NAV and prints the per-leg breakdown for ad-hoc cross-checks |
| `script/development/deploy/deploy-aave-umbrella.sh` | Dev-anvil deploy helper: `forge create` the adapter + `addBalanceAdapters([adapter])` on the local NAV |

## 7. Expected balances

Captured at the fork block in §5. The fork test does **not** hardcode `EXPECTED_*` constants — it recomputes each holder's staked + rewards independently and asserts equality (§8); the amounts below are the captured reference (the aToken-backed wrappers + reward accrual drift per block).

### 7a. Per-leg detail (every emission the adapter makes — `STK_WA_WETH_HOLDER`, all four stake tokens)

| Stake token | Leg | Reserve | Amount (raw) | Amount (humanised) | positionId (decoded) |
|---|---|---|---|---|---|
| stkwaEthUSDC.v1 | Staking | USDC | `1881856985` | 1,881.856985 USDC | `0x6bf1…8Aa6` |
| stkwaEthUSDC.v1 | Rewards | USDC | `72340636` | 72.340636 USDC | `0x6bf1…8Aa6` |
| stkwaEthUSDT.v1 | Staking | USDT | `798477344` | 798.477344 USDT | `0xA484…2D31` |
| stkwaEthUSDT.v1 | Rewards | USDT | `67947101` | 67.947101 USDT | `0xA484…2D31` |
| stkwaEthWETH.v1 | Staking | WETH | `2718960276623852900` | 2.718960276623852900 WETH | `0xaAFD…73Ce` |
| stkwaEthWETH.v1 | Rewards | WETH | `44128310175509233` | 0.044128310175509233 WETH | `0xaAFD…73Ce` |
| stkGHO.v1 | Staking | GHO | `321722605569835228164` | 321.722605569835228164 GHO | `0x4f82…5033` |
| stkGHO.v1 | Rewards | GHO | `48878864883629751593` | 48.878864883629751593 GHO | `0x4f82…5033` |

### 7b. Per-asset summary (what `getAdapterBalanceForAsset` returns — `STK_WA_WETH_HOLDER`)

| Reserve | Total (raw) | Total (humanised) | isDebt |
|---|---|---|---|
| USDC | `1954197621` | 1,954.197621 USDC | false |
| USDT | `866424445` | 866.424445 USDT | false |
| WETH | `2763088586799362133` | 2.763088586799362133 WETH | false |
| GHO | `370601470453464979757` | 370.601470453464979757 GHO | false |

Other holders (per-asset totals): `STK_WA_USDC_HOLDER` → USDC `208367191` (202.55 staked + 5.82 rewards); `STK_GHO_HOLDER` → GHO `35501036047087010165164` (35,470.32 staked + 30.71 rewards) + USDT `26123858` (rewards-only); `STK_WA_USDT_HOLDER` → USDC `495286834392` + USDT `1626617315619`.

## 8. Ground-truth cross-check

`test_stkwaEth*_balance_matchesAdapterDiscovery` / `test_stkGHO_balance_matchesAdapterDiscovery` recompute each holder's value along the **same walk the adapter takes but via independent interface reads**, then assert equality with `getAdapterBalanceForAsset`:

| Leg | Recomputed independently as |
|---|---|
| Staking | `stk.balanceOf` → `stk.convertToAssets` → (if `stk.asset()` is an ERC4626) `waToken.convertToAssets` |
| Rewards | `RewardsController.calculateCurrentUserRewards`, each reward token mapped to its bare reserve via `UNDERLYING_ASSET_ADDRESS()` |

This is an **in-EVM cross-check** at the forked block (same archive state, zero derivation drift). **Why no Python:** the value is a chained `convertToAssets` of live on-chain balances — there is no closed-form re-derivation to do (unlike the Uniswap V2 dilution math); the strongest available ground truth is the protocol's own conversion functions read along an independent path. These cross-check tests assert only the summed `getAdapterBalanceForAsset`; the identity assertions (`protocolSubId == aave-v3-umbrella`, `protocolId == aave-v3`, `positionId == abi.encode(stakeToken)`, and the per-leg `PositionKind`) live in the `getAdapterPositions` tests — the unit test `test_getAdapterPositions_emitsStakingAndRewardsLegsWithIdentity` covers all of them, and the fork `getAdapterPositions` tests cover `PositionKind` + `balanceAdapter`.

## 9. Wiring the live dev-anvil dashboard

`script/development/deploy/deploy-aave-umbrella.sh` deploys + registers the adapter on the local mainnet anvil so the dashboard renders the holders' Umbrella positions for a side-channel cross-check. Run after the dev anvil is up and the NAV proxy is deployed:

```bash
bash script/development/anvil/start-forks.sh 1     # fresh fork at latest
bash script/development/deploy/deploy.sh 1         # NAV + Chainlink assets (incl. GHO)
bash script/development/deploy/deploy-aave-umbrella.sh 1
bash script/development/app/sync-app-env.sh 1
# then start the Next.js dev server in app/
```

`start-forks.sh` forks at the **latest** block (not pinned to `25_287_877`), and the staked amounts come from `convertToAssets` on the aToken-backed wrappers (which accrue every block), so the dashboard values read marginally higher than §7's pinned numbers — an expected, sub-bp live-drift sanity check, not a mismatch. For strict alignment, fork anvil at the pinned block directly (`anvil --fork-url <rpc> --fork-block-number 25287877`).

The deployed adapter address is recorded in `script/development/state/1-addresses.json`. Each Umbrella position renders under **Aave Umbrella** with a **Staking** and a **Rewards** leg per stake token, denominated in the bare reserve (USDC/USDT/WETH/GHO). GHO is a Chainlink-priced reserve so stkGHO renders; all four reserves are registered by `register-assets.sh`.

## 10. Test verdict

| Aspect | Status |
|---|---|
| Discovery: `getAllAssets` → bare reserves (two-hop wa-walk + one-hop GHO), deduped | ✅ |
| Staking leg == independent `convertToAssets` walk | ✅ |
| Rewards leg == `calculateCurrentUserRewards` mapped to bare reserve (aToken + plain) | ✅ |
| Same-asset stkGHO: Staking + Rewards both GHO, distinguished by `positionKind` | ✅ |
| Identity: `positionId == abi.encode(stakeToken)`, `protocolSubId == aave-v3-umbrella`, `protocolId == aave-v3` | ✅ |
| Cooldown-driven Staking split: locked (`isLocked=true`) + unlocked (`isLocked=false`) legs share `positionId` | ✅ |
| Zero-leg skip / rewards-only leg / assetFilter | ✅ |
| Unregistered-reserve skip in `getAdapterPositions` (balance methods still report it) | ✅ |

**Mainnet: 12 / 12 fork + 23 / 23 unit tests pass.** Single mainnet deployment → no cross-chain surface. Aave Umbrella is verified.

Run via:

```bash
forge test --match-path "test/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.t.sol"
FOUNDRY_PROFILE=slow forge test --match-path "test/balances/BalanceAdapters/fork/AaveUmbrellaBalanceAdapter.fork.t.sol" -vv
```
