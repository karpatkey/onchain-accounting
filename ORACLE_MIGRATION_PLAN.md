# Oracle Migration Plan — karpatkey-tokenized-fund → onchain-accounting

> **Branch**: `feat/oracle-migration`
> **Source repo**: `karpatkey-tokenized-fund/contracts` (NAV v1)
> **Target repo**: `onchain-accounting` (NAV v2)
> **Goal**: Port all Price Oracles and Balance Oracles — **with passing tests** — so NAV v2 has full parity.

---

## Already-migrated oracles may be outdated — always diff first

> **This applies every single time you touch an oracle that already exists in `onchain-accounting`.**

The 10 balance oracles and 4 price oracles already present in this repo were migrated at a point in time. Since then, the source repo (`karpatkey-tokenized-fund/contracts`, branch `usd-alpha-fund-deploy-scripts` or `old-nav`) may have received bug fixes, logic improvements, or new reward/position handling that were never back-ported here.

**Before writing a single line of code on any already-migrated oracle:**
1. Read the current implementation in `onchain-accounting`
2. Read the latest implementation in `karpatkey-tokenized-fund/contracts` (`usd-alpha-fund-deploy-scripts` or `old-nav`)
3. Diff them explicitly — do not rely on memory or assumptions
4. Decide for each difference whether to keep, back-port, or merge (document the decision)

Skipping this step risks shipping a stale oracle that silently under-reports balances or uses outdated math.

---

## Tests are not optional — they are the migration

The source repo has fork-based tests for every single oracle. These tests hit real on-chain state (real Aave positions, real Curve gauges, real Chainlink feeds) and are the **primary proof that a migration is correct**. An oracle without passing tests is not considered migrated, regardless of whether the code compiles.

**Every oracle migration is only complete when:**
1. `forge build` passes clean (no errors, no warnings in oracle files)
2. The **unit test** passes (`forge test --match-path "test/.../OracleName.t.sol"`)
3. The **fork test** passes (`forge test --match-path "test/.../fork/OracleName.fork.t.sol"`)

Do not move to the next oracle until all three pass.

---

## How to read this document

- Each item is a discrete, verifiable unit of work.
- Work through phases in order — each phase builds on the previous.
- Mark items `[x]` as you complete them.
- Each oracle has three sub-tasks: implementation, unit test, fork test. All three must be checked off.

---

## Interface changes cheat-sheet

### Price oracles — minimal change

The function signatures are **identical** between v1 and v2. Only the interface name/import changes.

| Change | From (v1) | To (v2) |
|--------|-----------|---------|
| Import | `IPriceOracleCustom` | `IPriceFeedCustom` |
| Inherits | `is IPriceOracleCustom` | `is IPriceFeedCustom` |
| ERC165 ID | `type(IPriceOracleCustom).interfaceId` | `type(IPriceFeedCustom).interfaceId` |
| Logic | unchanged | unchanged |

### Balance oracles — significant rewrite

| Aspect | v1 (`IBalanceOracleCustom`) | v2 (`IBalanceOracleAdapter`) |
|--------|----------------------------|------------------------------|
| Main function | `balanceOf(address asset, address account) returns (int256)` | `getOraclePositions(address account, address assetFilter) returns (PositionBalance[])` |
| Additional functions | `underlyingAssetsSupported()`, `positionMetadata()` | `getOracleBalances(account)`, `getOracleBalanceForAsset(account, asset)`, `underlyingAssetsSupported()` |
| Debt representation | negative `int256` | `uint256 amount + bool isDebt` |
| Metadata | `PositionMetadata { protocol, position, positionType }` | `protocol` + `positionDetail` strings inside `PositionBalance` |
| NAVCalculator ref | not required | `INAVCalculator public immutable navCalculator` (constructor param) |
| Asset filtering | not required | `ArrayLib.intersection()` of supported vs registered assets |

**Pattern all v2 balance oracles follow:**
```solidity
contract XyzBalanceOracle is IBalanceOracleAdapter {
    INAVCalculator public immutable navCalculator;
    // ...protocol-specific immutables...

    constructor(address navCalculator_, ...) {
        navCalculator = INAVCalculator(navCalculator_);
        // validate + store other params
    }

    function getOraclePositions(address account, address assetFilter)
        external view returns (INAVCalculator.PositionBalance[] memory)
    {
        // filter: intersection of _supported assets and navCalculator.getRegisteredAssets()
        // build PositionBalance[] using _buildPositions() internal helper
    }

    function getOracleBalances(address account)
        external view returns (address[] memory, uint256[] memory, bool[] memory)
    {
        // flatten getOraclePositions into parallel arrays
    }

    function getOracleBalanceForAsset(address account, address asset)
        external view returns (uint256 amount, bool isDebt)
    {
        // single-asset optimized path
    }

    function underlyingAssetsSupported() external view returns (address[] memory) { ... }
    function supportsInterface(bytes4 id) external pure returns (bool) { ... }
}
```

Reference implementations to follow: `AaveV3Instance.sol`, `MorphoMarket.sol`, `DaiDsr.sol`.

---

## PR strategy

5 PRs total, each targeting `main` in `onchain-accounting`, merged in order.

| PR | Content | Phases |
|---|---|---|
| **PR 1** — Surgical changes | GMX deletion + AaveV3Instance reward removal | Phase 3 (partial) |
| **PR 2** — Price oracles | All 16 missing price oracles + tests | Phase 1 |
| **PR 3** — Simple balance oracles | MorphoVault, GearboxMarket, Cap + tests | Phase 2a + 2b |
| **PR 4** — Curve | Curve oracle + tests | Phase 2c (partial) |
| **PR 5** — Convex | Convex oracle + tests | Phase 2c (partial) |

> PR 5 depends on PR 4 being merged (Convex shares pool-token logic with Curve).
> Phase 3 reconciliation of existing migrations is spread across PRs — PR 1 handles AaveV3Instance, the rest are reconciled as part of each related PR or as standalone work. Each PR must leave the test suite fully green before merging.

---

## Phase 0 — Setup & verification

- [x] Create branch `feat/oracle-migration` in `onchain-accounting`
- [x] `forge build` passes clean — "Nothing to compile" (already up to date)
- [x] Non-fork test baseline: **605 passed, 3 failed** after PR 1 (GMX deletion removed 3 test files; 3 failures are script deploy tests requiring RPC URL — pre-existing, not oracle-related)
- [ ] Fork test baseline: `FOUNDRY_PROFILE=slow forge test --match-path "test/**/fork/*.sol"` — record pass count (requires RPC URLs in `.env`)
- [x] Protocol interfaces check — all interfaces are defined **inline** within each oracle file; no lib additions needed:
  - Curve: `ICurveLPToken`, `ICurveGauge`, `ICurveMinter` — defined inline in `Curve.sol`
  - Convex: `IConvexRewarder`, `IRewardsDistributor`, `IConvexToken` etc. — defined inline in `Convex.sol`
  - Gearbox: `IVault` — defined inline in `GearboxMarket.sol`
  - Cap: `ICUsd`, `IStcUSD` — defined inline in `Cap.sol`
  - ETH+: `IRToken`, `IMain`, `IBasketHandler` — defined inline in `ETHPlus_Price.sol`
- [ ] Confirm `.env` has all required RPC URLs for fork tests: `MAINNET_URL`, `ARBITRUM_URL`, `BASE_URL`, `OP_URL`, `GNOSIS_URL`

---

## Phase 1 — Price oracles (16 missing)

All price oracles share the same migration recipe:
1. Copy source file, update interface import/name/ERC165 ID
2. Verify constructor args (same as source)
3. Port unit test following `sDAI_Price.t.sol` pattern
4. Port fork test following `sDAI_Price.fork.t.sol` pattern
5. `forge build && forge test --match-path "test/prices/protocols/OracleName*"` — must pass before moving on
6. Add `_deployXxx()` function to `03_DeployPriceFeeds.s.sol` + wire into the correct chain's `_deployChainPriceAdapters()` — the script must still compile (`forge build`) after the addition

**Deploy script pattern** (`03_DeployPriceFeeds.s.sol`):
- Add import at top
- Add `_deployIfEnabled` call inside the correct chain function (`_deployMainnetPriceAdapters`, `_deployArbitrumPriceAdapters`, etc.)
- Add `_deployXxx()` function reading params via `ConfigReader.readPriceFeedParam()` and calling `ConfigReader.writeAdapterAddress()`
- Follow `_deploySdai()` / `_deployLdo()` as reference

### What price oracle tests must cover (for every oracle)

**Unit test** (`OracleName.t.sol`):
- [ ] `test_constructor_invalidArgs` — reverts on zero address / invalid heartbeat
- [ ] `test_decimals` — returns expected decimals (usually 8)
- [ ] `test_underlyingAssetSupported` — returns the correct token address
- [ ] `test_supportsInterface` — ERC165 returns true for `IPriceFeedCustom` and `IERC165`

**Fork test** (`OracleName.fork.t.sol`):
- [ ] `test_getLatestPrice` — returns a non-zero price and `stale = false` at the pinned block
- [ ] `test_getLatestPrice_stale` — `vm.warp` past heartbeat; returns `stale = true`
- [ ] `test_decimals` — matches expected value on real chain
- [ ] `test_underlyingAssetSupported` — returns correct on-chain token address
- [ ] (where applicable) `test_price_sanity` — price is within a reasonable USD range (e.g. ETH between $1000–$10000)

### 1a — ERC4626 pattern (simplest)

These use `convertToAssets(1e18)` for the exchange rate. Logic is trivial; mainly an interface rename.

- [ ] **`sUSDe_Price.sol`** — USDe/USD (Chainlink) × sUSDe/USDe (ERC4626)
  - Source: `src/prices/protocols/sUSDe_Price.sol`
  - [ ] Implementation
  - [ ] Unit test: `test/prices/protocols/sUSDe_Price.t.sol`
  - [ ] Fork test: `test/prices/protocols/fork/sUSDe_Price.fork.t.sol`
  - [ ] `forge test --match-path "test/prices/protocols/sUSDe*"` passes ✓
  - [ ] Deploy script: `_deploySusde()` added to `_deployMainnetPriceAdapters()` in `03_DeployPriceFeeds.s.sol`

- [ ] **`syrupUSDC_Price.sol`** — USDC/USD (Chainlink) × syrupUSDC/USDC (ERC4626)
  - Source: `src/prices/protocols/syrupUSDC_Price.sol`
  - [ ] Implementation
  - [ ] Unit test: `test/prices/protocols/syrupUSDC_Price.t.sol`
  - [ ] Fork test: `test/prices/protocols/fork/syrupUSDC_Price.fork.t.sol`
  - [ ] `forge test --match-path "test/prices/protocols/syrupUSDC*"` passes ✓
  - [ ] Deploy script: `_deploySyrupUsdc()` added to `_deployMainnetPriceAdapters()` in `03_DeployPriceFeeds.s.sol`

### 1b — On-chain rate × Chainlink ETH/USD

Pattern: `price = protocolRate(18 dec) × ETH/USD(8 dec) / 1e18 → 8 dec`

- [ ] **`wstETH_Price.sol`** — `IWstETH.stEthPerToken()` × ETH/USD
  - Source: `src/prices/protocols/wstETH_Price.sol`
  - Constructor: `(wstETH, ethToUsdChainlink, ethToUsdHeartbeat)`
  - [ ] Implementation
  - [ ] Unit test: `test/prices/protocols/wstETH_Price.t.sol`
  - [ ] Fork test: `test/prices/protocols/fork/wstETH_Price.fork.t.sol`
  - [ ] `forge test --match-path "test/prices/protocols/wstETH_Price*"` passes ✓
  - [ ] Deploy script: `_deployWsteth()` added to `_deployMainnetPriceAdapters()` in `03_DeployPriceFeeds.s.sol`

- [ ] **`rETH_Price.sol`** — `IRocketTokenRETH.getExchangeRate()` × ETH/USD
  - Source: `src/prices/protocols/rETH_Price.sol`
  - [ ] Implementation
  - [ ] Unit test: `test/prices/protocols/rETH_Price.t.sol`
  - [ ] Fork test: `test/prices/protocols/fork/rETH_Price.fork.t.sol`
  - [ ] `forge test --match-path "test/prices/protocols/rETH_Price*"` passes ✓
  - [ ] Deploy script: `_deployReth()` added to `_deployMainnetPriceAdapters()` in `03_DeployPriceFeeds.s.sol`

- [ ] **`cbETH_Price.sol`** — `ICbETH.exchangeRate()` × ETH/USD
  - Source: `src/prices/protocols/cbETH_Price.sol`
  - [ ] Implementation
  - [ ] Unit test: `test/prices/protocols/cbETH_Price.t.sol`
  - [ ] Fork test: `test/prices/protocols/fork/cbETH_Price.fork.t.sol`
  - [ ] `forge test --match-path "test/prices/protocols/cbETH_Price.t*"` passes ✓
  - [ ] Deploy script: `_deployCbeth()` added to `_deployMainnetPriceAdapters()` in `03_DeployPriceFeeds.s.sol`

- [ ] **`eETH_Price.sol`** — `(weETH/ETH Chainlink) ÷ (weETH/eETH ratio)` × ETH/USD
  - Source: `src/prices/protocols/eETH_Price.sol`
  - Note: eETH has no direct Chainlink feed; price derived from weETH oracle
  - [ ] Implementation
  - [ ] Unit test: `test/prices/protocols/eETH_Price.t.sol`
  - [ ] Fork test: `test/prices/protocols/fork/eETH_Price.fork.t.sol`
  - [ ] `forge test --match-path "test/prices/protocols/eETH_Price*"` passes ✓
  - [ ] Deploy script: `_deployEeth()` added to `_deployMainnetPriceAdapters()` in `03_DeployPriceFeeds.s.sol`

- [ ] **`weETH_Price.sol`** — Chainlink weETH/ETH × Chainlink ETH/USD
  - Source: `src/prices/protocols/weETH_Price.sol`
  - [ ] Implementation
  - [ ] Unit test: `test/prices/protocols/weETH_Price.t.sol`
  - [ ] Fork test: `test/prices/protocols/fork/weETH_Price.fork.t.sol`
  - [ ] `forge test --match-path "test/prices/protocols/weETH_Price.t*"` passes ✓
  - [ ] Deploy script: `_deployWeeth()` added to `_deployMainnetPriceAdapters()` in `03_DeployPriceFeeds.s.sol`

- [ ] **`rsETH_Price.sol`** — Kelp DAO `IRateProvider.getLatestRate()` × ETH/USD
  - Source: `src/prices/protocols/rsETH_Price.sol`
  - [ ] Implementation
  - [ ] Unit test: `test/prices/protocols/rsETH_Price.t.sol`
  - [ ] Fork test: `test/prices/protocols/fork/rsETH_Price.fork.t.sol`
  - [ ] `forge test --match-path "test/prices/protocols/rsETH_Price.t*"` passes ✓
  - [ ] Deploy script: `_deployRseth()` added to `_deployMainnetPriceAdapters()` in `03_DeployPriceFeeds.s.sol`

### 1c — L2 variants (Chainlink × Chainlink)

These use two Chainlink feeds (asset/ETH × ETH/USD). Minimal logic, but fork tests **must run against the correct L2 chain** — not Mainnet.

- [ ] **`wstETH_L2_Price.sol`** — Chainlink wstETH/ETH × ETH/USD
  - Source: `src/prices/protocols/wstETH_L2_Price.sol`
  - Note: Optimism uses Aave ratio provider instead of Chainlink for wstETH/ETH — same contract, different constructor path
  - [ ] Implementation
  - [ ] Unit test: `test/prices/protocols/wstETH_L2_Price.t.sol`
  - [ ] Fork test: `test/prices/protocols/fork/wstETH_L2_Price.fork.t.sol` (fork Arbitrum or Base)
  - [ ] `forge test --match-path "test/prices/protocols/wstETH_L2_Price*"` passes ✓
  - [ ] Deploy script: `_deployWstethL2()` added to `_deployArbitrumPriceAdapters()` + `_deployBasePriceAdapters()` + `_deployOptimismPriceAdapters()` as applicable in `03_DeployPriceFeeds.s.sol`

- [ ] **`cbETH_L2_Price.sol`** — Chainlink cbETH/ETH × ETH/USD
  - Source: `src/prices/protocols/cbETH_L2_Price.sol`
  - [ ] Implementation
  - [ ] Unit test: `test/prices/protocols/cbETH_L2_Price.t.sol`
  - [ ] Fork test: `test/prices/protocols/fork/cbETH_L2_Price.fork.t.sol` (fork Base — cbETH most liquid there)
  - [ ] `forge test --match-path "test/prices/protocols/cbETH_L2*"` passes ✓
  - [ ] Deploy script: `_deployCbethL2()` added to `_deployBasePriceAdapters()` in `03_DeployPriceFeeds.s.sol`

- [ ] **`weETH_L2_Price.sol`** — Chainlink weETH/eETH × ETH/USD (eETH ≈ ETH 1:1 assumption)
  - Source: `src/prices/protocols/weETH_L2_Price.sol`
  - [ ] Implementation
  - [ ] Unit test: `test/prices/protocols/weETH_L2_Price.t.sol`
  - [ ] Fork test: `test/prices/protocols/fork/weETH_L2_Price.fork.t.sol`
  - [ ] `forge test --match-path "test/prices/protocols/weETH_L2*"` passes ✓
  - [ ] Deploy script: `_deployWeethL2()` added to applicable L2 chain functions in `03_DeployPriceFeeds.s.sol`

- [ ] **`rsETH_L2_Price.sol`** — Chainlink rsETH/ETH × ETH/USD
  - Source: `src/prices/protocols/rsETH_L2_Price.sol`
  - [ ] Implementation
  - [ ] Unit test: `test/prices/protocols/rsETH_L2_Price.t.sol`
  - [ ] Fork test: `test/prices/protocols/fork/rsETH_L2_Price.fork.t.sol`
  - [ ] `forge test --match-path "test/prices/protocols/rsETH_L2*"` passes ✓
  - [ ] Deploy script: `_deployRsethL2()` added to applicable L2 chain functions in `03_DeployPriceFeeds.s.sol`

- [ ] **`ezETH_L2_Price.sol`** — `IxRenzoDeposit.getRate()` × ETH/USD
  - Source: `src/prices/protocols/ezETH_L2_Price.sol`
  - Note: L2 uses xRenzoDeposit rate bridge, not RestakeManager (different from Mainnet ezETH)
  - [ ] Implementation
  - [ ] Unit test: `test/prices/protocols/ezETH_L2_Price.t.sol`
  - [ ] Fork test: `test/prices/protocols/fork/ezETH_L2_Price.fork.t.sol`
  - [ ] `forge test --match-path "test/prices/protocols/ezETH_L2*"` passes ✓
  - [ ] Deploy script: `_deployEzethL2()` added to applicable L2 chain functions in `03_DeployPriceFeeds.s.sol`

- [ ] **`syrupUSDC_L2_Price.sol`** — Chainlink syrupUSDC/USDC × USDC/USD
  - Source: `src/prices/protocols/syrupUSDC_L2_Price.sol`
  - [ ] Implementation
  - [ ] Unit test: `test/prices/protocols/syrupUSDC_L2_Price.t.sol`
  - [ ] Fork test: `test/prices/protocols/fork/syrupUSDC_L2_Price.fork.t.sol`
  - [ ] `forge test --match-path "test/prices/protocols/syrupUSDC_L2*"` passes ✓
  - [ ] Deploy script: `_deploySyrupUsdcL2()` added to applicable L2 chain functions in `03_DeployPriceFeeds.s.sol`

### 1d — Complex custom logic

- [ ] **`ezETH_Price.sol`** — `IRestakeManager.calculateTVLs()` / ezETH supply × ETH/USD
  - Source: `src/prices/protocols/ezETH_Price.sol`
  - Note: Uses Renzo RestakeManager; TVL is sum of collateral across all operators
  - Note: Complex overflow risk — review mulDiv usage carefully during port
  - [ ] Implementation
  - [ ] Unit test: `test/prices/protocols/ezETH_Price.t.sol`
  - [ ] Fork test: `test/prices/protocols/fork/ezETH_Price.fork.t.sol`
  - [ ] `forge test --match-path "test/prices/protocols/ezETH_Price.t*"` passes ✓
  - [ ] Deploy script: `_deployEzeth()` added to `_deployMainnetPriceAdapters()` in `03_DeployPriceFeeds.s.sol`

- [ ] **`ETHPlus_Price.sol`** — Reserve protocol basket accounting
  - Source: `src/prices/protocols/ETHPlus_Price.sol`
  - Note: `basketsNeededForRedemption(1e18) × basketPrice / 1e18` — unique pattern, no analogues in existing oracles
  - Note: Verify Reserve protocol interfaces exist in lib/; add minimal interfaces if not
  - [ ] Implementation
  - [ ] Unit test: `test/prices/protocols/ETHPlus_Price.t.sol`
  - [ ] Fork test: `test/prices/protocols/fork/ETHPlus_Price.fork.t.sol`
  - [ ] `forge test --match-path "test/prices/protocols/ETHPlus*"` passes ✓
  - [ ] Deploy script: `_deployEthPlus()` added to `_deployMainnetPriceAdapters()` in `03_DeployPriceFeeds.s.sol`

---

## Phase 2 — Balance oracles (5 missing)

Each requires a full interface rewrite. Follow the pattern from `DaiDsr.sol` (simplest) → `AaveV3Instance.sol` (multi-position) → `BalancerV3.sol` (complex).

**Deploy script pattern** (`04_DeployBalanceAdapters.s.sol`):
- Add import at top
- Add `_deployIfEnabled("AdapterName")` call in `run()`
- Add `if (_startsWith(adapterName, "Prefix_") || _equals(adapterName, "AdapterName"))` branch in `_deployAdapter()`
- Add `_deployXxx()` function reading params via `ConfigReader.readAdapterParam()`
- Follow `_deployDaiDsr()` / `_deployMorphoBlue()` as reference

### What balance oracle tests must cover (for every oracle)

**Unit test** (`OracleName.t.sol`) — extend `BalanceAdapterTestBase`:
- [ ] `test_constructor_invalidArgs` — reverts on zero addresses
- [ ] `test_supportsInterface` — ERC165 returns true for `IBalanceOracleAdapter` and `IERC165`
- [ ] `test_underlyingAssetsSupported` — returns the expected asset array
- [ ] `test_getOracleBalances_unknownAccount` — returns zero balances for an account with no positions
- [ ] `test_getOracleBalanceForAsset_unsupportedAsset` — returns (0, false) for an asset this oracle doesn't handle

**Fork test** (`OracleName.fork.t.sol`) — extend `BalanceAdapterTestBase.fork`:
- [ ] `test_getOraclePositions` — uses a real account with known positions at the pinned block; verifies non-zero amounts and correct `isDebt` flags
- [ ] `test_getOracleBalances` — parallel arrays match `getOraclePositions` results
- [ ] `test_getOracleBalanceForAsset` — single-asset result matches the corresponding entry from `getOraclePositions`
- [ ] `test_underlyingAssetsSupported` — returns correct on-chain addresses
- [ ] (where applicable) `test_debtPosition` — borrowed positions have `isDebt = true`
- [ ] (where applicable) `test_rewardPosition` — reward token positions are present and non-zero

### 2a — ERC4626 vaults (simplest)

Single asset, `convertToAssets(shares)` → one `PositionBalance` per supported asset.

- [ ] **`MorphoVault.sol`** — Morpho ERC4626 vault shares → underlying
  - Source: `src/balances/protocols/MorphoVault.sol`
  - Supported assets: the vault's `asset()` (loan token)
  - Constructor: `(morphoVault, protocol, navCalculator)`
  - Note: Source tests both v1 and v2 vaults — fork test must cover both
  - [ ] Implementation
  - [ ] Unit test: `test/balances/protocols/MorphoVault.t.sol`
  - [ ] Fork test: `test/balances/protocols/fork/MorphoVault.fork.t.sol`
  - [ ] `forge test --match-path "test/balances/protocols/MorphoVault*"` passes ✓
  - [ ] Deploy script: `_deployMorphoVault()` + `MorphoVault_` branch added to `04_DeployBalanceAdapters.s.sol`

- [ ] **`GearboxMarket.sol`** — Gearbox farming pool (ERC4626) → underlying
  - Source: `src/balances/protocols/GearboxMarket.sol`
  - Constructor: `(farmingPool, protocol, navCalculator)`
  - Note: Source tests autocompounding tolerance — document tolerance with a comment in the fork test
  - [ ] Verify Gearbox interfaces exist in lib/ or add minimal `IFarmingPool`
  - [ ] Implementation
  - [ ] Unit test: `test/balances/protocols/GearboxMarket.t.sol`
  - [ ] Fork test: `test/balances/protocols/fork/GearboxMarket.fork.t.sol`
  - [ ] `forge test --match-path "test/balances/protocols/GearboxMarket*"` passes ✓
  - [ ] Deploy script: `_deployGearboxMarket()` + `Gearbox_` branch added to `04_DeployBalanceAdapters.s.sol`

### 2b — Protocol-specific moderate

- [ ] **`Cap.sol`** — Cap Finance cUSD + stcUSD positions → USDC equivalent
  - Source: `src/balances/protocols/Cap.sol`
  - Logic: `cUSD.balanceOf(account)` + `stcUSD.getBurnAmount(stcUSD.balanceOf(account))`
  - Supported assets: USDC (both positions denominated in USDC)
  - Constructor: `(cUSD, stcUSD, protocol, navCalculator)`
  - Note: Two positions per account (cUSD balance + staked cUSD converted to USDC)
  - [ ] Verify Cap interfaces exist in lib/ or add minimal `IStakedCap`
  - [ ] Implementation
  - [ ] Unit test: `test/balances/protocols/Cap.t.sol`
  - [ ] Fork test: `test/balances/protocols/fork/Cap.fork.t.sol`
  - [ ] `forge test --match-path "test/balances/protocols/Cap*"` passes ✓
  - [ ] Deploy script: `_deployCap()` + `Cap_` branch added to `04_DeployBalanceAdapters.s.sol`

### 2c — Complex LP + rewards (hardest)

These have multi-asset positions, reward accrual, and bounded loops. Port last — use the existing `BalancerV3.sol` and `Aura.sol` in this repo as structural reference since they were already upgraded.

- [ ] **`Curve.sol`** — Curve LP positions (unstaked + gauge-staked) + CRV rewards
  - Source: `src/balances/protocols/Curve.sol`
  - Supported assets: all pool tokens (`coins[0..N]`) + CRV + extra reward tokens
  - Constructor: `(gauge, protocol, navCalculator)` — pool derived from `gauge.lp_token()`
  - Key complexity:
    - Unstaked LP: `pool.calc_withdraw_one_coin()` or proportional split
    - Staked LP: `gauge.balanceOf(account)` → same math as unstaked
    - CRV rewards: `integrate_fraction` is **checkpoint-based lower bound** — document clearly in NatSpec and test comments
    - Extra rewards: `gauge.claimable_reward(account, token)` per reward token
    - Bounded loop: `_MAX_ITERATIONS = 8` for pool coins
  - [ ] Verify Curve interfaces exist in lib/ (`ICurveGauge`, `ICurvePool`, `ICurveMinter`)
  - [ ] Implementation
  - [ ] Unit test: `test/balances/protocols/Curve.t.sol`
  - [ ] Fork test: `test/balances/protocols/fork/Curve.fork.t.sol`
    - Must test: unstaked LP position, staked LP position, CRV lower-bound, at least one extra reward token
    - Must use a real account known to hold gauge-staked LP at the pinned block
  - [ ] `forge test --match-path "test/balances/protocols/Curve*"` passes ✓
  - [ ] Deploy script: `_deployCurve()` + `Curve_` branch added to `04_DeployBalanceAdapters.s.sol`

- [ ] **`Convex.sol`** — Convex-staked Curve LP + CRV + CVX rewards
  - Source: `src/balances/protocols/Convex.sol`
  - Supported assets: same pool tokens as underlying Curve pool + CRV + CVX + extras
  - Constructor: `(convexRewards, protocol, navCalculator)` — pool derived from `convexRewards.stakingToken()`
  - Key complexity:
    - LP balance: `convexRewards.balanceOf(account)` → proportional split same as Curve
    - CRV rewards: `convexRewards.earned(account)` (more accurate than Curve gauge — no checkpoint bias)
    - CVX derivation: `earned_CRV → CVX_mint_amount` via Convex cliff schedule
    - Extra rewards: iterate `convexRewards.extraRewardsLength()`
    - Bounded loop: `_MAX_ITERATIONS = 8`
  - **Must be done after Curve** (shares pool-token proportional split logic)
  - [ ] Verify Convex interfaces exist in lib/ (`IConvexRewards`, `IConvexBooster`)
  - [ ] Implementation
  - [ ] Unit test: `test/balances/protocols/Convex.t.sol`
  - [ ] Fork test: `test/balances/protocols/fork/Convex.fork.t.sol`
    - Must test: LP pool token positions, CRV rewards, CVX derived amount, at least one extra reward
  - [ ] `forge test --match-path "test/balances/protocols/Convex*"` passes ✓
  - [ ] Deploy script: `_deployConvex()` + `Convex_` branch added to `04_DeployBalanceAdapters.s.sol`

---

## Phase 3 — Reconcile existing migrations

The 10 balance oracles and 4 price oracles already in `onchain-accounting` were migrated independently and may have **diverged significantly** from the source. Some (e.g. `BalancerV3`, `Aura`) are known to have changed substantially. The `onchain-accounting` version may also simply be **outdated** — the source may have received fixes or additions that were never ported over.

> **Reminder**: see the "Already-migrated oracles may be outdated" section at the top. This entire phase is governed by that rule. Do not skip the diff.

**For each oracle below:**
1. Read the current `onchain-accounting` implementation
2. Read the latest source implementation (`usd-alpha-fund-deploy-scripts` or `old-nav`)
3. Diff them line by line — for every difference, make an explicit decision:
   - **Keep onchain-accounting version** — if it's an intentional improvement or fix; add a comment explaining why it differs
   - **Back-port from source** — if the source has logic that was lost or regressed
   - **Merge both** — if each version has non-overlapping additions
4. Run tests: `forge test --match-path "test/**/OracleName*"` — must pass
5. If tests don't cover a reconciled behaviour: add the missing test case

### Balance oracles to reconcile

- [x] **AaveV3Instance** — diff vs source first; then **remove reward position** (Aave lending rewards inactive)
  - [x] Source diff done. Key decisions: stable debt omitted intentionally (Aave v3 deprecated it — NatSpec comment added); try/catch omitted intentionally (v2 reverts explicitly); collateral label and separate positions are v2 improvements.
  - [x] Unit tests pass (6/6, confirmed PR 1)
  - [x] Fork tests pass (7/7)
  - [x] Deploy script (`04_DeployBalanceAdapters.s.sol`): `rewardsDistributor` param removed from `_deployAaveV3()`
  - [x] Verify script (`VerifyEtherscan.s.sol`): `rewardsDistributor` removed from AaveV3 constructor arg encoding

- [ ] **AaveV3SafetyModule** — diff vs source; staking rewards are the core purpose — do **not** remove them
  - [ ] `forge test --match-path "test/balances/protocols/AaveV3SafetyModule*"` passes ✓
  - [ ] Deploy script: add `_deployAaveV3SafetyModule()` + `AaveV3SafetyModule_` branch to `04_DeployBalanceAdapters.s.sol` (currently missing)

- [x] **SparkLend** — rewards removed (same approach as AaveV3Instance)
  - Source diff done: v1 is a thin wrapper, no logic differences beyond constructor passthrough.
  - Spark's on-chain RewardsController exists but the wstETH/stETH campaign ended Oct 2024. No active campaigns to test against; rewards removed for now, can be re-added if a specific campaign is active.
  - Removed `test_getOracleBalanceForAsset_reward_steth` (user had zero supply/debt at fork block — rewards-only position no longer tracked).
  - [x] Unit tests pass (4/4)
  - [x] Fork tests pass (7/7 after removing rewards test)
  - [x] Deploy script (`04_DeployBalanceAdapters.s.sol`): `rewardsDistributor` param removed from `_deploySparkLend()`
  - [x] Verify script (`VerifyEtherscan.s.sol`): `rewardsDistributor` removed from SparkLend constructor arg encoding

- [ ] **MorphoMarket** — diff vs source; check collateral + loan token dual-asset handling and rounding
  - [ ] `forge test --match-path "test/balances/protocols/MorphoMarket*"` passes ✓
  - [ ] Deploy script: verify existing `_deployMorphoBlue()` constructor params still match after reconciliation

- [ ] **BalancerV3** — **known to have diverged significantly** — thorough diff required
  - Identify every difference: BAL reward checkpoint logic, gauge handling, ERC4626 unwrapping, etc.
  - Document which version's approach is kept and why
  - Ensure tests cover any behaviour unique to the onchain-accounting version
  - [ ] `forge test --match-path "test/balances/protocols/BalancerV3*"` passes ✓
  - [ ] Deploy script: add `_deployBalancerV3()` + `BalancerV3_` branch to `04_DeployBalanceAdapters.s.sol` (currently missing)

- [ ] **Aura** — **known to have diverged significantly** — thorough diff required
  - Identify every difference: CVX cliff schedule, Aura token mint math, reward aggregation
  - Document which version's approach is kept and why
  - Ensure tests cover any behaviour unique to the onchain-accounting version
  - [ ] `forge test --match-path "test/balances/protocols/Aura*"` passes ✓
  - [ ] Deploy script: add `_deployAura()` + `Aura_` branch to `04_DeployBalanceAdapters.s.sol` (currently missing)

- [ ] **DaiDsr** — diff vs source; verify chi accumulation (RAY-precision mulDiv) and drip emulation
  - [ ] `forge test --match-path "test/balances/protocols/DaiDsr*"` passes ✓
  - [ ] Deploy script: verify existing `_deployDaiDsr()` constructor params still match after reconciliation

- [ ] **StakeWiseV3Vault** — diff vs source; verify net position (vault assets − osToken debt)
  - [ ] `forge test --match-path "test/balances/protocols/StakeWiseV3Vault*"` passes ✓
  - [ ] Deploy script: add `_deployStakeWiseV3Vault()` + `StakeWiseV3Vault_` branch to `04_DeployBalanceAdapters.s.sol` (currently missing)

- [ ] **StakeWiseV3OsToken** — diff vs source; verify `convertToAssets` path
  - [ ] `forge test --match-path "test/balances/protocols/StakeWiseV3OsToken*"` passes ✓
  - [ ] Deploy script: add `_deployStakeWiseV3OsToken()` + `StakeWiseV3OsToken_` branch to `04_DeployBalanceAdapters.s.sol` (currently missing)

- [ ] **SkySavingsUsds** — diff vs source; verify ERC4626 `convertToAssets`
  - [ ] `forge test --match-path "test/balances/protocols/SkySavingsUsds*"` passes ✓
  - [ ] Deploy script: verify existing `_deploySkySavingsUsds()` constructor params still match after reconciliation

### Price oracles to reconcile

- [ ] **sDAI_Price** — diff vs source; verify DSR chi math (RAY-precision mulDiv) and staleness logic
  - [ ] `forge test --match-path "test/prices/protocols/sDAI*"` passes ✓
  - [ ] Deploy script: verify existing `_deploySdai()` constructor params still match after reconciliation

- [ ] **sUSDS_Price** — diff vs source; verify ERC4626 exchange rate path and staleness logic
  - [ ] `forge test --match-path "test/prices/protocols/sUSDS*"` passes ✓
  - [ ] Deploy script: verify existing `_deploySusds()` constructor params still match after reconciliation

- [ ] **sXDAI_Price** — diff vs source; verify Gnosis chain-specific path and staleness logic
  - [ ] `forge test --match-path "test/prices/protocols/sXDAI*"` passes ✓
  - [ ] Deploy script: add `_deploySxdai()` to `_deployGnosisPriceAdapters()` in `03_DeployPriceFeeds.s.sol` (currently commented out / missing)

- [ ] **LDO_Price** — diff vs source; verify two-feed cross-rate (LDO/ETH × ETH/USD) and both heartbeats
  - [ ] `forge test --match-path "test/prices/protocols/LDO*"` passes ✓
  - [ ] Deploy script: verify existing `_deployLdo()` constructor params still match after reconciliation

---

## Phase 4 — Integration & cleanup

This is the final gate. **All tests must be green before opening the PR.**

### Full test run
- [ ] `forge build` — zero errors, zero warnings in oracle files and deploy scripts
- [ ] `forge test` — all unit + integration tests pass; test count is ≥ baseline from Phase 0
- [ ] `FOUNDRY_PROFILE=slow forge test --match-path "test/**/fork/*.sol"` — all fork tests pass
- [ ] Compare final pass count vs Phase 0 baseline — the delta must equal the number of new test files added

### Specific oracle test checklist (final confirmation)
Run each group and confirm green:
- [ ] `forge test --match-path "test/prices/protocols/**"` — all 21 price oracle test files pass
- [ ] `forge test --match-path "test/balances/protocols/**"` — all 18 balance oracle test files pass

### Code quality
- [ ] `forge fmt` — formatter passes (no diff)
- [ ] All new oracle files have: correct SPDX header, `pragma solidity 0.8.27`, NatSpec on constructor params
- [ ] CRV lower-bound caveat is documented in `Curve.sol` NatSpec (it was in v1 — must carry over)

### PRs
- [ ] All 5 PRs merged to `main` in `onchain-accounting` (see PR strategy section)
- [ ] Each PR description references this plan document and lists the oracles it covers

---

## Oracle count summary

| Category | Already in onchain-accounting | To migrate | Total after migration |
|----------|-------------------------------|------------|-----------------------|
| Price oracles | 5 (sDAI, sUSDS, sXDAI, LDO, CrossRate) | 16 | 21 |
| Balance oracles | 12 (after GMX deletion: ERC20Default, CompoundV3 + 10 migrated) | 5 | 17 |
| **Total** | **17** | **21** | **38** |

### New items added beyond source (no migration needed)
- `ERC20DefaultOracle` — auto-deployed wallet balance tracker
- `CompoundV3Comet` — new protocol not in source
- `CrossRate_Price` — generic cross-rate utility

### Items to delete from onchain-accounting
- [x] **`src/balances/protocols/GMX.sol`** — deleted in PR 1
- [x] **`test/balances/protocols/GMX.t.sol`** — deleted in PR 1
- [x] **`test/balances/protocols/fork/GMX.fork.t.sol`** — deleted in PR 1
- [x] **`script/deploy/06_Configure.s.sol`** — GMX_GLP removed from both balance adapter name arrays (PR 1 follow-up)
- [x] **`script/test/ConfigReaderTest.t.sol`** — GMX_GLP references replaced with MorphoBlue_USDC (PR 1 follow-up)

---

## Quick reference: source file locations

The authoritative source for oracle implementations is the `usd-alpha-fund-deploy-scripts` branch (or `old-nav`) in `karpatkey-tokenized-fund/contracts`. Always diff against one of these branches, not `main`.

```
karpatkey-tokenized-fund/contracts/   (branch: usd-alpha-fund-deploy-scripts or old-nav)
├── src/
│   ├── prices/protocols/       ← 20 price oracle implementations
│   └── balances/protocols/     ← 15 balance oracle implementations
└── test/
    ├── prices/protocols/       ← 20 price oracle tests
    └── balances/protocols/     ← 15 balance oracle tests
```
