# Position Identity Schema

Every `PositionBalance` and `Position` returned by the NAV stack carries three typed fields that
form a stable, machine-readable identity for each position. This document explains what they are,
how to decode them, and how to use them for indexing, reconciliation, and action routing.

---

## The three identity fields

```solidity
struct PositionBalance {
    Asset        balanceAsset;    // token the amount is denominated in
    address      balanceOracle;   // adapter address — provenance only, NOT part of identity
    uint256      amount;          // always positive
    bool         isDebt;         // NAV sign: true = subtract
    bytes32      protocolId;     // keccak256("protocol-slug") — selects decode schema
    bytes        positionId;     // abi.encode(...) — stable position key
    PositionKind positionKind;   // Wallet | Supplied | Borrowed | Collateral | Earned
}
```

`balanceOracle` is explicitly excluded from the identity — it is provenance (which adapter
reported this row) and can change when an adapter is redeployed without the position changing.

---

## `protocolId` — which protocol

`protocolId` is `keccak256` of a canonical ASCII slug. A single slug maps to exactly one
`positionId` ABI-decode schema, so you can switch on `protocolId` and know exactly how to
decode `positionId` without any runtime sniffing.

All constants live in [`src/utils/ProtocolIds.sol`](../../src/utils/ProtocolIds.sol).

```solidity
bytes32 protocolId = keccak256("aave-v3-lending");  // == ProtocolIds.AAVE_V3_LENDING
```

---

## `positionId` — which instance

`positionId` is `abi.encode(...)` of the position's stable key. The exact schema depends on
`protocolId` — one slug, one schema. Full table:

| `protocolId` slug | `positionId` = `abi.encode(...)` |
|---|---|
| `wallet` | `""` (empty bytes) |
| `aave-v3-lending` | `(address pool, address reserve)` |
| `aave-v2-lending` | `(address pool, address reserve)` |
| `spark-lend` | `(address pool, address reserve)` |
| `aave-v3-safety-module` | `(address stakeToken)` |
| `aave-v3-umbrella` | `(address stakeToken)` |
| `morpho-vaults` | `(address vault)` |
| `morpho-markets` | `(bytes32 marketId)` |
| `gearbox-v3` | `(address market)` |
| `compound-v3` | `(address comet)` |
| `fluid-ftokens` | `(address fToken)` |
| `fluid-vaults` | `(address vault)` |
| `balancer-v3-pool` | `(address pool)` |
| `balancer-v3-gauge` | `(address gauge)` |
| `balancer-v2-pool` | `(bytes32 poolId)` |
| `balancer-v2-gauge` | `(address gauge)` |
| `curve-pool` | `(address pool)` |
| `curve-gauge` | `(address gauge)` |
| `convex` | `(address rewarder)` |
| `aura` | `(address auraRewards)` |
| `uniswap-v3` | `(address npm, uint256 tokenId)` |
| `uniswap-v2` | `(address pair)` |
| `pancakeswap-v3` | `(address npm, uint256 tokenId)` |
| `pancakeswap-v2` | `(address pair)` |
| `stakewise-v3` | `(address vault)` |
| `cap` | `(address vault)` |
| `erc4626` | `(address vault)` |
| `dai-dsr` | `""` (account-global) |
| `sky-savings` | `(address savingsContract)` |
| `merkl` | `(address rewardToken)` |
| `stader-withdrawal` | `""` (account-global) |
| `kelp-withdrawal` | `""` (account-global) |
| `lido-withdrawal` | `""` (account-global) |
| `bridge-escrow` | `(address escrow, address token)` |

**Empty positionId** means the position is account-global for that protocol — there is only ever
one such position per account (e.g. DAI Savings Rate, Lido withdrawal queue).

---

## `PositionKind` — what kind of position

```solidity
enum PositionKind {
    Wallet,     // plain ERC20 / native balance (ERC20DefaultOracle)
    Supplied,   // lending supply, vault shares, staking principal, LP principal
    Borrowed,   // any debt position (isDebt = true)
    Collateral, // supply locked as collateral (e.g. Aave usageAsCollateralEnabled = true)
    Earned      // accrued but not yet claimed: rewards, uncollected fees
}
```

`Collateral` is kept distinct from `Supplied` because collateral cannot be freely withdrawn —
a consumer routing to a "withdraw" action needs to know this.

---

## The stable reconciliation key

The per-chain primary key for caching, indexing, and reconciliation:

```solidity
bytes32 key = keccak256(abi.encode(
    chainId,
    protocolId,
    positionId,
    balanceAsset.asset,
    positionKind
));
```

In TypeScript:

```typescript
import { keccak256, AbiCoder } from "ethers";

const abi = AbiCoder.defaultAbiCoder();
const key = keccak256(abi.encode(
    ["uint256", "bytes32", "bytes", "address", "uint8"],
    [chainId, position.protocolId, position.positionId, position.balanceAsset.asset, position.positionKind]
));
```

**Excluded from the key by design:**
- `balanceOracle` — provenance only; redeploying an adapter doesn't change the position
- `isDebt` — derivable from `positionKind == Borrowed`

---

## Adapter reference — positionId decode and legs

The table below and the TypeScript examples cover every adapter in the codebase. All
decodes use `AbiCoder.defaultAbiCoder()` from ethers.js. Protocol ID constants come from
`ProtocolIds.sol` (`keccak256(toUtf8Bytes("<slug>"))`).

### PositionKind summary per adapter

| Adapter | `protocolId` slug | Legs emitted (`PositionKind`) |
|---|---|---|
| `ERC20DefaultOracle` | `wallet` | `Wallet` |
| `AaveV3InstancesMeta` | `aave-v3-lending` | `Supplied`, `Collateral`, `Borrowed` |
| `AaveV2InstancesMeta` | `aave-v2-lending` | `Supplied`, `Collateral`, `Borrowed` |
| `SparkLend` | `spark-lend` | `Supplied`, `Collateral`, `Borrowed` |
| `AaveV3SafetyModule` | `aave-v3-safety-module` | `Supplied`, `Earned` |
| `AaveUmbrella` | `aave-v3-umbrella` | `Supplied`, `Earned` |
| `MorphoVaultsMeta` | `morpho-vaults` | `Supplied` |
| `MorphoMarketsMeta` | `morpho-markets` | `Collateral`, `Supplied`, `Borrowed` |
| `GearboxMarketsMeta` | `gearbox-v3` | `Supplied` |
| `FluidFTokensMeta` | `fluid-ftokens` | `Supplied` |
| `FluidVaultsMeta` | `fluid-vaults` | `Collateral`, `Borrowed` |
| `CompoundV3CometsMeta` | `compound-v3` | `Supplied`, `Borrowed`, `Collateral`, `Earned` |
| `StakeWiseV3VaultsMeta` | `stakewise-v3` | `Supplied`, `Borrowed` |
| `BalancerV3PoolsMeta` | `balancer-v3-pool` | `Supplied` |
| `BalancerV3GaugesMeta` | `balancer-v3-gauge` | `Supplied`, `Earned` |
| `BalancerV2PoolsMeta` | `balancer-v2-pool` | `Supplied` |
| `BalancerV2GaugesMeta` | `balancer-v2-gauge` | `Supplied`, `Earned` |
| `CurvePoolsMeta` | `curve-pool` | `Supplied` |
| `CurveGaugesMeta` | `curve-gauge` | `Supplied`, `Earned` |
| `ConvexRewardsMeta` | `convex` | `Supplied`, `Earned` |
| `AuraRewardsMeta` | `aura` | `Supplied`, `Earned` |
| `UniswapV3PoolsMeta` / `PancakeSwapV3PoolsMeta` | `uniswap-v3` / `pancakeswap-v3` | `Supplied`, `Earned` |
| `UniswapV2PoolsMeta` / `PancakeSwapV2PoolsMeta` | `uniswap-v2` / `pancakeswap-v2` | `Supplied` |
| `Cap` | `cap` | `Supplied` |
| `ERC4626Wrap` | `erc4626` | `Supplied` |
| `DaiDsr` | `dai-dsr` | `Supplied` |
| `SkySavingsUsds` | `sky-savings` | `Supplied` |
| `MerklRewards` | `merkl` | `Earned` |
| `LidoWithdrawalQueue` | `lido-withdrawal` | `Supplied` |
| `StaderWithdrawalQueue` | `stader-withdrawal` | `Supplied` |
| `KelpWithdrawalQueue` | `kelp-withdrawal` | `Supplied` |

---

### Decode examples

```typescript
import { AbiCoder, keccak256, toUtf8Bytes } from "ethers";
const abi = AbiCoder.defaultAbiCoder();
```

#### ERC20 wallets — `wallet`

```typescript
// positionId = "" — no decode needed, balanceAsset.asset is the token
// positionKind = Wallet
```

#### Aave V3 / Aave V2 / Spark — `aave-v3-lending` / `aave-v2-lending` / `spark-lend`

Per-reserve positionId: each supply, collateral, and borrow leg for the same reserve shares
one positionId; different reserves have different positionIds.

```typescript
const [pool, reserve] = abi.decode(["address", "address"], pos.positionId);
// pool   — IPool (V3) / ILendingPool (V2) / SparkPool
// reserve — the underlying ERC20 (USDC, WETH, …)

// Action routing:
// Borrowed  → pool.repay(reserve, pos.amount, 2, account)
// Supplied  → pool.withdraw(reserve, pos.amount, account)
// Collateral → pool.withdraw(reserve, pos.amount, account)  (if health factor allows)
```

#### Aave V3 Safety Module — `aave-v3-safety-module`

```typescript
const [stakeToken] = abi.decode(["address"], pos.positionId);
// stakeToken — stkAAVE, stkABPT, stkABPTv2, or stkGHO
// Supplied   → staked principal (denominated in the stake token's STAKED_TOKEN())
// Earned     → claimable AAVE rewards
```

#### Aave Umbrella — `aave-v3-umbrella`

```typescript
const [stakeToken] = abi.decode(["address"], pos.positionId);
// stakeToken — UmbrellaStakeToken (e.g. stkwaEthUSDC.v1, stkGHO.v1)
// Supplied   → principal, denominated in the bare reserve (USDC, WETH, GHO …)
// Earned     → claimable rewards, same bare reserve denomination
```

#### Morpho Vaults — `morpho-vaults`

```typescript
const [vault] = abi.decode(["address"], pos.positionId);
// vault — MetaMorpho ERC4626 vault address
// Supplied → convertToAssets(balanceOf(account)), denominated in vault.asset()
```

#### Morpho Markets — `morpho-markets`

Per-reserve positionId (same as Aave): one positionId per (collateralToken, loanToken) market.

```typescript
const [marketId] = abi.decode(["bytes32"], pos.positionId);
// marketId — Morpho Blue market ID (keccak of MarketParams)
// Collateral → collateral token supplied
// Supplied   → loan token supplied (lending side)
// Borrowed   → loan token borrowed
```

#### Gearbox V3 — `gearbox-v3`

```typescript
const [market] = abi.decode(["address"], pos.positionId);
// market — Gearbox V3 ERC4626 farming pool
// Supplied → convertToAssets(balanceOf(account))
```

#### Fluid fTokens — `fluid-ftokens`

```typescript
const [fToken] = abi.decode(["address"], pos.positionId);
// fToken — Fluid fToken (ERC4626 lending vault)
// Supplied → convertToAssets(balanceOf(account))
```

#### Fluid Vaults — `fluid-vaults`

```typescript
const [vault] = abi.decode(["address"], pos.positionId);
// vault — Fluid T1 vault contract
// Collateral → aggregated collateral across all of account's NFT positions
// Borrowed   → aggregated debt
```

#### Compound V3 — `compound-v3`

```typescript
const [comet] = abi.decode(["address"], pos.positionId);
// comet — Comet market (e.g. cUSDCv3, cWETHv3)
// Supplied    → base-token supply
// Borrowed    → base-token borrow
// Collateral  → individual collateral asset legs
// Earned      → COMP rewards (claimable)
```

#### StakeWise V3 — `stakewise-v3`

```typescript
const [vault] = abi.decode(["address"], pos.positionId);
// vault — StakeWise V3 ERC4626-like vault
// Supplied → vault shares → underlying (ETH / GNO)
// Borrowed → minted osToken debt → underlying equivalent
```

#### Balancer V3 Pools — `balancer-v3-pool`

```typescript
const [pool] = abi.decode(["address"], pos.positionId);
// pool — Balancer V3 pool / BPT address
// Supplied → one leg per pool token (wallet-held, unstaked BPT)
```

#### Balancer V3 Gauges — `balancer-v3-gauge`

```typescript
const [gauge] = abi.decode(["address"], pos.positionId);
// gauge — Balancer V3 liquidity gauge
// Supplied → one leg per pool token (gauge-staked BPT share)
// Earned   → BAL + extra reward token legs
```

#### Balancer V2 Pools — `balancer-v2-pool`

The instance coordinate IS the raw bytes32 poolId (not an address). The BPT address is its
top 160 bits.

```typescript
const [poolId] = abi.decode(["bytes32"], pos.positionId);
const bpt = "0x" + poolId.slice(2, 42);          // top 20 bytes of poolId
// Supplied → one leg per underlying pool token (wallet-held BPT)
```

#### Balancer V2 Gauges — `balancer-v2-gauge`

```typescript
const [gauge] = abi.decode(["address"], pos.positionId);
// gauge — Balancer V2 liquidity gauge (child or root)
// Supplied → one leg per pool token (gauge-staked BPT share)
// Earned   → BAL + extra reward token legs
```

#### Curve Pools — `curve-pool`

```typescript
const [pool] = abi.decode(["address"], pos.positionId);
// pool — Curve pool address (also LP token for classic/TriCryptoNG pools)
// Supplied → one leg per registered pool coin (wallet-held LP, pro-rata)
```

#### Curve Gauges — `curve-gauge`

```typescript
const [gauge] = abi.decode(["address"], pos.positionId);
// gauge — Curve liquidity gauge
// Supplied → one leg per pool coin (staked LP share, pro-rata)
// Earned   → CRV (lower-bound) + extra reward token legs
```

#### Convex — `convex`

```typescript
const [rewarder] = abi.decode(["address"], pos.positionId);
// rewarder — Convex BaseRewardPool address
// Supplied → one leg per underlying Curve pool coin (staked LP, pro-rata)
// Earned   → CRV, CVX, and extra reward token legs
```

#### Aura — `aura`

```typescript
const [auraRewards] = abi.decode(["address"], pos.positionId);
// auraRewards — Aura BaseRewardPool4626 address
// Supplied → one leg per Balancer pool token (staked BPT share)
// Earned   → BAL, AURA, and extra reward token legs
```

#### Uniswap V3 / PancakeSwap V3 — `uniswap-v3` / `pancakeswap-v3`

Per-NFT positionId: each NFT (tokenId) gets its own positionId. Multiple NFTs in the same
pool each have a distinct positionId. All legs of one NFT (token0 liquidity, token1
liquidity, token0 fees, token1 fees) share the same positionId.

```typescript
const [npm, tokenId] = abi.decode(["address", "uint256"], pos.positionId);
// npm     — NonfungiblePositionManager (canonical per chain)
// tokenId — NFT token ID
// Supplied → in-range liquidity (token0 and token1 legs)
// Earned   → unclaimed fee legs (token0 and token1)

// Collect fees:
if (pos.positionKind === PositionKind.Earned) {
  await npmContract.collect({ tokenId, recipient: account, amount0Max: MAX, amount1Max: MAX });
}
```

#### Uniswap V2 / PancakeSwap V2 — `uniswap-v2` / `pancakeswap-v2`

```typescript
const [pair] = abi.decode(["address"], pos.positionId);
// pair — UniswapV2Pair / PancakeSwap V2 Pair address
// Supplied → two legs: token0 and token1 pro-rata from wallet-held LP
```

#### Cap — `cap`

```typescript
const [vault] = abi.decode(["address"], pos.positionId);
// vault — Cap cUSD token address
// Supplied → account's cUSD redeemable value in underlying (USDC, etc.)
```

#### ERC4626 wrapper — `erc4626`

```typescript
const [wrapper] = abi.decode(["address"], pos.positionId);
// wrapper — ERC4626 share token (e.g. waEthLidoGHO stata-token)
// Supplied → convertToAssets(balanceOf(account)) in wrapper.asset()
```

#### DAI Savings Rate — `dai-dsr`

```typescript
// positionId = "" — account-global, one position per account
// Supplied → DAI balance in the DSR (chi-adjusted)
```

#### Sky Savings (sUSDS) — `sky-savings`

```typescript
const [savingsContract] = abi.decode(["address"], pos.positionId);
// savingsContract — SavingsUSDS contract address
// Supplied → USDS balance (convertToAssets(balanceOf(account)))
```

#### Merkl rewards — `merkl`

```typescript
const [rewardToken] = abi.decode(["address"], pos.positionId);
// rewardToken — the ERC20 reward token
// Earned → unclaimed allocation (proof-cached; may be stale between proof updates)
```

#### Lido / Stader / Kelp withdrawal queues — `lido-withdrawal` / `stader-withdrawal` / `kelp-withdrawal`

```typescript
// positionId = "" — account-global; one position per account per queue
// Supplied → summed ETH owed across all open (unclaimed) request IDs
// balanceAsset is the underlying (native ETH sentinel for Lido/Stader, the LST asset for Kelp)
```

---

## Human-readable labels — `IPositionDescribable` and `NavLens`

The typed fields are for machines. For human-readable display, two mechanisms exist:

### `IPositionDescribable` (on each adapter)

```solidity
interface IPositionDescribable {
    function protocolName() external view returns (string memory); // "Aave V3", "Morpho", …
    function describePosition(bytes calldata positionId) external view returns (string memory); // "USDC supply"
}
```

All adapters implement this. Meta-adapters derive the label on-chain from live state (ERC20
symbols, vault names, pool composition). Per-instance adapters return static strings.

### `NavLens` — verbose read side-car

[`src/nav/NavLens.sol`](../../src/nav/NavLens.sol) is a stateless read-only contract that
wraps `NAVCalculator` and adds human-readable labels:

```solidity
struct VerbosePosition {
    Position position;     // full enriched position (typed identity + pricing)
    string   protocolName; // e.g. "Curve", "Morpho"
    string   positionLabel; // e.g. "USDC/crvUSD gauge", "kpk ETH Prime V1 vault"
}

// Deployment: same address on every chain
navLens.getAccountPositionsVerbose(account, quoteAsset)
navLens.getAccountNavVerbose(account, quoteAsset)  // NAV + all verbose positions in one call
```

Labels come from each oracle's `IPositionDescribable` implementation. If an oracle doesn't
implement it, both fields are empty strings. **Never use these strings for identity, indexing,
or reconciliation** — they are display-only and may change as labels evolve.

---

## Adding a new adapter

When implementing a new balance adapter:

1. Add a slug to [`src/utils/ProtocolIds.sol`](../../src/utils/ProtocolIds.sol) and document the
   `positionId` schema in its NatSpec comment.
2. Choose a `positionId` encoding: `abi.encode(primaryKey)` where `primaryKey` is the most
   specific on-chain address or identifier for this adapter instance.
3. Assign `positionKind` per leg:
   - Lending supply (freely withdrawable) → `Supplied`
   - Lending supply as collateral → `Collateral`
   - Debt → `Borrowed`
   - Vault shares, staked tokens, LP principal → `Supplied`
   - Unclaimed rewards or fees → `Earned`
   - ERC20 wallet balance → `Wallet`
4. Implement `IPositionDescribable` to provide human-readable labels:
   - `protocolName()` — static `pure` string for per-instance adapters; same constant for meta-adapters
   - `describePosition(bytes positionId)` — derive on-chain for meta-adapters (decode positionId,
     read token symbols); static string for per-instance adapters
5. Update this table above and the `ProtocolIds` schema comment.

See [`howto/add-balance-adapter.md`](add-balance-adapter.md) for the full end-to-end recipe.
