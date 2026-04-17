# Oracle Migration Plan — karpatkey-tokenized-fund → onchain-accounting

> **Status: Completed — archival record as of 2026-04-17.**
> All three PRs (#10, #11, #12) merged to `main`. Oracle migration scope is closed. This document is preserved as the authoritative history of *what* was ported, *why* specific divergences were accepted, and *which* follow-ups remain open.
>
> **For ongoing operational work** (deploying oracles, adding new protocols, registering new assets), see [`script/NAV_V2_DEPLOYMENT_RUNBOOK.md`](script/NAV_V2_DEPLOYMENT_RUNBOOK.md). The runbook is the living doc; this plan is the retrospective.

> **Branches**: stacked PRs — see PR strategy below
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

Stacked PRs — each branch targets the previous one. As each PR merges to `main`, GitHub auto-updates the next PR's base. This gives clean incremental diffs without a separate integration branch.

| PR | GitHub | Branch | Target | Status |
|---|---|---|---|---|
| **PR 1** — Surgical changes | [#10](https://github.com/karpatkey/onchain-accounting/pull/10) | `feat/pr1-surgical-changes` | `main` | **Merged 2026-04-17** (`f97f264`). Scope: GMX removal + stale rewards. |
| **PR 2** — All 16 price oracles (1a/1b/1c/1d) + deploy-script wiring | [#11](https://github.com/karpatkey/onchain-accounting/pull/11) | `feat/pr2-price-oracles` | `main` | **Merged 2026-04-17** (`369efd0`). Scope: all 16 Custom price oracles + L2 deploy wiring + `assets.json.priceFeeds` section + chain config pre-seeds. |
| **PR 3** — All 5 balance oracles + deploy-script wiring | [#12](https://github.com/karpatkey/onchain-accounting/pull/12) | `feat/pr3-balance-oracles` | `main` | **Merged 2026-04-17** (`f32d560`). Scope: MorphoVault, GearboxMarket, Cap, Curve, Convex + 43-instance deploy list + `06_Configure.s.sol` shared-helper alignment + Aura L2 parity + BalancerV3 L2 fork test. |

> Phase 3 reconciliation of existing migrations is spread across PRs — PR 1 handles AaveV3Instance/SparkLend, the rest are reconciled as part of each related PR. Each PR must leave the test suite fully green before merging.
>
> **On scope change (2026-04-16):** while reviewing `NAV_V2_DEPLOYMENT_RUNBOOK.md` we discovered that the per-oracle checklists in Phases 1c/1d did not include a "Deploy script" checkbox (Phases 1a/1b did), and Phase 2 did not track updates to `06_Configure.s.sol` or the full per-instance list for `04_DeployBalanceAdapters.s.sol`. Rather than creating a separate PR 4, the missing deploy-script work is folded back into the PR where the oracle lives (prices → PR 2, balances → PR 3), so each merged PR leaves its oracles actually deployable. See the Phase 1 and Phase 2 addendum sections below for the concrete task lists. Scope is limited to what the **ETH Alpha Fund** and **USD Alpha Fund** actually use — stale v1 entries (expired PT tokens, wound-down markets, unused StakeWise vaults, etc.) are intentionally excluded.

---

## Phase 0 — Setup & verification

- [x] Create branch `feat/oracle-migration` in `onchain-accounting`
- [x] `forge build` passes clean — "Nothing to compile" (already up to date)
- [x] Non-fork test baseline: **624 passed, 1 failed** on `feat/pr1-surgical-changes` (1 pre-existing `invariant_navConsistency` failure on `main` — unrelated to oracle migration)
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

- [x] **`sUSDe_Price.sol`** — USDe/USD (Chainlink) × sUSDe/USDe (ERC4626)
  - Source: `src/prices/protocols/sUSDe_Price.sol`
  - [x] Implementation
  - [x] Unit test: `test/prices/protocols/sUSDe_Price.t.sol` (1/1)
  - [x] Fork test: `test/prices/protocols/fork/sUSDe_Price.fork.t.sol` (4/4, block 24_486_042, price $1.2199)
  - [x] Deploy script: `_deploySusde()` added to `_deployMainnetPriceAdapters()` in `03_DeployPriceFeeds.s.sol`

- [x] **`syrupUSDC_Price.sol`** — USDC/USD (Chainlink) × syrupUSDC/USDC (ERC4626)
  - Source: `src/prices/protocols/syrupUSDC_Price.sol`
  - [x] Implementation
  - [x] Unit test: `test/prices/protocols/syrupUSDC_Price.t.sol` (1/1)
  - [x] Fork test: `test/prices/protocols/fork/syrupUSDC_Price.fork.t.sol` (4/4, block 24_485_547, price $1.1521)
  - [x] Deploy script: `_deploySyrupUsdc()` added to `_deployMainnetPriceAdapters()` in `03_DeployPriceFeeds.s.sol`

### 1b — On-chain rate × Chainlink ETH/USD

Pattern: `price = protocolRate(18 dec) × ETH/USD(8 dec) / 1e18 → 8 dec`

- [x] **`wstETH_Price.sol`** — `IWstETH.stEthPerToken()` × ETH/USD
  - Source: `src/prices/protocols/wstETH_Price.sol`
  - Constructor: `(wstETH, ethToUsdChainlink, ethToUsdHeartbeat)`
  - [x] Implementation
  - [x] Unit test: `test/prices/protocols/wstETH_Price.t.sol` (1/1)
  - [x] Fork test: `test/prices/protocols/fork/wstETH_Price.fork.t.sol` (4/4, block 24_199_054, price $3777.37)
  - [x] Deploy script: `_deployWsteth()` added to `_deployMainnetPriceAdapters()` in `03_DeployPriceFeeds.s.sol`

- [x] **`rETH_Price.sol`** — `IRocketTokenRETH.getExchangeRate()` × ETH/USD
  - Source: `src/prices/protocols/rETH_Price.sol`
  - [x] Implementation
  - [x] Unit test: `test/prices/protocols/rETH_Price.t.sol` (1/1)
  - [x] Fork test: `test/prices/protocols/fork/rETH_Price.fork.t.sol` (4/4, block 24_249_038, price $3785.18)
  - [x] Deploy script: `_deployReth()` added to `_deployMainnetPriceAdapters()` in `03_DeployPriceFeeds.s.sol`

- [x] **`cbETH_Price.sol`** — `ICbETH.exchangeRate()` × ETH/USD
  - Source: `src/prices/protocols/cbETH_Price.sol`
  - [x] Implementation
  - [x] Unit test: `test/prices/protocols/cbETH_Price.t.sol` (1/1)
  - [x] Fork test: `test/prices/protocols/fork/cbETH_Price.fork.t.sol` (4/4, block 24_333_658, price $3389.74)
  - [x] Deploy script: `_deployCbeth()` added to `_deployMainnetPriceAdapters()` in `03_DeployPriceFeeds.s.sol`

- [x] **`eETH_Price.sol`** — `(weETH/ETH Chainlink) ÷ (weETH/eETH ratio)` × ETH/USD
  - Source: `src/prices/protocols/eETH_Price.sol`
  - Note: eETH has no direct Chainlink feed; price derived from weETH oracle
  - [x] Implementation
  - [x] Unit test: `test/prices/protocols/eETH_Price.t.sol` (1/1)
  - [x] Fork test: `test/prices/protocols/fork/eETH_Price.fork.t.sol` (4/4, block 24_412_470, price $2124.29)
  - [x] Deploy script: `_deployEeth()` added to `_deployMainnetPriceAdapters()` in `03_DeployPriceFeeds.s.sol`

- [x] **`weETH_Price.sol`** — Chainlink weETH/ETH × Chainlink ETH/USD
  - Source: `src/prices/protocols/weETH_Price.sol`
  - [x] Implementation
  - [x] Unit test: `test/prices/protocols/weETH_Price.t.sol` (1/1)
  - [x] Fork test: `test/prices/protocols/fork/weETH_Price.fork.t.sol` (4/4, block 24_412_470, price $2310.77)
  - [x] Deploy script: `_deployWeeth()` added to `_deployMainnetPriceAdapters()` in `03_DeployPriceFeeds.s.sol`

- [x] **`rsETH_Price.sol`** — Kelp DAO `IRateProvider.getLatestRate()` × ETH/USD
  - Source: `src/prices/protocols/rsETH_Price.sol`
  - [x] Implementation
  - [x] Unit test: `test/prices/protocols/rsETH_Price.t.sol` (1/1)
  - [x] Fork test: `test/prices/protocols/fork/rsETH_Price.fork.t.sol` (4/4, block 24_327_368, price $3166.54)
  - [x] Deploy script: `_deployRseth()` added to `_deployMainnetPriceAdapters()` in `03_DeployPriceFeeds.s.sol`

### 1c — L2 variants (Chainlink × Chainlink)

These use two Chainlink feeds (asset/ETH × ETH/USD). Minimal logic, but fork tests **must run against the correct L2 chain** — not Mainnet.

- [x] **`wstETH_L2_Price.sol`** — Chainlink wstETH/ETH × ETH/USD
  - Source: `src/prices/protocols/wstETH_L2_Price.sol`
  - Note: Optimism/Gnosis use Aave ratio provider instead of Chainlink — same interface, different constructor address
  - [x] Implementation
  - [x] Unit test: `test/prices/protocols/wstETH_L2_Price.t.sol` (1/1)
  - [x] Fork test: `test/prices/protocols/fork/wstETH_L2_Price.fork.t.sol` (4/4 per chain — Arbitrum block 428_230_165 → $2774.23, Base block 41_671_488 → $2775.59, Optimism block 147_267_078 → $2810.46, Gnosis block 44_492_094 → $2804.98)

- [x] **`cbETH_L2_Price.sol`** — Chainlink cbETH/ETH × ETH/USD
  - Source: `src/prices/protocols/cbETH_L2_Price.sol`
  - [x] Implementation
  - [x] Unit test: `test/prices/protocols/cbETH_L2_Price.t.sol` (1/1)
  - [x] Fork test: `test/prices/protocols/fork/cbETH_L2_Price.fork.t.sol` (4/4, Base block 41_682_714 → $2567.80)

- [x] **`weETH_L2_Price.sol`** — Chainlink weETH/eETH × ETH/USD
  - Source: `src/prices/protocols/weETH_L2_Price.sol`
  - [x] Implementation
  - [x] Unit test: `test/prices/protocols/weETH_L2_Price.t.sol` (1/1)
  - [x] Fork test: `test/prices/protocols/fork/weETH_L2_Price.fork.t.sol` (4/4 per chain — Arbitrum block 428_258_960 → $2414.29, Base block 41_675_313 → $2426.28)

- [x] **`rsETH_L2_Price.sol`** — Chainlink rsETH/ETH × ETH/USD
  - Source: `src/prices/protocols/rsETH_L2_Price.sol`
  - [x] Implementation
  - [x] Unit test: `test/prices/protocols/rsETH_L2_Price.t.sol` (1/1)
  - [x] Fork test: `test/prices/protocols/fork/rsETH_L2_Price.fork.t.sol` (4/4, Arbitrum block 428_316_316 → $2463.39)

- [x] **`ezETH_L2_Price.sol`** — `IxRenzoDeposit.getRate()` × ETH/USD
  - Source: `src/prices/protocols/ezETH_L2_Price.sol`
  - Note: L2 uses xRenzoDeposit rate bridge, not RestakeManager (different from Mainnet ezETH)
  - [x] Implementation
  - [x] Unit test: `test/prices/protocols/ezETH_L2_Price.t.sol` (1/1)
  - [x] Fork test: `test/prices/protocols/fork/ezETH_L2_Price.fork.t.sol` (4/4, Arbitrum block 427_928_961 → $2503.24)

- [x] **`syrupUSDC_L2_Price.sol`** — Chainlink syrupUSDC/USDC × USDC/USD
  - Source: `src/prices/protocols/syrupUSDC_L2_Price.sol`
  - [x] Implementation
  - [x] Unit test: `test/prices/protocols/syrupUSDC_L2_Price.t.sol` (1/1)
  - [x] Fork test: `test/prices/protocols/fork/syrupUSDC_L2_Price.fork.t.sol` (4/4, Arbitrum block 433_494_408 → $1.1521)

### 1d — Complex custom logic

- [x] **`ezETH_Price.sol`** — `IRestakeManager.calculateTVLs()` / ezETH supply × ETH/USD
  - Source: `src/prices/protocols/ezETH_Price.sol`
  - Note: Uses Renzo RestakeManager; TVL is sum of collateral across all operators; try/catch for revert safety
  - [x] Implementation
  - [x] Unit test: `test/prices/protocols/ezETH_Price.t.sol` (1/1)
  - [x] Fork test: `test/prices/protocols/fork/ezETH_Price.fork.t.sol` (4/4, mainnet block 24_328_427 → $3189.30)

- [x] **`ETHPlus_Price.sol`** — Reserve protocol basket accounting
  - Source: `src/prices/protocols/ETHPlus_Price.sol`
  - Note: `basketsNeeded / totalSupply × basketHandler.price().low` — no Chainlink feed, no stale check
  - [x] Implementation
  - [x] Unit test: `test/prices/protocols/ETHPlus_Price.t.sol` (1/1)
  - [x] Fork test: `test/prices/protocols/fork/ETHPlus_Price.fork.t.sol` (3/3 — no stale test, mainnet block 24_277_401 → $3188.46)

---

### Phase 1 addendum — deploy-script wiring (tracked in **PR 2**, added 2026-04-16)

The per-oracle checklists above in groups 1a/1b already had a `Deploy script: _deployXxx()` line that is [x]. Groups **1c (L2 variants)** and **1d (complex custom)** did not include that line, so the work was never tracked. This addendum adds the missing items. **Scope:** only Custom price adapters actually used by the **ETH Alpha Fund** or the **USD Alpha Fund** deploy scripts in `karpatkey-tokenized-fund` — stale or Chainlink-only entries are skipped.

**Source of truth for which oracles are needed per chain:**
- `karpatkey-tokenized-fund/contracts/script/deploy/EthAlphaFund/{Chain}.s.sol` — `_setupPriceOracles()` calls like `wstethToUsdCustom()`, `ezethToUsdCustom()`, etc.
- `karpatkey-tokenized-fund/contracts/script/deploy/UsdAlphaFund/{Chain}.s.sol` — same pattern

#### 1.7.a — `_deployMainnetPriceAdapters()` — add ezETH

Both funds' Mainnet price-oracle setup in v1 uses `ezethToUsdCustom` (ETH Alpha) — v2 implementation exists (`ezETH_Price.sol`) but has no deploy function.

- [ ] Add `import {ezETH_PriceOracle} from "../../src/prices/protocols/ezETH_Price.sol";`
- [ ] Add `if (ConfigReader.isAdapterEnabled(..., "ezETH")) _deployEzEth();` call inside `_deployMainnetPriceAdapters()`
- [ ] Implement `_deployEzEth()` reading `restakeManager`, `ezEth`, `ethToUsdChainlinkOracle`, `ethToUsdChainlinkHeartbeat` (and whatever else the constructor needs) via `ConfigReader.readPriceFeedParam`
- [ ] **`ETHPlus_Price.sol` is NOT wired** — ETH Alpha uses `ethPlusToUsdChainlink()` (Chainlink, not Custom). Document this decision in a comment next to the unused import or omit the import entirely.

#### 1.7.b — `_deployArbitrumPriceAdapters()` — wire L2 variants

Derived from Alpha fund Arbitrum scripts:
- ETH Alpha Arbitrum uses: `wstethToUsdCustom`, `weethToUsdCustom`, `ezethToUsdCustom`, `rsethToUsdCustom`
- USD Alpha Arbitrum uses: `syrupusdcToUsdCustom`

- [ ] Replace empty stub with real implementation (follow the Mainnet pattern used by groups 1a/1b — `_readAdapterDeployed` idempotency check → read constructor args → `new Contract(...)` → `writeAdapterAddress`)
- [ ] Wire `wstETH_L2` — import `wstETH_L2_PriceOracle`, add `_deployIfEnabled`-style gate reading from `assets.json.priceFeeds.wstETH_L2.42161`
- [ ] Wire `weETH_L2`
- [ ] Wire `ezETH_L2` (uses `IxRenzoDeposit.getRate()`, different from Mainnet ezETH)
- [ ] Wire `rsETH_L2`
- [ ] Wire `syrupUSDC_L2`

#### 1.7.c — `_deployBasePriceAdapters()` — wire L2 variants

Derived from Alpha fund Base scripts:
- ETH Alpha Base uses: `wstethToUsdCustom`, `weethToUsdCustom`, `cbethToUsdCustom`
- USD Alpha Base uses: no Custom adapters (just Chainlink USDC + GHO)

- [ ] Replace empty stub with real implementation
- [ ] Wire `wstETH_L2`
- [ ] Wire `weETH_L2`
- [ ] Wire `cbETH_L2`

#### 1.7.d — `_deployOptimismPriceAdapters()` — (no work needed)

Alpha funds on Optimism use only Chainlink feeds (`wstethToUsdChainlink`, `usdcToUsdChainlink`, `usdtToUsdChainlink`). No Custom price adapters need to be deployed.

- [ ] Leave the function as a documented no-op (comment explaining that Alpha funds on OP use Chainlink exclusively)

#### 1.7.e — `_deployGnosisPriceAdapters()` — wire L2 wstETH

- ETH Alpha Gnosis uses `wstethToUsdCustom` (which at v1 maps to the L2 variant) + `wethToUsdChainlink`
- USD Alpha Gnosis uses `savingsXdaiToUsdCustom` — already wired in Phase 3 (`_deploySxdai`).

- [ ] Add wiring for `wstETH_L2` (Gnosis uses Aave ratio provider instead of Chainlink — same interface, different constructor address — see the `wstETH_L2_Price.sol` NatSpec)

#### 1.7.f — `assets.json` — add `priceFeeds` section

`ConfigReader.readPriceFeedParam()` reads constructor args from `script/config/assets.json` at path `.priceFeeds.{adapter}.{chainId}.constructor.{param}`. That section does not exist yet.

- [ ] Add top-level `priceFeeds` object with entries for every adapter above, per chain. Shape:
  ```json
  "priceFeeds": {
    "sDAI": {
      "1": { "enabled": true, "constructor": { "sDai": "0x...", "dsrManager": "0x...", "daiToUsdChainlinkOracle": "0x...", "daiToUsdChainlinkHeartbeat": "3600" } }
    },
    "wstETH_L2": {
      "42161": { "enabled": true, "constructor": { ... } },
      "8453":  { "enabled": true, "constructor": { ... } },
      "100":   { "enabled": true, "constructor": { ... } }
    }
  }
  ```
- [ ] Per-chain content (Custom adapters used by Alpha funds):
  - Mainnet (1): `sDAI`, `LDO`, `sUSDS`, `sUSDe`, `syrupUSDC`, `wstETH`, `rETH`, `cbETH`, `weETH`, `rsETH`, `eETH`, `ezETH`
  - Arbitrum (42161): `wstETH_L2`, `weETH_L2`, `rsETH_L2`, `ezETH_L2`, `syrupUSDC_L2`
  - Base (8453): `wstETH_L2`, `weETH_L2`, `cbETH_L2`
  - Optimism (10): (none — Chainlink-only)
  - Gnosis (100): `sXDAI`, `wstETH_L2`
- [ ] Do **not** populate `ETHPlus` entry — not used by Alpha funds.

#### 1.7.g — Chain configs — pre-seed `priceFeeds` key (if required)

`ConfigReader.writeAdapterAddress(...)` writes deployed price-feed addresses to `script/config/chains/{chainId}.json` at `.priceFeeds.{adapter}.deployed`. A stale comment in `ConfigReader.readAdapterParam` claims priceFeeds has been removed from chain config schema; the script still writes there, and `vm.writeJson` may refuse to create a missing parent object.

- [ ] Verify whether `vm.writeJson` creates `.priceFeeds.{adapter}.deployed` when `.priceFeeds` is absent; if not, pre-seed `"priceFeeds": {}` (or per-adapter sub-objects) in each chain config
- [ ] Remove the stale comment in `ConfigReader.readAdapterParam`

#### 1.7.h — Verify before PR 2 merge

- [ ] `forge build` clean
- [ ] `forge script script/deploy/03_DeployPriceFeeds.s.sol --chain-id 1` dry run (no broadcast) succeeds
- [ ] Same dry run for chain-id 42161, 8453, 10, 100
- [ ] Update the PR 2 description on GitHub to list the scope addition (deploy-script wiring, `assets.json.priceFeeds` population, any chain-config pre-seed)

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
- [x] `test_constructor_invalidArgs` — reverts on zero addresses
- [x] `test_supportsInterface` — ERC165 returns true for `IBalanceOracleAdapter` and `IERC165`
- [x] `test_underlyingAssetsSupported` — returns the expected asset array
- [x] `test_getOracleBalances_unknownAccount` — returns zero balances for an account with no positions
- [x] `test_getOracleBalanceForAsset_unsupportedAsset` — returns (0, false) for an asset this oracle doesn't handle

**Fork test** (`OracleName.fork.t.sol`) — extend `BalanceAdapterTestBase.fork`:
- [x] `test_getOraclePositions` — uses a real account with known positions at the pinned block; verifies non-zero amounts and correct `isDebt` flags
- [x] `test_getOracleBalances` — parallel arrays match `getOraclePositions` results
- [x] `test_getOracleBalanceForAsset` — single-asset result matches the corresponding entry from `getOraclePositions`
- [x] `test_underlyingAssetsSupported` — returns correct on-chain addresses
- [x] (where applicable) `test_debtPosition` — borrowed positions have `isDebt = true`
- [x] (where applicable) `test_rewardPosition` — reward token positions are present and non-zero

### 2a — ERC4626 vaults (simplest)

Single asset, `convertToAssets(shares)` → one `PositionBalance` per supported asset.

- [x] **`MorphoVault.sol`** — Morpho ERC4626 vault shares → underlying
  - Source: `src/balances/protocols/MorphoVault.sol`
  - Supported assets: the vault's `asset()` (loan token)
  - Constructor: `(morphoVault, protocol, navCalculator)`
  - Note: Source tests both v1 and v2 vaults — fork test must cover both
  - [x] Implementation
  - [x] Unit test: `test/balances/protocols/MorphoVault.t.sol`
  - [x] Fork test: `test/balances/protocols/fork/MorphoVault.fork.t.sol`
  - [x] `forge test --match-path "test/balances/protocols/MorphoVault*"` passes ✓
  - [x] Deploy script: `_deployMorphoVault()` + `MorphoVault_` branch added to `04_DeployBalanceAdapters.s.sol`

- [x] **`GearboxMarket.sol`** — Gearbox farming pool (ERC4626) → underlying
  - Source: `src/balances/protocols/GearboxMarket.sol`
  - Constructor: `(farmingPool, protocol, navCalculator)`
  - Note: Source tests autocompounding tolerance — document tolerance with a comment in the fork test
  - [x] Verify Gearbox interfaces exist in lib/ or add minimal `IFarmingPool`
  - [x] Implementation
  - [x] Unit test: `test/balances/protocols/GearboxMarket.t.sol`
  - [x] Fork test: `test/balances/protocols/fork/GearboxMarket.fork.t.sol`
  - [x] `forge test --match-path "test/balances/protocols/GearboxMarket*"` passes ✓
  - [x] Deploy script: `_deployGearboxMarket()` + `Gearbox_` branch added to `04_DeployBalanceAdapters.s.sol`

### 2b — Protocol-specific moderate

- [x] **`Cap.sol`** — Cap Finance cUSD + stcUSD positions → USDC equivalent
  - Source: `src/balances/protocols/Cap.sol`
  - Logic: `cUSD.balanceOf(account)` + `stcUSD.getBurnAmount(stcUSD.balanceOf(account))`
  - Supported assets: USDC (both positions denominated in USDC)
  - Constructor: `(cUSD, stcUSD, protocol, navCalculator)`
  - Note: Two positions per account (cUSD balance + staked cUSD converted to USDC)
  - [x] Verify Cap interfaces exist in lib/ or add minimal `IStakedCap`
  - [x] Implementation
  - [x] Unit test: `test/balances/protocols/Cap.t.sol`
  - [x] Fork test: `test/balances/protocols/fork/Cap.fork.t.sol`
  - [x] `forge test --match-path "test/balances/protocols/Cap*"` passes ✓
  - [x] Deploy script: `_deployCap()` + `Cap_` branch added to `04_DeployBalanceAdapters.s.sol`

### 2c — Complex LP + rewards (hardest)

These have multi-asset positions, reward accrual, and bounded loops. Port last — use the existing `BalancerV3.sol` and `Aura.sol` in this repo as structural reference since they were already upgraded.

- [x] **`Curve.sol`** — Curve LP positions (unstaked + gauge-staked) + CRV rewards
  - Source: `src/balances/protocols/Curve.sol`
  - Supported assets: all pool tokens (`coins[0..N]`) + CRV + extra reward tokens
  - Constructor: `(gauge, protocol, navCalculator)` — pool derived from `gauge.lp_token()`
  - Key complexity:
    - Unstaked LP: `pool.calc_withdraw_one_coin()` or proportional split
    - Staked LP: `gauge.balanceOf(account)` → same math as unstaked
    - CRV rewards: `integrate_fraction` is **checkpoint-based lower bound** — document clearly in NatSpec and test comments
    - Extra rewards: `gauge.claimable_reward(account, token)` per reward token
    - Bounded loop: `_MAX_ITERATIONS = 8` for pool coins
  - [x] Verify Curve interfaces exist in lib/ (`ICurveGauge`, `ICurvePool`, `ICurveMinter`)
  - [x] Implementation
  - [x] Unit test: `test/balances/protocols/Curve.t.sol`
  - [x] Fork test: `test/balances/protocols/fork/Curve.fork.t.sol`
    - Must test: unstaked LP position, staked LP position, CRV lower-bound, at least one extra reward token
    - Must use a real account known to hold gauge-staked LP at the pinned block
  - [x] `forge test --match-path "test/balances/protocols/Curve*"` passes ✓
  - [x] Deploy script: `_deployCurve()` + `Curve_` branch added to `04_DeployBalanceAdapters.s.sol`

- [x] **`Convex.sol`** — Convex-staked Curve LP + CRV + CVX rewards
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
  - [x] Verify Convex interfaces exist in lib/ (`IConvexRewards`, `IConvexBooster`)
  - [x] Implementation
  - [x] Unit test: `test/balances/protocols/Convex.t.sol`
  - [x] Fork test: `test/balances/protocols/fork/Convex.fork.t.sol`
    - Must test: LP pool token positions, CRV rewards, CVX derived amount, at least one extra reward
  - [x] `forge test --match-path "test/balances/protocols/Convex*"` passes ✓
  - [x] Deploy script: `_deployConvex()` + `Convex_` branch added to `04_DeployBalanceAdapters.s.sol`

---

### Phase 2 addendum — per-instance deploy list + `06_Configure.s.sol` (tracked in **PR 3**, added 2026-04-16)

The per-oracle checklists above each have a `Deploy script: _deployXxx()` line that is [x] — meaning the adapter **type** has a handler. What was never tracked: the full **per-instance** list of `_deployIfEnabled("Prefix_Instance")` calls in `run()` of `04_DeployBalanceAdapters.s.sol`, and the corresponding names in `06_Configure.s.sol`'s hardcoded arrays.

**Scope:** mirror the set of balance oracles the **ETH Alpha Fund** and **USD Alpha Fund** register on their NAV in v1 — nothing more. Stale v1 entries (expired PT markets, `StakeWise` vaults not used by either fund, Morpho markets not used by either fund, `CompoundV3_USDC/WETH` (no Alpha-fund usage), `DaiDsr`, `SkySavingsUsds`) are intentionally excluded.

**Naming fix:** the current `AaveV3_USDC` / `AaveV3_WETH` entries in `04` and `06` are misleading — Aave V3 has no per-token markets, these names are meaningless. They will be renamed to `AaveV3_Core` / `AaveV3_Prime` on Mainnet (matching v1's `aaveV3CoreInstanceBalanceOracle` / `aaveV3PrimeInstanceBalanceOracle`). Similar rename: `SparkLend_USDC` → `SparkLend` (single instance per chain).

**Source of truth per chain:** `karpatkey-tokenized-fund/contracts/script/deploy/{EthAlphaFund,UsdAlphaFund}/{Chain}.s.sol` — every `addBalances(nav, ...BalanceOracle(...))` call is one instance that v2 must be able to deploy and register.

#### 2.9.a — Mainnet per-instance list (union ETH + USD Alpha)

Replace the current 8-entry list with the full set:

| Adapter name (v2) | v1 source function | Used by |
|---|---|---|
| `AaveV3_Core` | `aaveV3CoreInstanceBalanceOracle` | ETH, USD |
| `AaveV3_Prime` | `aaveV3PrimeInstanceBalanceOracle` | ETH, USD |
| `SparkLend` (rename) | `spark_BalanceOracle` | USD |
| `AaveV3SafetyModule_stkGHO` | `aaveV3GhoStakingBalanceOracleWithoutAaveRewards` | USD |
| `Cap` | `capMoney_cUSD_BalanceOracle` | USD |
| `MorphoVault_kpkETHPrime_V1` | `morphoVault_kpk_ETH_Prime_V1_BalanceOracle` | ETH |
| `MorphoVault_kpkETHPrime_V2` | `morphoVault_kpk_ETH_Prime_V2_BalanceOracle` | ETH |
| `MorphoVault_kpkUSDCPrime_V1` | `morphoVault_kpk_USDC_Prime_V1_BalanceOracle` | USD |
| `MorphoVault_kpkUSDCPrime_V2` | `morphoVault_kpk_USDC_Prime_V2_BalanceOracle` | USD |
| `GearboxMarket_kpkWETH` | `gearboxMarket_kpk_ETH_Market_BalanceOracle` | ETH |
| `GearboxMarket_kpkwstETH` | `gearboxMarket_kpk_wstETH_Market_BalanceOracle` | ETH |
| `BalancerV3_rETH_WETH` *(rename from `weETH_WETH`)* | `balancerV3_Boosted_rETH_WETH_BalanceOracle` | ETH |
| `BalancerV3_GHO_USDT_USDC` *(new)* | `balancer_Boosted_GHO_USDT_USDC_BalanceOracle` | USD |
| `Aura_rETH_WETH` *(rename from `weETH_WETH`)* | `aura_Boosted_rETH_WETH_BalanceOracle` | ETH |
| `Aura_GHO_USDT_USDC` *(new)* | `aura_Boosted_GHO_USDT_USDC_BalanceOracle` | USD |
| `Curve_weETH_WETH` | `Curve_weETH_WETH_BalanceOracle` | ETH |
| `Curve_crvUSD_USDC` *(new)* | v1 `Curve_crvUSD_USDC_BalanceOracle` → used indirectly via Convex | USD (implicit) |
| `Curve_crvUSD_USDT` *(new)* | v1 `Curve_crvUSD_USDT_BalanceOracle` | USD (implicit) |
| `Curve_RLUSD_USDC` *(new)* | v1 `Curve_RLUSD_USDC_BalanceOracle` | USD (implicit) |
| `Convex_weETH_WETH` *(rename from `crvUSD_USDT`)* | `Convex_weETH_WETH_BalanceOracle` | ETH |
| `Convex_crvUSD_USDC` *(new)* | `Convex_USDC_crvUSD_BalanceOracle` | USD |
| `Convex_crvUSD_USDT` *(keep)* | `Convex_USDT_crvUSD_BalanceOracle` | USD |
| `Convex_RLUSD_USDC` *(new)* | `Convex_RLUSD_USDC_BalanceOracle` | USD |

**Drop from the current list:**
- `AaveV3_USDC`, `AaveV3_WETH` (rename to Core/Prime as above — these names are bogus)
- `CompoundV3_USDC`, `CompoundV3_WETH` (not used by either Alpha fund)
- `SparkLend_USDC` (rename to `SparkLend`)
- `DaiDsr`, `SkySavingsUsds` (not used by either Alpha fund)
- `AaveV3SafetyModule_stkAAVE` (not used by either fund — only `stkGHO` is)
- `MorphoVault_kpkUSDC_V1`, `MorphoVault_kpkUSDC_V2` (rename to `MorphoVault_kpkUSDCPrime_V1/V2` for clarity; add the missing `kpkETHPrime_V1/V2` pair)
- `BalancerV3_weETH_WETH`, `Aura_weETH_WETH` (wrong pool — rename to `rETH_WETH` and add `GHO_USDT_USDC`)
- `StakeWiseV3Vault_WETH`, `StakeWiseV3OsToken_WETH` (Alpha funds do not use StakeWise on Mainnet; Gnosis-only deployments dropped too since neither Alpha fund uses them)

**Tasks:**
- [ ] Update imports, `run()` `_deployIfEnabled` calls, and handler branches in `04_DeployBalanceAdapters.s.sol`
- [ ] Add chain config entries with all constructor params per instance (cross-reference v1 `BalanceOracles.sol` + v1 `*_Lib.sol` for the addresses)
- [ ] Mirror the adapter-name list in `06_Configure.s.sol._countDeployedBalanceAdapters()` and `_addBalanceOracleTransactions()`, growing `new string[](N)` to the actual size
- [ ] Drop the stale `MorphoBlue_USDC` entry from `06_Configure.s.sol` (not deployed by `04`)

#### 2.9.b — Arbitrum per-instance list

| Adapter name (v2) | v1 source | Used by |
|---|---|---|
| `AaveV3_Arbitrum` | `aaveV3Oracle` | ETH, USD |
| `MorphoMarket_sUSDS_USDC` | `morphoMarket_sUSDS_USDC_BalanceOracle` | USD |
| `MorphoMarket_syrupUSDC_USDC` | `morphoMarket_syrupUSDC_USDC_BalanceOracle` | USD |
| `MorphoVault_kpkUSDCYieldV1` | `morphoVault_kpk_USDC_Prime_BalanceOracle` | USD |
| `BalancerV3_GHO_USDC_USDT` | `balancer_Boosted_GHO_USDC_USDT_BalanceOracle` | USD (implicit via Aura gauge) |
| `Aura_GHO_USDC_USDT` | `aura_Boosted_GHO_USDC_USDT_BalanceOracle` | USD |

- [ ] Add imports + `_deployIfEnabled` calls + chain config entries
- [ ] Add matching names to `06_Configure.s.sol` chain-42161 behaviour (note: `06_Configure` is currently chain-agnostic — will need per-chain gating or expanded array)

#### 2.9.c — Base per-instance list

| Adapter name (v2) | v1 source | Used by |
|---|---|---|
| `AaveV3_Base` | `aaveV3Oracle` | ETH, USD |
| `MorphoMarket_wstETH_WETH` | `morphoMarket_wstETH_WETH_BalanceOracle` | ETH |
| `MorphoMarket_weETH_WETH` | `morphoMarket_weETH_WETH_BalanceOracle` | ETH |
| `MorphoMarket_cbETH_USDC` | `morphoMarket_cbETH_USDC_BalanceOracle` | USD |
| `MorphoMarket_cbBTC_USDC` | `morphoMarket_cbBTC_USDC_BalanceOracle` | USD |
| `BalancerV3_GHO_USDC` | `balancer_Boosted_GHO_USDC_BalanceOracle` | USD (implicit) |
| `Aura_GHO_USDC` | `aura_Boosted_GHO_USDC_BalanceOracle` | USD |

- [ ] Add imports + `_deployIfEnabled` calls + chain config entries, same `06_Configure` treatment

#### 2.9.d — Optimism per-instance list

| Adapter name (v2) | v1 source | Used by |
|---|---|---|
| `AaveV3_Optimism` | `aaveV3Oracle` | ETH, USD |

- [ ] Add `_deployIfEnabled("AaveV3_Optimism")` + chain config entry

#### 2.9.e — Gnosis per-instance list

| Adapter name (v2) | v1 source | Used by |
|---|---|---|
| `AaveV3_Gnosis` | `aaveV3Oracle` | ETH, USD |
| `Native` *(see below)* | `nativeBalanceOracle` | USD |

- Gnosis `USD Alpha` uses `nativeBalanceOracle()` for native xDAI. v2 doesn't have a dedicated "Native" balance adapter — `ERC20Default` on Gnosis with the xDAI ERC-7528 sentinel should cover this, but confirm.
- [ ] Add `AaveV3_Gnosis` deploy + config
- [ ] Confirm native xDAI coverage via `ERC20Default`; if not, add a new Native adapter (or extend `ERC20Default`)
- [ ] **Do not** wire StakeWise vaults — neither Alpha fund uses them on Gnosis

#### 2.9.f — Naming cleanup pass (Mainnet + all chains)

- [ ] Rename current `AaveV3_USDC` / `AaveV3_WETH` → `AaveV3_Core` / `AaveV3_Prime` in `04` + `06` + chain config + any existing test fixtures
- [ ] Rename `SparkLend_USDC` → `SparkLend` (handler already works for any dataProvider)
- [ ] Rename current `MorphoVault_kpkUSDC_V1/V2` → `MorphoVault_kpkUSDCPrime_V1/V2`

#### 2.9.g — Verify before PR 3 merge

- [ ] `forge build` clean; `forge test` (non-fork) still 716+ pass
- [ ] Dry run per chain: `forge script script/deploy/04_DeployBalanceAdapters.s.sol --chain-id {id}` produces one "Deployed at: …" log line per adapter in the list above
- [ ] Dry run per chain: `forge script script/deploy/06_Configure.s.sol --chain-id 1` produces a Safe TX file with one `addBalanceOracle` per deployed adapter (count matches 2.9.a)
- [ ] Update the PR 3 description on GitHub to list the scope addition (misleading-name renames, full per-instance deploy list, `06_Configure.s.sol` rewrite)

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
  - [x] `ConfigReaderTest.t.sol`: `test_ReadComplexAdapterParams` replaced with `test_ReadMissingAdapterParamsReturnsEmpty` — tautological `>= 0` assertion replaced with real `assertEq(length, 0)` checks

- [x] **AaveV3SafetyModule** — diff vs source; staking rewards are the core purpose — do **not** remove them
  - Diff: naming conventions only (SCREAMING_SNAKE_CASE), v1→v2 interface. Logic identical.
  - [x] `forge test --match-path "test/balances/protocols/AaveV3SafetyModule*"` passes ✓ (6 unit + 11 fork)
  - [x] Deploy script: `_deployAaveV3SafetyModule()` + `AaveV3SafetyModule_` branch added to `04_DeployBalanceAdapters.s.sol`

- [x] **SparkLend** — rewards removed (same approach as AaveV3Instance)
  - Source diff done: v1 is a thin wrapper, no logic differences beyond constructor passthrough.
  - Spark's on-chain RewardsController exists but the wstETH/stETH campaign ended Oct 2024. No active campaigns to test against; rewards removed for now, can be re-added if a specific campaign is active.
  - Removed `test_getOracleBalanceForAsset_reward_steth` (user had zero supply/debt at fork block — rewards-only position no longer tracked).
  - [x] Unit tests pass (4/4)
  - [x] Fork tests pass (7/7 after removing rewards test)
  - [x] Deploy script (`04_DeployBalanceAdapters.s.sol`): `rewardsDistributor` param removed from `_deploySparkLend()`
  - [x] Verify script (`VerifyEtherscan.s.sol`): `rewardsDistributor` removed from SparkLend constructor arg encoding

- [x] **MorphoMarket** — diff vs source; check collateral + loan token dual-asset handling and rounding
  - Diff: v2 is a logic improvement over v1. v1 short-circuits with `return 0` if `totalBorrowShares == 0 || totalSupplyShares == 0`, which would miss supply positions in markets with no borrows. v2 handles supply and borrow independently. Keep v2.
  - [x] `forge test --match-path "test/balances/protocols/MorphoMarket*"` passes ✓ (7 unit + 9 fork)
  - [x] Deploy script: `_deployMorphoBlue()` constructor params match current MorphoMarket constructor — no changes needed

- [x] **BalancerV3** — **known to have diverged significantly** — thorough diff required
  - Key differences vs source:
    1. ERC4626 path: reverted `previewRedeem(shares - 1) - 1` — v2 now uses `previewRedeem(shares)` matching v1. Added missing `else` branch for non-ERC4626 tokens (was returning raw scaled-18 values, incorrect).
    2. `gaugeRewards`: added try/catch on `claimable_reward` — matches v1 behavior.
    3. `claimableTokens`: added L2 fallback (`calculateIntegrateFractionL2` with `inflation_rate(weekNumber)` mapping) — matches v1.
    4. `positionDetail`: v2 uses `underlyingAsset.symbol` per asset (improvement over v1 fixed string).
    5. Constructor: v2 takes `protocol_` instead of `positionMetadata_`. No `positionDetail_` param.
    6. `calculateIntegrateFraction`: v2 uses SafeCast (`.toUint256()`, `.toUint128()`) instead of `uint256(uint128(period))`.
  - [x] `forge test --match-path "test/balances/protocols/BalancerV3*"` passes ✓ (7 unit + 7 fork)
  - [x] Deploy script: `_deployBalancerV3()` + `BalancerV3_` branch added to `04_DeployBalanceAdapters.s.sol`

- [x] **Aura** — **known to have diverged significantly** — thorough diff required
  - Key differences vs source:
    1. ~~No L2 support: v1 had `IS_MAINNET`/`_L2_COORDINATOR`/`calculateL2AuraMint`. v2 is mainnet-only — intentional.~~ **RESCINDED 2026-04-16** — this was wrongly flagged as intentional. L2 support was restored in commit `62fcdee` on `feat/pr3-balance-oracles`: constructor dropped `auraToken_`, AURA token is derived dynamically via `Booster.minter()` + `IL2Coordinator.auraOFT()` staticcall, `calculateL2AuraMint` added, `rewards()` branches on new `IS_MAINNET` flag. New fork test file `test/balances/protocols/fork/Aura.L2.fork.t.sol` ports v1's `test_arbitrum_l2_aura_rewards` and adds 4 more L2-specific assertions.
    2. ERC4626 path: reverted `previewRedeem(shares - 1) - 1` — v2 now uses `previewRedeem(shares)` matching v1. Added missing `else` branch for non-ERC4626 tokens (same fix as BalancerV3).
    3. `previewEarned()`: v2 more sophisticated (factors in `rewardRate` × elapsed time). v1 used `earned()` directly. Kept v2 (functionally equivalent at same block, time delta = 0).
    4. `rewardClaimed` signature: v2 takes `(address token, amount)` vs v1 `(amount)`.
    5. Extra rewards: added try/catch around `IStashToken(pool.rewardToken()).baseToken()` — matches v1 behavior for pools that don't use stash wrappers.
    6. Constructor: v2 takes explicit `(pool_, gauge_, booster_, pid_, auraToken_, ...)` vs v1 `(booster_, baseRewardPool_, ...)`. More defensive validation.
    7. `getMinterMinted`: same assembly storage slot approach. v2 also adds `minterMinted()` to IAuraToken interface (unused in current code).
  - [x] `forge test --match-path "test/balances/protocols/Aura*"` passes ✓ (2 unit + 4 fork)
  - [x] Deploy script: `_deployAura()` + `Aura_` branch added to `04_DeployBalanceAdapters.s.sol`

- [x] **DaiDsr** — diff vs source; verify chi accumulation (RAY-precision mulDiv) and drip emulation
  - Diff: naming conventions only (SCREAMING_SNAKE_CASE), v1→v2 interface. Chi/rmul/rpow math identical.
  - [x] `forge test --match-path "test/balances/protocols/DaiDsr*"` passes ✓ (4 unit + 4 fork)
  - [x] Deploy script: `_deployDaiDsr()` constructor params match — no changes needed

- [x] **StakeWiseV3Vault** — diff vs source; verify net position (vault assets − osToken debt)
  - Diff: naming conventions, v1→v2 interface. v1 returns `vaultAssets.toInt256() - mintedOs.toInt256()`; v2 splits to `(amount, isDebt)`. Logically equivalent.
  - [x] `forge test --match-path "test/balances/protocols/StakeWiseV3Vault*"` passes ✓ (6 unit + 7 fork)
  - [x] Deploy script: `_deployStakeWiseV3Vault()` + `StakeWiseV3Vault_` branch added to `04_DeployBalanceAdapters.s.sol`

- [x] **StakeWiseV3OsToken** — diff vs source; verify `convertToAssets` path
  - Diff: naming conventions, v1→v2 interface. `IERC20(OS_TOKEN).balanceOf(account)` + `convertToAssets` path identical.
  - [x] `forge test --match-path "test/balances/protocols/StakeWiseV3OsToken*"` passes ✓ (5 unit + 3 fork)
  - [x] Deploy script: `_deployStakeWiseV3OsToken()` + `StakeWiseV3OsToken_` branch added to `04_DeployBalanceAdapters.s.sol`

- [x] **SkySavingsUsds** — diff vs source; verify ERC4626 `convertToAssets`
  - Diff: naming conventions, v1→v2 interface. `convertToAssets(balanceOf(account))` path identical. Bug fix: `_buildPositions` was hardcoding `positionDetail: "Savings USDS"` — corrected to use `_positionDetail`.
  - [x] `forge test --match-path "test/balances/protocols/SkySavingsUSDS*"` passes ✓ (1 unit + 8 fork)
  - [x] Deploy script: `_deploySkySavingsUsds()` constructor params match — no changes needed

### Price oracles to reconcile

- [x] **sDAI_Price** — diff vs source; verify DSR chi math (RAY-precision mulDiv) and staleness logic
  - Diff: naming conventions only (SCREAMING_SNAKE_CASE vs camelCase for constants/immutables). Logic identical.
  - [x] `forge test --match-path "test/prices/protocols/sDAI*"` passes ✓ (1 unit + 4 fork)
  - [x] Deploy script: `_deploySdai()` constructor params match source — no changes needed

- [x] **sUSDS_Price** — diff vs source; verify ERC4626 exchange rate path and staleness logic
  - Diff: naming conventions only. Logic identical.
  - [x] `forge test --match-path "test/prices/protocols/sUSDS*"` passes ✓ (1 unit + 4 fork)
  - [x] Deploy script: `_deploySusds()` constructor params match source — no changes needed

- [x] **sXDAI_Price** — diff vs source; verify Gnosis chain-specific path and staleness logic
  - Diff: naming conventions only + typo fix (`chainlinkHertbeat` → `CHAINLINK_HEARTBEAT`). Logic identical.
  - [x] `forge test --match-path "test/prices/protocols/sXDAI*"` passes ✓ (1 unit + 4 fork)
  - [x] Deploy script: `_deploySxdai()` added to `_deployGnosisPriceAdapters()` in `03_DeployPriceFeeds.s.sol`; reads `sXdai`, `xDaiToUsdChainlinkOracle`, `xDaiToUsdChainlinkHeartbeat` from config

- [x] **LDO_Price** — diff vs source; verify two-feed cross-rate (LDO/ETH × ETH/USD) and both heartbeats
  - Diff: naming conventions only. Logic identical.
  - [x] `forge test --match-path "test/prices/protocols/LDO*"` passes ✓ (1 unit + 4 fork)
  - [x] Deploy script: `_deployLdo()` constructor params match source — no changes needed

---

## Phase 4 — Integration & cleanup

This is the final gate. **All tests must be green before opening the PR.**

### Full test run
- [x] `forge build` — "No files changed, compilation skipped" — zero errors (lint warnings are pre-existing and suppressed with `forge-lint: disable-next-line`) — 2026-04-15
- [x] `forge test` — **716 passed, 0 failed** (non-fork unit tests) — 2026-04-17 (re-confirmed on `main` post-merge)
- [x] `FOUNDRY_PROFILE=slow forge test --match-path "test/**/fork/*.sol"` — **271 passed, 0 failed** — 2026-04-17 (post-merge; +7 vs 2026-04-15 baseline from Aura L2 + BalancerV3 L2 additions)
- [x] Compare final pass count vs Phase 0 baseline — delta matches new test files added

### Specific oracle test checklist (final confirmation)
Run each group and confirm green:
- [x] `forge test --no-match-path "test/**/fork/*.sol"` — **716 passed, 0 failed** — 2026-04-17
- [x] `forge test --match-path "test/**/fork/*.sol"` (slow profile) — **271 passed, 0 failed** — 2026-04-17

### Code quality
- [x] `forge fmt --check` — exits 0, no diff — 2026-04-15
- [x] All new oracle files have: correct SPDX header, pragma matching the current codebase (`pragma solidity ^0.8;` for oracle contracts, `^0.8.28` for deploy scripts), NatSpec on constructor params
- [x] CRV lower-bound caveat is documented in `Curve.sol` NatSpec (it was in v1 — must carry over)

### PRs
- [x] All 3 PRs merged to `main` in `onchain-accounting` (#10 `f97f264`, #11 `369efd0`, #12 `f32d560` — all on 2026-04-17)
- [x] Each PR description references this plan document and lists the oracles it covers

---

## Phase 5 — Final parity check (2026-04-15)

Comprehensive file-by-file comparison of every oracle and its tests against the KTF source.
Performed after Phase 3 reconciliation (commit `15543ef`) + Round 4 Copilot fixes (commit `dc02d3a`).

Legend: ✅ Parity confirmed | ⚠️ Intentional divergence (documented) | ❌ Bug / regression

### Price oracles — src parity

| Oracle | Src parity | Notes |
|--------|-----------|-------|
| `sUSDe_Price.sol` | ✅ | Identical logic |
| `syrupUSDC_Price.sol` | ✅ | Identical logic |
| `wstETH_Price.sol` | ✅ | Identical logic |
| `rETH_Price.sol` | ✅ | Identical logic |
| `cbETH_Price.sol` | ⚠️ | OA uses `<= 0` (vs KTF `< 0`) — intentional improvement: zero price treated as stale |
| `eETH_Price.sol` | ✅ | Identical logic |
| `weETH_Price.sol` | ✅ | Identical logic |
| `rsETH_Price.sol` | ⚠️ | Same `<= 0` improvement as cbETH |
| `ezETH_Price.sol` | ⚠️ | Same `<= 0` improvement; OA also adds `try/catch` on `calculateTVLs` — intentional |
| `wstETH_L2_Price.sol` | ✅ | Identical logic |
| `cbETH_L2_Price.sol` | ✅ | Identical logic |
| `weETH_L2_Price.sol` | ✅ | Identical logic |
| `rsETH_L2_Price.sol` | ✅ | Identical logic |
| `ezETH_L2_Price.sol` | ⚠️ | Same `<= 0` improvement as cbETH |
| `syrupUSDC_L2_Price.sol` | ✅ | Identical logic |
| `ETHPlus_Price.sol` | ✅ | Identical logic |
| `sDAI_Price.sol` | ✅ | Naming conventions only (reconciled Phase 3) |
| `sUSDS_Price.sol` | ✅ | Naming conventions only (reconciled Phase 3) |
| `sXDAI_Price.sol` | ✅ | Naming conventions + typo fix (reconciled Phase 3) |
| `LDO_Price.sol` | ✅ | Naming conventions only (reconciled Phase 3) |
| `CrossRate_Price.sol` | — | New in OA — no KTF counterpart |

### Price oracle tests — parity

| Test file | Unit | Fork | Notes |
|-----------|------|------|-------|
| `sUSDe_Price.t.sol` | ✅ | ✅ | |
| `syrupUSDC_Price.t.sol` | ✅ | ✅ | |
| `wstETH_Price.t.sol` | ✅ | ✅ | |
| `rETH_Price.t.sol` | ✅ | ✅ | |
| `cbETH_Price.t.sol` | ✅ | ✅ | |
| `eETH_Price.t.sol` | ✅ | ✅ | |
| `weETH_Price.t.sol` | ✅ | ✅ | |
| `rsETH_Price.t.sol` | ✅ | ✅ | |
| `ezETH_Price.t.sol` | ✅ | ✅ | |
| `wstETH_L2_Price.t.sol` | ✅ | ✅ | |
| `cbETH_L2_Price.t.sol` | ✅ | ✅ | |
| `weETH_L2_Price.t.sol` | ✅ | ✅ | |
| `rsETH_L2_Price.t.sol` | ✅ | ✅ | |
| `ezETH_L2_Price.t.sol` | ✅ | ✅ | |
| `syrupUSDC_L2_Price.t.sol` | ✅ | ✅ | |
| `ETHPlus_Price.t.sol` | ✅ | ✅ | |
| `sDAI_Price.t.sol` | ✅ | ✅ | |
| `sUSDS_Price.t.sol` | ✅ | ✅ | |
| `sXDAI_Price.t.sol` | ✅ | ✅ | |
| `LDO_Price.t.sol` | ✅ | ✅ | |
| `CrossRate_Price.t.sol` | ✅ | ✅ | New in OA |

### Balance oracles — src parity

| Oracle | Src parity | Notes |
|--------|-----------|-------|
| `AaveV3Instance.sol` | ⚠️ | Stable debt omitted (Aave v3 deprecated); rewards removed (inactive); collateral labels added — all intentional (reconciled Phase 3) |
| `AaveV3SafetyModule.sol` | ✅ | Naming conventions only (reconciled Phase 3) |
| `SparkLend.sol` | ⚠️ | Rewards removed (no active campaigns Oct 2024+) — intentional (reconciled Phase 3) |
| `MorphoMarket.sol` | ⚠️ | OA handles supply/borrow independently — improvement over KTF short-circuit (reconciled Phase 3) |
| `BalancerV3.sol` | ⚠️ | Multiple intentional improvements: `previewRedeem` fix, non-ERC4626 else-branch, try/catch, L2 fallback, underflow guard (reconciled Phase 3 + Round 4 fix) |
| `Aura.sol` | ⚠️ | L2 support restored 2026-04-16 (commit `62fcdee`): dynamic AURA resolution via `Booster.minter()`/`L2Coordinator.auraOFT()`, `IS_MAINNET` flag, `calculateL2AuraMint`. Constructor dropped `auraToken_` (8→7 params). Plus ERC4626 fix, try/catch on stash wrapper, more defensive gauge/pool validation (reconciled Phase 3). |
| `DaiDsr.sol` | ✅ | Naming conventions only (reconciled Phase 3) |
| `StakeWiseV3Vault.sol` | ✅ | Naming conventions only; v1/v2 split is logically equivalent (reconciled Phase 3) |
| `StakeWiseV3OsToken.sol` | ✅ | Naming conventions only (reconciled Phase 3) |
| `SkySavingsUsds.sol` | ⚠️ | Bug fix: `_positionDetail` field now used instead of hardcoded string (reconciled Phase 3) |
| `MorphoVault.sol` | ⚠️ | OA hoists `_calculateBalance` outside loop (improvement); Round 4 Copilot fix |
| `GearboxMarket.sol` | ⚠️ | OA hoists `_calculateBalance` outside loop (improvement); Round 4 Copilot fix |
| `Cap.sol` | ✅ | Logic identical |
| `Curve.sol` | ⚠️ | CRV lower-bound uses `integrate_fraction − minted`; OA adds `return 0` when `minted()` fails (intentional improvement); hardcoded mainnet addresses (established pattern) |
| `Convex.sol` | ⚠️ | CVX only returned via stash wrapper — intentional design (no stash = no CVX; see Copilot Round 3 decline rationale); `lpToken_` passed explicitly |
| `ERC20DefaultOracle.sol` | — | New in OA — no KTF counterpart |
| `CompoundV3Comet.sol` | — | New in OA — no KTF counterpart |

### Balance oracle tests — parity

| Test file | Unit | Fork | Notes |
|-----------|------|------|-------|
| `AaveV3Instance.t.sol` | ✅ (6/6) | ✅ (7/7) | |
| `AaveV3SafetyModule.t.sol` | ✅ (6/6) | ✅ (11/11) | |
| `SparkLend.t.sol` | ✅ (4/4) | ✅ (7/7) | Reward test removed — no active campaign |
| `MorphoMarket.t.sol` | ✅ (7/7) | ✅ (9/9) | |
| `BalancerV3.t.sol` | ✅ (7/7) | ✅ (9/9) | Mainnet (7/7) + Arbitrum L2 (2/2). New `BalancerV3.L2.fork.t.sol` ports v1's `test_claimableTokens_arbitrum` — asserts exact v1 value `2_759_910_397_061_400_746` BAL to catch any L2 fallback regressions. |
| `Aura.t.sol` | ✅ (2/2) | ✅ (9/9) | Mainnet (4/4) + Arbitrum L2 (5/5). New `Aura.L2.fork.t.sol` ports v1's `test_arbitrum_l2_aura_rewards` and adds 4 L2-specific assertions. |
| `DaiDsr.t.sol` | ✅ (4/4) | ✅ (4/4) | |
| `StakeWiseV3Vault.t.sol` | ✅ (6/6) | ✅ (7/7) | |
| `StakeWiseV3OsToken.t.sol` | ✅ (5/5) | ✅ (3/3) | |
| `SkySavingsUSDS.t.sol` | ✅ (1/1) | ✅ (8/8) | |
| `MorphoVault.t.sol` | ✅ (13/13) | ✅ (11/11) | |
| `GearboxMarket.t.sol` | ✅ (13/13) | ✅ (12/12) | |
| `Cap.t.sol` | ✅ (17/17) | ✅ (9/9) | |
| `Curve.t.sol` | ✅ (15/15) | ✅ (15/15) | |
| `Convex.t.sol` | ✅ (17/17) | ✅ (13/13) | |
| `ERC20DefaultOracle.t.sol` | ✅ | ✅ | New in OA |
| `CompoundV3Comet.t.sol` | ✅ | ✅ | New in OA |

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

---

## Aspects to improve going forward

The migration is closed, but several items are known limitations or follow-ups worth acting on in separate PRs.

### Blocking or near-blocking

- [x] **`SparkLend` dispatch bug in `04_DeployBalanceAdapters.s.sol`** — **fixed 2026-04-17 (docs PR).** `run()` calls `_deployIfEnabled("SparkLend")` (bare name, post-rename), but `_deployAdapter` used to only match the `SparkLend_` prefix. The dispatcher now accepts both bare and prefixed names:
  ```solidity
  if (_equals(adapterName, "SparkLend") || _startsWith(adapterName, "SparkLend_")) {
      return _deploySparkLend(adapterName, navCalculator);
  }
  ```
  Same pattern applies to any future single-instance adapter.

- [ ] **`AtomicProxyDeployer` retains orphaned `DEFAULT_ADMIN_ROLE`.** After the atomic deploy, the deployer contract's address still shows `hasRole(DEFAULT_ADMIN_ROLE, ...) == true` in the NAV and Bridge proxies. The contract has no runtime code that can act on it (constructor-only, no external functions), so it's functionally dead. Still cosmetically undesirable — consider adding a self-revoke to the constructor, or a post-deploy Safe TX that revokes the orphaned role.

- [ ] **`02_DeployProxies.s.sol` MANAGER-grant reverts when `chainConfig.admin` is a Safe.** Lines 179-183 call `grantRole(MANAGER, chainConfig.manager)` from the broadcast sender (deployer EOA). In both the atomic and legacy paths, only `chainConfig.admin` ends up with `DEFAULT_ADMIN_ROLE` — the deployer EOA is never granted it. Since every current chain config sets `addresses.admin` to a Safe (Mainnet: `0x00008bB2Ff12ca49eD157B21a0D955c63C9ab31F`), running `02_DeployProxies.s.sol` as-is against these configs reverts at the MANAGER grant. Workaround until fixed: temporarily set `chainConfig.admin` = deployer EOA for deploy, then transfer via Safe afterwards; or skip/guard the grant in `02` and let `06_Configure.s.sol` do it. Proper fix: guard the block on `msg.sender == chainConfig.admin` (or on `hasRole(DEFAULT_ADMIN_ROLE, msg.sender)`), and either move the MANAGER grant into the `AtomicProxyDeployer` constructor or hand it off to `06_Configure.s.sol`. Must fix before the next NAV v2 deployment or the existing chains will need manual intervention. Surfaced by PR #13 review (Copilot).

### Non-blocking follow-ups

- [ ] **Native xDAI coverage on Gnosis (runbook gap 5).** `ERC20Default` pre-inserts the `NATIVE_ADDRESS` sentinel at NAVCalculator init, but no fork test confirms that `getOracleBalanceForAsset(NATIVE_ADDRESS, safe)` returns the correct native balance on Gnosis. USD Alpha uses native xDAI. Add a Gnosis fork test against a Safe that holds xDAI before the Gnosis Alpha deploy goes live.

- [ ] **Curve and Convex hardcoded mainnet addresses.** `_CRV_TOKEN` and `_CURVE_MINTER` in `Curve.sol`, `_CVX_TOKEN` in `Convex.sol`. Mirrors v1. Fine today because these adapters are Mainnet-only in our inventory, but if we ever deploy Curve/Convex on an L2 we'd either (a) pass the addresses via constructor or (b) add a `block.chainid` guard. Prefer (a) for testability.

- [ ] **Convex CVX via stash wrapper only.** Intentional design documented in the Round 3 review thread and in `Convex.sol` NatSpec. Every Convex pool we include must be verified to expose a CVX stash wrapper in `extraRewards` (see `convex_cvx_stash_check.md` memory). If Convex ever migrates away from stash wrappers, revisit the `_checkExtraReward` flow. For now, keep the pre-deploy check as part of the pool-onboarding runbook.

- [ ] **L2 fork-test coverage for oracles other than Aura + BalancerV3.** `calculateIntegrateFractionL2` in Aura and BalancerV3 is exercised by L2 fork tests now. Other oracles with implicit L2 behavior (any that branch on `IS_MAINNET`, or any that derive an address via `Booster.minter()` / similar chain-dependent paths) should grow matching L2 fork tests. None identified in the PR #12 audit, but worth re-checking as protocols add L2 deployments.

- [ ] **Sequencer uptime grace period.** `NAVCalculator.chainlinkL2SequencerGracePeriod` is initialised to 1 hour. Reasonable default but arbitrary — review against the fund's acceptable tolerance (a 1-hour stale window can materially misrepresent NAV during volatile recovery). If we want tighter guarantees, expose this as a config field and set per-chain.

- [ ] **`_latestPrice` natspec has a `COMPLETE ME` placeholder** (`src/prices/Prices.sol:56`). Fill in the stale semantics in prose.

- [ ] **Bridge adapters on Mainnet + Optimism + Gnosis.** Config-enabled where applicable, not yet broadcast. Non-blocking for current funds; deploy when the first fund needs to bridge *from* those chains (see runbook gap 4).

- [ ] **Shares v2 consumes NAV on-chain?** Currently no — `kpkShares` uses off-chain price submission via `settleRequests`. If a future fund wires NAV on-chain, it must check `nav.stalePriceAssets` and `nav.sequencerDown` — NAVCalculator does not revert on stale, it returns best-effort value plus flags. Document this explicitly in any new on-chain consumer.

---

## Lessons learned

Notes worth carrying into future migrations or large refactors.

### What went well

- **Stacked PRs with explicit scope per PR.** PR #10 (surgical / removals), #11 (prices + deploy wiring), #12 (balances + deploy wiring + L2 parity) kept each review tractable. Each PR had a clean green CI before moving the next up. Would do again for any multi-concern migration.

- **Systematic v1↔v2 audit at the end.** Phase 5's file-by-file parity check caught the Aura L2 regression that the normal test suite missed (because v2 never had an L2 Aura fork test). Audit before merging, not after.

- **Config-driven per-chain deployment.** `_deployIfEnabled` + per-chain JSON with `deployed` fields is idempotent, diffable, and easy to reason about. Much better than v1's per-fund `{Chain}.s.sol` duplication.

- **Porting fork tests alongside oracle implementations.** Every fork test that asserted an exact v1 value (e.g. `2_759_910_397_061_400_746` BAL from BalancerV3 L2) served as a regression-proof port. If the test value matches, the math matches.

### What we'd do differently

- **Audit first, port second.** We ported some oracles before realizing they'd already been migrated with intentional divergences (`BalancerV3`, `Aura`). Running Phase 3 reconciliation earlier (or before starting Phase 1) would have saved a rebase and some wasted work.

- **Don't trust "intentional divergence" notes blindly.** The Aura L2 support loss was originally documented as an intentional drop — it wasn't. A single-line notebook entry saying "intentional" isn't audit-proof; rerun the diff and re-justify every divergence at merge time.

- **Scope expansion mid-PR was a smell.** Both PR #11 and PR #12 got scope expansions (deploy-script wiring) late in the review cycle because the original plan didn't track "each oracle ships with a deploy function." Next time, include the deploy wiring in the per-oracle checklist from day 1.

- **Copilot false positives are common in Foundry-land.** Copilot flagged four `MockToken` name collisions across test files that don't actually collide (Foundry compiles test files independently). Reviewing Copilot suggestions against the actual toolchain, not a generic Solidity compiler model, saved a pointless refactor.

- **Brittle config plumbing bites quietly.** `vm.writeJson` requires the parent object to exist — an empty `priceFeeds: {}` key is load-bearing. `SparkLend` prefix match (see follow-ups above) silently swallows errors. Every `_deployIfEnabled` helper should log and *fail loud* on "Unknown adapter type" in CI.

### Process notes

- **Keep `memory/convex_cvx_stash_check.md`-style notes.** Small, specific, actionable (a cast command + a verified pool table). Those were the memory entries that saved the most time during review.

- **Every PR description should reference this plan document + which sections it covers.** PR #10/#11/#12 all did; makes the retrospective trivial to write.

- **Don't let the runbook drift.** `NAV_V2_DEPLOYMENT_RUNBOOK.md` was stale within days of PR #12 merging (the "Known Gaps" section still listed gaps 1–3 as blocking when they were closed). Any PR that changes deploy scripts, adapter families, or role flow *must* update the runbook in the same PR.

---

## How to extend this repo after the migration

Forward-looking guidance. The migration is closed — these are the workflows for additions.

- **New Custom price oracle:** follow the ["How to add a new Custom price oracle"](script/NAV_V2_DEPLOYMENT_RUNBOOK.md#how-to-add-a-new-custom-price-oracle) section of the runbook.
- **New balance adapter (protocol or instance):** follow the ["How to add a new balance adapter"](script/NAV_V2_DEPLOYMENT_RUNBOOK.md#how-to-add-a-new-balance-adapter) section of the runbook.
- **New fund on existing chains:** no code changes needed — just register assets on NAVCalculator (Phase 5 of the runbook) and ensure the relevant balance oracles are already registered. If the fund needs a protocol we don't yet support, add the adapter first.
- **New chain:** see `DEPLOYMENT_SUMMARY.md` for the CREATE2 + atomic-proxy flow. Add the chain config, run `01_DeployImplementations.s.sol`, `02_DeployProxies.s.sol`, then follow the runbook Phases 1–9.
