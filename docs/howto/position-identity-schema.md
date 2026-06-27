# Position Identity Schema

Every `PositionBalance` returned by the NAV stack carries a stable, machine-readable identity.
This document explains all fields, provides a concrete example for every adapter, and describes
how to decode and use the identity for indexing, reconciliation, and action routing.

---

## `PositionBalance` — field reference

```solidity
struct PositionBalance {
    Asset        balanceAsset;   // token the amount is denominated in
    address      balanceAdapter;  // adapter that reported this row (provenance only)
    uint256      amount;         // magnitude, always positive
    bool         isDebt;         // NAV sign: true = subtract, false = add
    bytes32      protocolId;     // keccak256("protocol-slug")
    bytes        positionId;     // abi.encode(...) — stable on-chain key
    PositionKind positionKind;   // Wallet | Supplied | Borrowed | Collateral | Staking | Rewards | Fees
}
```

### Field descriptions

**`balanceAsset`** — `Asset { address asset; string symbol; uint8 decimals; }`

The ERC20 token (or native-token sentinel `0xEeee…EeeE`) that `amount` is denominated in.
Populated from NAVCalculator's asset registry; `symbol` and `decimals` are the registry values,
not read live from the token contract.

**`balanceAdapter`** — `address`

The adapter contract that produced this row. Provenance / audit trail — changing which adapter
is registered does not change the position. Excluded from the reconciliation key.

**`amount`** — `uint256`

Balance magnitude at the asset's native decimal precision. Always positive: debts are signalled
by `isDebt = true`, never by a negative `amount`. NAVCalculator multiplies by `-1` when
`isDebt` is true to compute the signed NAV contribution.

**`isDebt`** — `bool`

`true` → this row subtracts from NAV (borrow, debt). `false` → this row adds to NAV (credit,
supply, rewards, fees). `positionKind == Borrowed` implies `isDebt = true`; all other kinds
imply `isDebt = false`.

**`protocolId`** — `bytes32`

`keccak256` of a canonical kebab-case ASCII slug (e.g. `"aave-v3-lending"`). A single slug
maps to exactly one `positionId` ABI-decode schema — switch on `protocolId` to know how to
decode `positionId` without runtime sniffing. Constants in `src/utils/ProtocolIds.sol`.

**`positionId`** — `bytes`

`abi.encode(...)` of the stable on-chain key for this position. Account-global
positions (withdrawal/exit queues, the Ethena cooldown) encode their immutable
anchor contract — `abi.encode(address <queue/manager>)` — since there is one
aggregated leg per account. The schema is uniquely determined by `protocolId`;
full table below.

**`positionKind`** — `PositionKind`

Semantic category of the leg. Together with `protocolId`, `positionId`, and
`balanceAsset.asset` it forms the per-chain reconciliation key:
`keccak256(abi.encode(chainId, protocolId, positionId, balanceAsset.asset, positionKind))`.

### The enriched sibling: `Position`

NAVCalculator's `getAccountPositions` returns `Position`, which adds pricing on top:

```solidity
struct Position {
    // PositionBalance's balance fields: balanceAsset, balanceAdapter, amount, isDebt +
    Asset   quoteAsset;      // quote currency (USD, ETH, …)
    int256  value;           // signed value in quoteAsset (negative for debt)
    int256  price;           // price used: quoteAsset per balanceAsset unit
    uint8   priceDecimals;   // decimal precision of price
    bool    stale;           // true if the price feed was stale at query time
    // + the identity fields: protocolId, positionId, positionKind
}
```

`PositionBalance` is the raw output of balance adapters; `Position` is what consumers typically
work with. Both share the same identity fields.

---

## `PositionBalance` examples

One representative leg per adapter using realistic but fictional amounts. For adapters that
emit multiple legs the most informative leg is shown; other legs are noted inline.

Token addresses (Mainnet): USDC `0xA0b8…6eB48` · WETH `0xC02a…6Cc2` · DAI `0x6B17…1d0F` ·
stETH `0xae7a…2Ca0` · wstETH `0x7f39…Ca0` · CRV `0xD533…cd52` · AAVE `0x7Fc6…DaE9` ·
GHO `0x40D1…2f` · USDS `0xdC03…84F` · ETH (native) `0xEeee…EeeE`

Protocol contract addresses are shown as `0x<Name>` to remain chain-agnostic.

---

### Per-instance adapters

#### `ERC20DefaultBalanceAdapter` — wallet balance

```solidity
// One leg per registered asset held directly in the account.
PositionBalance({
    balanceAsset:  Asset({ asset: 0xA0b8…6eB48, symbol: "USDC", decimals: 6 }),
    balanceAdapter: 0x<ERC20DefaultBalanceAdapter>,
    amount:        1_500_000_000,          // 1 500.000000 USDC
    isDebt:        false,
    protocolId:    keccak256("wallet"),
    positionId:    abi.encode(0xA0b8…6eB48),  // abi.encode(asset)
    positionKind:  PositionKind.Wallet
})
```

#### `SparkLend` — lending supply

```solidity
// One positionId per instance = abi.encode(pool); reserves are distinguished by balanceAsset + positionKind.
// Other legs: Collateral (usageAsCollateralEnabled = true), Borrowed (variableDebt).
PositionBalance({
    balanceAsset:  Asset({ asset: 0x6B17…1d0F, symbol: "DAI", decimals: 18 }),
    balanceAdapter: 0x<SparkLendAdapter>,
    amount:        3_000e18,               // 3 000 DAI
    isDebt:        false,
    protocolId:    keccak256("spark-lend"),
    positionId:    abi.encode(0x<SparkPool>),   // the Spark Pool (reserve is in balanceAsset)
    positionKind:  PositionKind.Supplied
})
```

#### `AaveV3SafetyModule` — staked AAVE

```solidity
// One positionId per stake token (stkAAVE / stkABPT / stkABPTv2 / stkGHO).
// Staking principal is denominated in the stake token's STAKED_TOKEN (AAVE for stkAAVE).
// Other legs: Rewards (claimable AAVE reward, denominated in AAVE — the REWARD_TOKEN, for every stake token).
PositionBalance({
    balanceAsset:  Asset({ asset: 0x7Fc6…DaE9, symbol: "AAVE", decimals: 18 }),
    balanceAdapter: 0x<AaveV3SafetyModuleAdapter>,
    amount:        500e18,                 // 500 AAVE staked in stkAAVE
    isDebt:        false,
    protocolId:    keccak256("aave-v3-safety-module"),
    positionId:    abi.encode(0x<stkAAVE>),
    positionKind:  PositionKind.Staking
})
```

#### `AaveUmbrella` — Umbrella stake token

```solidity
// Dynamically discovered via RewardsController.getAllAssets().
// Other legs: Rewards (claimable reward in bare reserve).
PositionBalance({
    balanceAsset:  Asset({ asset: 0xA0b8…6eB48, symbol: "USDC", decimals: 6 }),
    balanceAdapter: 0x<AaveUmbrellaAdapter>,
    amount:        1_000_000_000,          // 1 000 USDC (principal via waToken exchange rate)
    isDebt:        false,
    protocolId:    keccak256("aave-v3-umbrella"),
    positionId:    abi.encode(0x<stkwaEthUSDC.v1>),
    positionKind:  PositionKind.Staking
})
```

#### `Cap` — cUSD + stcUSD (two legs)

Two structurally distinct legs, each valued in USDC: the base synthetic dollar (cUSD) and the staked,
yield-bearing savings token (stcUSD). The leg is identified by the token in `positionId`.

```solidity
// Leg 1 — held cUSD (label ["Stablecoin", "cUSD"])
PositionBalance({
    balanceAsset:  Asset({ asset: 0xA0b8…6eB48, symbol: "USDC", decimals: 6 }),
    balanceAdapter: 0x<CapAdapter>,
    amount:        2_000_000_000,          // 2 000 USDC
    isDebt:        false,
    protocolId:    keccak256("cap"),
    positionId:    abi.encode(0x<cUSD>),   // Cap cUSD token address
    positionKind:  PositionKind.Supplied
})
// Leg 2 — staked stcUSD (label ["Savings", "stcUSD"])
PositionBalance({
    balanceAsset:  Asset({ asset: 0xA0b8…6eB48, symbol: "USDC", decimals: 6 }),
    balanceAdapter: 0x<CapAdapter>,
    amount:        1_000_000_000,          // 1 000 USDC (stcUSD → cUSD → USDC)
    isDebt:        false,
    protocolId:    keccak256("cap"),
    positionId:    abi.encode(0x<stcUSD>), // Cap stcUSD token address
    positionKind:  PositionKind.Staking   // stcUSD is staked cUSD
})
```

#### `ERC4626Wrap` — ERC4626 wrapper

```solidity
// Generic adapter for any ERC4626 share token (e.g. stata-tokens).
PositionBalance({
    balanceAsset:  Asset({ asset: 0x40D1…2f, symbol: "GHO", decimals: 18 }),
    balanceAdapter: 0x<ERC4626WrapAdapter>,
    amount:        1_000e18,               // 1 000 GHO (convertToAssets of share balance)
    isDebt:        false,
    protocolId:    keccak256("erc4626"),
    positionId:    abi.encode(0x<wrapper>),  // ERC-4626 wrapper address
    positionKind:  PositionKind.Supplied
})
```

#### `KelpWithdrawalQueue` — rsETH exit queue

```solidity
// Sums all open requests per asset; positionId = abi.encode(WithdrawalManager) — account-global
// anchor, shared across the per-asset legs (told apart by balanceAsset), not per-request.
PositionBalance({
    balanceAsset:  Asset({ asset: 0xae7a…2Ca0, symbol: "stETH", decimals: 18 }),
    balanceAdapter: 0x<KelpWithdrawalQueueAdapter>,
    amount:        2e18,                   // 2 stETH owed across open requests
    isDebt:        false,
    protocolId:    keccak256("kelp-withdrawal"),
    positionId:    abi.encode(0x<KelpWithdrawalManager>),  // Kelp LRTWithdrawalManager (account-global anchor)
    positionKind:  PositionKind.Supplied
})
```

#### `LidoWithdrawalQueue` — stETH → ETH queue

```solidity
// Sums amountOfStETH across all unclaimed request IDs; denominated in ETH (not stETH).
PositionBalance({
    balanceAsset:  Asset({ asset: 0xEeee…EeeE, symbol: "ETH", decimals: 18 }),
    balanceAdapter: 0x<LidoWithdrawalQueueAdapter>,
    amount:        1e18,                   // 1 ETH owed on finalization
    isDebt:        false,
    protocolId:    keccak256("lido-withdrawal"),
    positionId:    abi.encode(0x<LidoWithdrawalQueue>),  // Lido WithdrawalQueueERC721 (account-global anchor)
    positionKind:  PositionKind.Supplied
})
```

#### `MerklRewards` — unclaimed Merkl allocation

```solidity
// One leg per reward token; proof-cached balance (may lag until next proof update).
PositionBalance({
    balanceAsset:  Asset({ asset: 0xD533…cd52, symbol: "CRV", decimals: 18 }),
    balanceAdapter: 0x<MerklRewardsAdapter>,
    amount:        250e18,                 // 250 CRV unclaimed
    isDebt:        false,
    protocolId:    keccak256("merkl"),
    positionId:    abi.encode(0x3Ef3…D9Ae),  // Merkl Distributor (reward token is in balanceAsset)
    positionKind:  PositionKind.Rewards
})
```

#### `StaderWithdrawalQueue` — ETHx → ETH queue

```solidity
// Sums all open request ETH values; denominated in WETH.
PositionBalance({
    balanceAsset:  Asset({ asset: 0xC02a…6Cc2, symbol: "WETH", decimals: 18 }),
    balanceAdapter: 0x<StaderWithdrawalQueueAdapter>,
    amount:        5e17,                   // 0.5 WETH owed
    isDebt:        false,
    protocolId:    keccak256("stader-withdrawal"),
    positionId:    abi.encode(0x<StaderUserWithdrawalManager>),  // Stader UserWithdrawalManager (account-global anchor)
    positionKind:  PositionKind.Supplied
})
```

---

### Meta-adapters

#### `AaveV3InstancesMeta` — Aave V3 supply (any instance)

```solidity
// positionId = abi.encode(pool), one per instance. Reserves are distinguished by balanceAsset + positionKind.
// Other legs: Collateral, Borrowed.
PositionBalance({
    balanceAsset:  Asset({ asset: 0xA0b8…6eB48, symbol: "USDC", decimals: 6 }),
    balanceAdapter: 0x<AaveV3InstancesMeta>,
    amount:        1_500_000_000,          // 1 500 USDC aToken balance
    isDebt:        false,
    protocolId:    keccak256("aave-v3-lending"),
    positionId:    abi.encode(0x<AaveV3Pool>),   // the instance Pool (reserve is in balanceAsset)
    positionKind:  PositionKind.Supplied
})
```

#### `MorphoVaultsMeta` — MetaMorpho vault supply

```solidity
PositionBalance({
    balanceAsset:  Asset({ asset: 0xA0b8…6eB48, symbol: "USDC", decimals: 6 }),
    balanceAdapter: 0x<MorphoVaultsMeta>,
    amount:        5_000_000_000,          // 5 000 USDC (convertToAssets)
    isDebt:        false,
    protocolId:    keccak256("morpho-vaults"),
    positionId:    abi.encode(0x<SteakhouseUSDCVault>),
    positionKind:  PositionKind.Supplied
})
```

#### `MorphoMarketsMeta` — Morpho market

```solidity
// Per-market: positionId = raw bytes32 marketId. Other legs: Supplied (loan supply), Borrowed.
PositionBalance({
    balanceAsset:  Asset({ asset: 0x7f39…Ca0, symbol: "wstETH", decimals: 18 }),
    balanceAdapter: 0x<MorphoMarketsMeta>,
    amount:        2e18,                   // 2 wstETH collateral
    isDebt:        false,
    protocolId:    keccak256("morpho-markets"),
    positionId:    abi.encode(bytes32(0x…marketId)),   // keccak256(MarketParams)
    positionKind:  PositionKind.Collateral
})
```

#### `EulerVaultsMeta` — Euler V2 vault supply

```solidity
// EulerEarn aggregator or core eVault. Other legs: Collateral (EVC-enabled supply), Borrowed (core eVaults only).
PositionBalance({
    balanceAsset:  Asset({ asset: 0xA0b8…6eB48, symbol: "USDC", decimals: 6 }),
    balanceAdapter: 0x<EulerVaultsMeta>,
    amount:        4_000_000_000,          // 4 000 USDC (convertToAssets)
    isDebt:        false,
    protocolId:    keccak256("euler-vaults"),
    positionId:    abi.encode(0x<EulerVault>),
    positionKind:  PositionKind.Supplied
})
```

#### `GearboxMarketsMeta` — Gearbox V3 farming pool

```solidity
PositionBalance({
    balanceAsset:  Asset({ asset: 0xA0b8…6eB48, symbol: "USDC", decimals: 6 }),
    balanceAdapter: 0x<GearboxMarketsMeta>,
    amount:        1_000_000_000,
    isDebt:        false,
    protocolId:    keccak256("gearbox-v3"),
    positionId:    abi.encode(0x<GearboxFarmingPool>),  // ERC4626 pool address
    positionKind:  PositionKind.Supplied
})
```

#### `FluidFTokensMeta` — Fluid fToken supply

```solidity
PositionBalance({
    balanceAsset:  Asset({ asset: 0xA0b8…6eB48, symbol: "USDC", decimals: 6 }),
    balanceAdapter: 0x<FluidFTokensMeta>,
    amount:        1_000_000_000,
    isDebt:        false,
    protocolId:    keccak256("fluid-ftokens"),
    positionId:    abi.encode(0x<FluidFUSDC>),
    positionKind:  PositionKind.Supplied
})
```

#### `FluidVaultsMeta` — Fluid T1 vault

```solidity
// Aggregates across all account NFT positions in this vault. Other legs: Borrowed.
PositionBalance({
    balanceAsset:  Asset({ asset: 0xC02a…6Cc2, symbol: "WETH", decimals: 18 }),
    balanceAdapter: 0x<FluidVaultsMeta>,
    amount:        1e18,                   // 1 WETH collateral (aggregated)
    isDebt:        false,
    protocolId:    keccak256("fluid-vaults"),
    positionId:    abi.encode(0x<FluidVault>),
    positionKind:  PositionKind.Collateral
})
```

#### `CompoundV3CometsMeta` — Compound V3 Comet

```solidity
// Other legs: Borrowed (base token debt), Collateral (per collateral asset), Rewards (COMP).
PositionBalance({
    balanceAsset:  Asset({ asset: 0xA0b8…6eB48, symbol: "USDC", decimals: 6 }),
    balanceAdapter: 0x<CompoundV3CometsMeta>,
    amount:        2_000_000_000,          // 2 000 USDC base supply
    isDebt:        false,
    protocolId:    keccak256("compound-v3"),
    positionId:    abi.encode(0x<cUSDCv3>),
    positionKind:  PositionKind.Supplied
})
```

#### `StakeWiseV3VaultsMeta` — StakeWise V3 vault

```solidity
// Staking = vault shares → ETH. Other leg: Borrowed (minted osETH debt).
PositionBalance({
    balanceAsset:  Asset({ asset: 0xEeee…EeeE, symbol: "ETH", decimals: 18 }),
    balanceAdapter: 0x<StakeWiseV3VaultsMeta>,
    amount:        2e18,                   // 2 ETH (convertToAssets(getShares))
    isDebt:        false,
    protocolId:    keccak256("stakewise-v3"),
    positionId:    abi.encode(0x<StakeWiseVault>),
    positionKind:  PositionKind.Staking
})
```

#### `BalancerV3PoolsMeta` — wallet-held Balancer V3 LP

```solidity
// One Supplied leg per pool token. Gauge-staked LP is a separate adapter.
PositionBalance({
    balanceAsset:  Asset({ asset: 0xA0b8…6eB48, symbol: "USDC", decimals: 6 }),
    balanceAdapter: 0x<BalancerV3PoolsMeta>,
    amount:        800_000_000,            // 800 USDC pro-rata from wallet BPT
    isDebt:        false,
    protocolId:    keccak256("balancer-v3-pool"),
    positionId:    abi.encode(0x<BalancerV3Pool>),
    positionKind:  PositionKind.Supplied
})
```

#### `BalancerV3GaugesMeta` — gauge-staked Balancer V3 LP

```solidity
// Other legs: Rewards (BAL + extra reward tokens).
PositionBalance({
    balanceAsset:  Asset({ asset: 0xA0b8…6eB48, symbol: "USDC", decimals: 6 }),
    balanceAdapter: 0x<BalancerV3GaugesMeta>,
    amount:        800_000_000,            // 800 USDC pro-rata from staked BPT
    isDebt:        false,
    protocolId:    keccak256("balancer-v3-gauge"),
    positionId:    abi.encode(0x<BalancerV3Gauge>),
    positionKind:  PositionKind.Staking
})
```

#### `BalancerV2PoolsMeta` — wallet-held Balancer V2 LP

```solidity
// positionId = raw bytes32 poolId (BPT address is poolId's top 20 bytes).
PositionBalance({
    balanceAsset:  Asset({ asset: 0xA0b8…6eB48, symbol: "USDC", decimals: 6 }),
    balanceAdapter: 0x<BalancerV2PoolsMeta>,
    amount:        800_000_000,
    isDebt:        false,
    protocolId:    keccak256("balancer-v2-pool"),
    positionId:    abi.encode(bytes32(0x<bptAddress>…<fee>)),  // raw V2 poolId
    positionKind:  PositionKind.Supplied
})
```

#### `BalancerV2GaugesMeta` — gauge-staked Balancer V2 LP

```solidity
// Other legs: Rewards (BAL + extra reward tokens).
PositionBalance({
    balanceAsset:  Asset({ asset: 0xA0b8…6eB48, symbol: "USDC", decimals: 6 }),
    balanceAdapter: 0x<BalancerV2GaugesMeta>,
    amount:        800_000_000,
    isDebt:        false,
    protocolId:    keccak256("balancer-v2-gauge"),
    positionId:    abi.encode(0x<BalancerV2Gauge>),
    positionKind:  PositionKind.Staking
})
```

#### `CurvePoolsMeta` — wallet-held Curve LP

```solidity
// One Supplied leg per registered pool coin, pro-rata from wallet LP balance.
PositionBalance({
    balanceAsset:  Asset({ asset: 0x<crvUSD>, symbol: "crvUSD", decimals: 18 }),
    balanceAdapter: 0x<CurvePoolsMeta>,
    amount:        1_000e18,               // 1 000 crvUSD pro-rata
    isDebt:        false,
    protocolId:    keccak256("curve-pool"),
    positionId:    abi.encode(0x<CurvePool>),
    positionKind:  PositionKind.Supplied
})
```

#### `CurveGaugesMeta` — staked Curve gauge

```solidity
// Other legs: Rewards (CRV lower-bound + extra reward tokens).
PositionBalance({
    balanceAsset:  Asset({ asset: 0x<crvUSD>, symbol: "crvUSD", decimals: 18 }),
    balanceAdapter: 0x<CurveGaugesMeta>,
    amount:        1_000e18,
    isDebt:        false,
    protocolId:    keccak256("curve-gauge"),
    positionId:    abi.encode(0x<CurveGauge>),
    positionKind:  PositionKind.Staking
})
```

#### `ConvexRewardsMeta` — Convex staked Curve LP

```solidity
// Staked LP decomposed into pool coins. Other legs: Rewards (CRV, CVX, extras).
PositionBalance({
    balanceAsset:  Asset({ asset: 0x<crvUSD>, symbol: "crvUSD", decimals: 18 }),
    balanceAdapter: 0x<ConvexRewardsMeta>,
    amount:        1_000e18,
    isDebt:        false,
    protocolId:    keccak256("convex"),
    positionId:    abi.encode(0x<ConvexBaseRewardPool>),
    positionKind:  PositionKind.Staking
})
```

#### `UniswapV3PoolsMeta` — Uniswap V3 NFT position

```solidity
// Per-NFT positionId. Two Supplied legs (token0, token1 in-range liquidity) +
// two Fees legs (token0, token1 uncollected fees) — all share this positionId.
PositionBalance({
    balanceAsset:  Asset({ asset: 0xA0b8…6eB48, symbol: "USDC", decimals: 6 }),
    balanceAdapter: 0x<UniswapV3PoolsMeta>,
    amount:        600_000_000,            // 600 USDC in-range liquidity (NFT #12345)
    isDebt:        false,
    protocolId:    keccak256("uniswap-v3"),
    positionId:    abi.encode(0x<NPM>, uint256(12345)),   // (npm, tokenId)
    positionKind:  PositionKind.Supplied
})
```

#### `UniswapV2PoolsMeta` — Uniswap V2 pair

```solidity
// Two Supplied legs per pair (token0 + token1 pro-rata from wallet LP).
PositionBalance({
    balanceAsset:  Asset({ asset: 0xA0b8…6eB48, symbol: "USDC", decimals: 6 }),
    balanceAdapter: 0x<UniswapV2PoolsMeta>,
    amount:        700_000_000,            // 700 USDC from USDC/WETH pair
    isDebt:        false,
    protocolId:    keccak256("uniswap-v2"),
    positionId:    abi.encode(0x<USDCWETHPair>),
    positionKind:  PositionKind.Supplied
})
```

#### `PancakeSwapV3PoolsMeta` / `PancakeSwapV2PoolsMeta`

Thin subclasses of UniswapV3/V2 adapters with different `npm`/`pair` addresses and the
`pancakeswap-v3` / `pancakeswap-v2` protocol slugs. All field schemas are identical.

---

## `getAccountPositionsVerbose` — full return values by adapter

`navCalculator.getAccountPositionsVerbose(account, address(0))` (USD quote) returns `VerbosePosition[]`.
Each entry wraps a `Position` (all `PositionBalance` fields + `value`, `price`, `priceDecimals`,
`stale`, `quoteAsset`) with `protocolName` and `labels` (`string[]`, sourced from each adapter's `positionLabels(bytes)` method).

The tables below show what the call returns for a representative account position in each protocol.
**`value (USD)`** is the signed contribution to NAV (negative = debt). Labels (`protocolName`,
`labels`) come from `IPositionDescribable` — meta-adapters derive them on-chain from live
state; per-instance adapters return static strings.

Assumed prices: USDC/DAI/GHO/USDS/crvUSD = $1 · WETH/ETH = $2 500 · wstETH = $2 900 ·
stETH = $2 480 · AAVE = $200 · CRV = $0.50 · CVX = $3 · BAL = $3 · COMP = $50

---

### Per-instance adapters

#### `ERC20DefaultBalanceAdapter` — wallet

Scenario: account holds USDC, WETH, and DAI.

| asset | amount | value (USD) | positionKind | protocolName | labels |
|-------|--------|-------------|--------------|--------------|---------------|
| USDC  | 1 500  | +1 500      | `Wallet`     | `"Wallet"`   | `["USDC"]`      |
| WETH  | 1.0    | +2 500      | `Wallet`     | `"Wallet"`   | `["WETH"]`      |
| DAI   | 3 000  | +3 000      | `Wallet`     | `"Wallet"`   | `["DAI"]`       |
| **NAV** | | **+7 000** | | | |

#### `SparkLend` — lending

Scenario: 1 500 USDC supplied (no collateral flag), 1 WETH as collateral, 500 USDC borrowed.

| asset | amount | value (USD) | positionKind  | protocolName | labels       |
|-------|--------|-------------|---------------|--------------|---------------------|
| USDC  | 1 500  | +1 500      | `Supplied`    | `"Spark"`    | `["Market", "SparkLend"]` |
| WETH  | 1.0    | +2 500      | `Collateral`  | `"Spark"`    | `["Market", "SparkLend"]` |
| USDC  | 500    | −500        | `Borrowed`    | `"Spark"`    | `["Market", "SparkLend"]` |
| **NAV** | | **+3 500** | | | |

#### `AaveV3SafetyModule` — staked tokens

Scenario: 500 AAVE in stkAAVE with 10 AAVE rewards accrued.

| asset | amount | value (USD) | positionKind | protocolName                | labels       |
|-------|--------|-------------|--------------|------------------------------|---------------------|
| AAVE  | 500    | +100 000    | `Staking`    | `"Aave V3"`                  | `["Safety Module"]`   |
| AAVE  | 10     | +2 000      | `Rewards`    | `"Aave V3"`                  | `["Safety Module"]`   |
| **NAV** | | **+102 000** | | | |

#### `AaveUmbrella` — Umbrella stake

Scenario: 1 000 USDC staked in stkwaEthUSDC.v1 with 5 USDC rewards pending.

| asset | amount | value (USD) | positionKind | protocolName      | labels        |
|-------|--------|-------------|--------------|-------------------|-----------------------|
| USDC  | 1 000  | +1 000      | `Staking`    | `"Aave Umbrella"` | `["Umbrella Module"]` |
| USDC  | 5      | +5          | `Rewards`    | `"Aave Umbrella"` | `["Umbrella Module"]` |
| **NAV** | | **+1 005** | | | |

#### `Cap` — cUSD + stcUSD

Scenario: 2 000 cUSD held + 1 000 USDC-worth of staked stcUSD.

| asset | amount | value (USD) | positionKind | protocolName | labels             |
|-------|--------|-------------|--------------|--------------|----------------------------|
| USDC  | 2 000  | +2 000      | `Supplied`   | `"Cap"`      | `["Stablecoin", "cUSD"]`   |
| USDC  | 1 000  | +1 000      | `Staking`    | `"Cap"`      | `["Savings", "stcUSD"]`    |

#### `ERC4626Wrap` — wrapper

Scenario: an ERC-4626 wrapper holding 1 000 GHO equivalent.

| asset | amount | value (USD) | positionKind | protocolName | labels |
|-------|--------|-------------|--------------|--------------|---------------|
| GHO   | 1 000  | +1 000      | `Supplied`   | `"ERC4626"`  | `["Vault"]` |

#### `KelpWithdrawalQueue` — pending unstake

Scenario: 2 stETH pending claim in Kelp queue.

| asset  | amount | value (USD) | positionKind | protocolName | labels |
|--------|--------|-------------|--------------|--------------|---------------|
| stETH  | 2.0    | +4 960      | `Supplied`   | `"Kelp DAO"` | `["rsETH Withdrawal Queue"]` |

#### `LidoWithdrawalQueue` — pending unstake

Scenario: 1 ETH finalized and waiting to be claimed.

| asset | amount | value (USD) | positionKind | protocolName | labels |
|-------|--------|-------------|--------------|--------------|---------------|
| ETH   | 1.0    | +2 500      | `Supplied`   | `"Lido"`     | `["stETH Withdrawal Queue"]` |

#### `MerklRewards` — unclaimed rewards

Scenario: 250 CRV unclaimed in Merkl distributor.

| asset | amount | value (USD) | positionKind | protocolName | labels |
|-------|--------|-------------|--------------|--------------|---------------|
| CRV   | 250    | +125        | `Rewards`    | `"Merkl"`    | `["Claimable Rewards"]` |

#### `StaderWithdrawalQueue` — pending unstake

Scenario: 0.5 WETH pending from ETHx unstake.

| asset | amount | value (USD) | positionKind | protocolName | labels |
|-------|--------|-------------|--------------|--------------|---------------|
| WETH  | 0.5    | +1 250      | `Supplied`   | `"Stader"`   | `["ETHx Withdrawal Queue"]` |

---

### Meta-adapters

#### `AaveV3InstancesMeta`

Scenario: 1 500 USDC supplied (not collateral), 1 WETH as collateral, 500 USDC borrowed — all on Aave V3 Core.

| asset | amount | value (USD) | positionKind | protocolName | labels     |
|-------|--------|-------------|--------------|--------------|-------------------|
| USDC  | 1 500  | +1 500      | `Supplied`   | `"Aave V3"`  | `["Market Instance", "Aave V3 Ethereum"]` |
| WETH  | 1.0    | +2 500      | `Collateral` | `"Aave V3"`  | `["Market Instance", "Aave V3 Ethereum"]` |
| USDC  | 500    | −500        | `Borrowed`   | `"Aave V3"`  | `["Market Instance", "Aave V3 Ethereum"]` |
| **NAV** | | **+3 500** | | | |

#### `MorphoVaultsMeta`

Scenario: 5 000 USDC supplied in Steakhouse USDC MetaMorpho vault.

| asset | amount | value (USD) | positionKind | protocolName | labels        |
|-------|--------|-------------|--------------|--------------|----------------------|
| USDC  | 5 000  | +5 000      | `Supplied`   | `"Morpho"`   | `["Vault", "Steakhouse USDC"]`  |

#### `MorphoMarketsMeta`

Scenario: 2 wstETH as collateral, 1 000 USDC borrowed — in a wstETH/USDC market.

| asset   | amount | value (USD) | positionKind | protocolName | labels           |
|---------|--------|-------------|--------------|--------------|-------------------------|
| wstETH  | 2.0    | +5 800      | `Collateral` | `"Morpho"`   | `["Market", "wstETH/USDC market"]`  |
| USDC    | 1 000  | −1 000      | `Borrowed`   | `"Morpho"`   | `["Market", "wstETH/USDC market"]`  |
| **NAV** | | **+4 800** | | | |

#### `EulerVaultsMeta`

Scenario: 4 000 USDC supplied in an Euler V2 vault (not enabled as EVC collateral).

| asset | amount | value (USD) | positionKind | protocolName | labels        |
|-------|--------|-------------|--------------|--------------|----------------------|
| USDC  | 4 000  | +4 000      | `Supplied`   | `"Euler"`    | `["Vault", "Euler USDC vault"]` |

#### `GearboxMarketsMeta`

Scenario: 1 000 USDC in Gearbox USDC farming pool.

| asset | amount | value (USD) | positionKind | protocolName  | labels          |
|-------|--------|-------------|--------------|---------------|------------------------|
| USDC  | 1 000  | +1 000      | `Supplied`   | `"Gearbox"`   | `["Market", "Gearbox USDC Farm"]`  |

#### `FluidFTokensMeta`

Scenario: 1 000 USDC in Fluid fUSDC.

| asset | amount | value (USD) | positionKind | protocolName | labels  |
|-------|--------|-------------|--------------|--------------|----------------|
| USDC  | 1 000  | +1 000      | `Supplied`   | `"Fluid"`    | `["Lending", "fUSDC supply"]` |

#### `FluidVaultsMeta`

Scenario: 1 WETH collateral, 500 USDC debt in a Fluid T1 vault.

| asset | amount | value (USD) | positionKind | protocolName | labels     |
|-------|--------|-------------|--------------|--------------|-------------------|
| WETH  | 1.0    | +2 500      | `Collateral` | `"Fluid"`    | `["Vault", "ETH-USDC vault"]` |
| USDC  | 500    | −500        | `Borrowed`   | `"Fluid"`    | `["Vault", "ETH-USDC vault"]` |
| **NAV** | | **+2 000** | | | |

#### `CompoundV3CometsMeta`

Scenario: 2 000 USDC supplied (base asset), 0.5 WETH as collateral, 10 COMP rewards — in cUSDCv3.

| asset | amount | value (USD) | positionKind | protocolName     | labels          |
|-------|--------|-------------|--------------|------------------|------------------------|
| USDC  | 2 000  | +2 000      | `Supplied`   | `"Compound V3"`  | `["Market", "Compound USDC"]`      |
| WETH  | 0.5    | +1 250      | `Collateral` | `"Compound V3"`  | `["Market", "Compound USDC"]`      |
| COMP  | 10     | +500        | `Rewards`    | `"Compound V3"`  | `["Market", "Compound USDC"]`      |
| **NAV** | | **+3 750** | | | |

#### `StakeWiseV3VaultsMeta`

Scenario: 2 ETH staked, 0.5 ETH equivalent minted as osETH (debt).

| asset | amount | value (USD) | positionKind | protocolName      | labels        |
|-------|--------|-------------|--------------|-------------------|----------------------|
| ETH   | 2.0    | +5 000      | `Staking`    | `"StakeWise V3"`  | `["Vaults", "Chorus One vault"]` |
| ETH   | 0.5    | −1 250      | `Borrowed`   | `"StakeWise V3"`  | `["Vaults", "Chorus One vault"]` |
| **NAV** | | **+3 750** | | | |

#### `BalancerV3PoolsMeta`

Scenario: wallet holds BPT representing 800 USDC + 0.32 WETH in a Balancer V3 USDC/WETH pool.

| asset | amount | value (USD) | positionKind | protocolName    | labels        |
|-------|--------|-------------|--------------|-----------------|----------------------|
| USDC  | 800    | +800        | `Supplied`   | `"Balancer V3"` | `["Liquidity Pool", "USDC/WETH 50/50"]`  |
| WETH  | 0.32   | +800        | `Supplied`   | `"Balancer V3"` | `["Liquidity Pool", "USDC/WETH 50/50"]`  |
| **NAV** | | **+1 600** | | | |

#### `BalancerV3GaugesMeta`

Scenario: staked BPT in gauge for a USDC/WETH pool, with 50 BAL rewards accrued.

| asset | amount | value (USD) | positionKind | protocolName    | labels           |
|-------|--------|-------------|--------------|-----------------|-------------------------|
| USDC  | 800    | +800        | `Staking`    | `"Balancer V3"` | `["Staking Gauge", "USDC/WETH gauge"]`     |
| WETH  | 0.32   | +800        | `Staking`    | `"Balancer V3"` | `["Staking Gauge", "USDC/WETH gauge"]`     |
| BAL   | 50     | +150        | `Rewards`    | `"Balancer V3"` | `["Staking Gauge", "USDC/WETH gauge"]`     |
| **NAV** | | **+1 750** | | | |

#### `BalancerV2PoolsMeta`

Scenario: wallet holds V2 BPT representing 800 USDC + 0.32 WETH.

| asset | amount | value (USD) | positionKind | protocolName    | labels       |
|-------|--------|-------------|--------------|-----------------|---------------------|
| USDC  | 800    | +800        | `Supplied`   | `"Balancer V2"` | `["Liquidity Pool", "Balancer USDC/WETH"]` |
| WETH  | 0.32   | +800        | `Supplied`   | `"Balancer V2"` | `["Liquidity Pool", "Balancer USDC/WETH"]` |
| **NAV** | | **+1 600** | | | |

#### `BalancerV2GaugesMeta`

Scenario: staked V2 BPT with 50 BAL rewards.

| asset | amount | value (USD) | positionKind | protocolName    | labels           |
|-------|--------|-------------|--------------|-----------------|-------------------------|
| USDC  | 800    | +800        | `Staking`    | `"Balancer V2"` | `["Staking Gauge", "50USDC-50WETH gauge"]` |
| WETH  | 0.32   | +800        | `Staking`    | `"Balancer V2"` | `["Staking Gauge", "50USDC-50WETH gauge"]` |
| BAL   | 50     | +150        | `Rewards`    | `"Balancer V2"` | `["Staking Gauge", "50USDC-50WETH gauge"]` |
| **NAV** | | **+1 750** | | | |

#### `CurvePoolsMeta`

Scenario: wallet holds LP representing 1 000 crvUSD + 1 000 USDC in a crvUSD/USDC pool.

| asset  | amount | value (USD) | positionKind | protocolName | labels       |
|--------|--------|-------------|--------------|--------------|---------------------|
| crvUSD | 1 000  | +1 000      | `Supplied`   | `"Curve"`    | `["Liquidity Pool", "crvUSD/USDC LP"]`  |
| USDC   | 1 000  | +1 000      | `Supplied`   | `"Curve"`    | `["Liquidity Pool", "crvUSD/USDC LP"]`  |
| **NAV** | | **+2 000** | | | |

#### `CurveGaugesMeta`

Scenario: staked gauge LP (same pool as above) with 100 CRV rewards.

| asset  | amount | value (USD) | positionKind | protocolName | labels          |
|--------|--------|-------------|--------------|--------------|------------------------|
| crvUSD | 1 000  | +1 000      | `Staking`    | `"Curve"`    | `["Staking Gauge", "crvUSD/USDC gauge"]`  |
| USDC   | 1 000  | +1 000      | `Staking`    | `"Curve"`    | `["Staking Gauge", "crvUSD/USDC gauge"]`  |
| CRV    | 100    | +50         | `Rewards`    | `"Curve"`    | `["Staking Gauge", "crvUSD/USDC gauge"]`  |
| **NAV** | | **+2 050** | | | |

#### `ConvexRewardsMeta`

Scenario: Convex-staked crvUSD/USDC LP with 100 CRV + 50 CVX rewards.

| asset  | amount | value (USD) | positionKind | protocolName | labels              |
|--------|--------|-------------|--------------|--------------|----------------------------|
| crvUSD | 1 000  | +1 000      | `Staking`    | `"Convex"`   | `["Curve LP", "crvUSD/USDC Convex"]`     |
| USDC   | 1 000  | +1 000      | `Staking`    | `"Convex"`   | `["Curve LP", "crvUSD/USDC Convex"]`     |
| CRV    | 100    | +50         | `Rewards`    | `"Convex"`   | `["Curve LP", "crvUSD/USDC Convex"]`     |
| CVX    | 50     | +150        | `Rewards`    | `"Convex"`   | `["Curve LP", "crvUSD/USDC Convex"]`     |
| **NAV** | | **+2 200** | | | |

#### `UniswapV3PoolsMeta`

Scenario: one NFT position (#12345) in the USDC/WETH 0.05% pool, in-range, with 20 USDC + 0.008 WETH in accrued fees.

| asset | amount  | value (USD) | positionKind | protocolName   | labels  |
|-------|---------|-------------|--------------|----------------|----------------|
| USDC  | 600     | +600        | `Supplied`   | `"Uniswap V3"` | `["Liquidity Pool", "NFT #12345"]` |
| WETH  | 0.24    | +600        | `Supplied`   | `"Uniswap V3"` | `["Liquidity Pool", "NFT #12345"]` |
| USDC  | 20      | +20         | `Fees`       | `"Uniswap V3"` | `["Liquidity Pool", "NFT #12345"]` |
| WETH  | 0.008   | +20         | `Fees`       | `"Uniswap V3"` | `["Liquidity Pool", "NFT #12345"]` |
| **NAV** | | **+1 240** | | | |

#### `UniswapV2PoolsMeta`

Scenario: wallet holds USDC/WETH V2 pair LP representing 700 USDC + 0.28 WETH.

| asset | amount | value (USD) | positionKind | protocolName   | labels     |
|-------|--------|-------------|--------------|----------------|-------------------|
| USDC  | 700    | +700        | `Supplied`   | `"Uniswap V2"` | `["Liquidity Pool", "USDC/WETH LP"]`  |
| WETH  | 0.28   | +700        | `Supplied`   | `"Uniswap V2"` | `["Liquidity Pool", "USDC/WETH LP"]`  |
| **NAV** | | **+1 400** | | | |

#### `PancakeSwapV3PoolsMeta` / `PancakeSwapV2PoolsMeta`

Same structure as UniswapV3/V2 respectively; `protocolName` = `"PancakeSwap V3"` / `"PancakeSwap V2"`.

---

## `protocolId` — which protocol

`protocolId` is `keccak256` of a canonical ASCII slug. A single slug maps to exactly one
`positionId` ABI-decode schema, so you can switch on `protocolId` and know exactly how to
decode `positionId` without any runtime sniffing.

All constants live in [`src/utils/ProtocolIds.sol`](../../src/utils/ProtocolIds.sol).

```solidity
bytes32 protocolId = keccak256("aave-v3-lending");  // == ProtocolIds.AAVE_V3_LENDING
```

### Every `protocolId` — slug, constant, and what it identifies

The complete set. The slug is the exact lowercase string fed to `keccak256`; the constant is its name
in `ProtocolIds.sol`; "Emitted by" is the adapter that produces positions under that id. (`positionId`
schemas are in the next section and in the per-adapter table above.)

| Slug | `ProtocolIds` constant | Emitted by — what it identifies |
|---|---|---|
| `wallet` | `WALLET` | `ERC20DefaultBalanceAdapter` — a plain ERC20/native balance held in the account |
| `aave-v3-lending` | `AAVE_V3_LENDING` | `AaveV3InstancesMetaBalanceAdapter` — supply/collateral/borrow on an Aave V3 market instance |
| `spark-lend` | `SPARK_LEND` | `SparkLendBalanceAdapter` — supply/collateral/borrow on SparkLend |
| `aave-v3-safety-module` | `AAVE_V3_SAFETY_MODULE` | `AaveV3SafetyModuleBalanceAdapter` — staked Safety Module principal + rewards |
| `aave-v3-umbrella` | `AAVE_V3_UMBRELLA` | `AaveUmbrellaBalanceAdapter` — Umbrella stake-token principal + rewards |
| `morpho-vaults` | `MORPHO_VAULTS` | `MorphoVaultsMetaBalanceAdapter` — MetaMorpho (ERC4626) vault supply |
| `morpho-markets` | `MORPHO_MARKETS` | `MorphoMarketsMetaBalanceAdapter` — Morpho isolated-market collateral/supply/borrow |
| `euler-vaults` | `EULER_VAULTS` | `EulerVaultsMetaBalanceAdapter` — Euler V2 vault supply/collateral/borrow |
| `gearbox-v3` | `GEARBOX_V3` | `GearboxMarketsMetaBalanceAdapter` — Gearbox V3 passive-pool deposit |
| `compound-v3` | `COMPOUND_V3` | `CompoundV3CometsMetaBalanceAdapter` — Compound V3 Comet base/collateral/rewards |
| `fluid-ftokens` | `FLUID_FTOKENS` | `FluidFTokensMetaBalanceAdapter` — Fluid fToken (ERC4626) lending supply |
| `fluid-vaults` | `FLUID_VAULTS` | `FluidVaultsMetaBalanceAdapter` — Fluid T1 vault collateral/borrow |
| `balancer-v3-pool` | `BALANCER_V3_POOL` | `BalancerV3PoolsMetaBalanceAdapter` — wallet-held Balancer V3 LP |
| `balancer-v3-gauge` | `BALANCER_V3_GAUGE` | `BalancerV3GaugesMetaBalanceAdapter` — gauge-staked Balancer V3 LP + rewards |
| `balancer-v2-pool` | `BALANCER_V2_POOL` | `BalancerV2PoolsMetaBalanceAdapter` — wallet-held Balancer V2 LP |
| `balancer-v2-gauge` | `BALANCER_V2_GAUGE` | `BalancerV2GaugesMetaBalanceAdapter` — gauge-staked Balancer V2 LP + rewards |
| `curve-pool` | `CURVE_POOL` | `CurvePoolsMetaBalanceAdapter` — wallet-held Curve LP |
| `curve-gauge` | `CURVE_GAUGE` | `CurveGaugesMetaBalanceAdapter` — gauge-staked Curve LP + rewards |
| `curve` | `CURVE` | Legacy per-instance Curve adapter — superseded on mainnet by `curve-pool` / `curve-gauge` |
| `convex` | `CONVEX` | `ConvexRewardsMetaBalanceAdapter` — Convex-staked Curve LP + CRV/CVX/extra rewards |
| `uniswap-v3` | `UNISWAP_V3` | `UniswapV3PoolsMetaBalanceAdapter` — Uniswap V3 LP NFT liquidity + fees |
| `uniswap-v2` | `UNISWAP_V2` | `UniswapV2PoolsMetaBalanceAdapter` — Uniswap V2 LP |
| `pancakeswap-v3` | `PANCAKESWAP_V3` | `PancakeSwapV3PoolsMetaBalanceAdapter` — PancakeSwap V3 LP NFT liquidity + fees |
| `pancakeswap-v2` | `PANCAKESWAP_V2` | `PancakeSwapV2PoolsMetaBalanceAdapter` — PancakeSwap V2 LP |
| `stakewise-v3` | `STAKEWISE_V3` | `StakeWiseV3VaultsMetaBalanceAdapter` — StakeWise V3 vault stake + osToken debt |
| `nexus-mutual-staking` | `NEXUS_MUTUAL_STAKING` | `NexusMutualStakingPoolsBalanceAdapter` — Nexus Mutual StakingNFT stake + rewards |
| `cap` | `CAP` | `CapBalanceAdapter` — Cap cUSD (held) and stcUSD (staked) |
| `erc4626` | `ERC4626` | `ERC4626WrapBalanceAdapter` — generic ERC4626 wrapper share |
| `merkl` | `MERKL` | `MerklRewardsBalanceAdapter` — unclaimed (claimable) Merkl reward tokens |
| `lido-withdrawal` | `LIDO_WITHDRAWAL` | `LidoWithdrawalQueueBalanceAdapter` — ETH owed from the Lido stETH withdrawal queue |
| `stader-withdrawal` | `STADER_WITHDRAWAL` | `StaderWithdrawalQueueBalanceAdapter` — ETH owed from the Stader ETHx withdrawal queue |
| `kelp-withdrawal` | `KELP_WITHDRAWAL` | `KelpWithdrawalQueueBalanceAdapter` — assets owed from the Kelp rsETH exit queue |
| `etherfi-withdrawal` | `ETHERFI_WITHDRAWAL` | `EtherFiWithdrawalQueueBalanceAdapter` — ETH owed from the ether.fi eETH withdrawal queue |
| `stakewise-exit` | `STAKEWISE_EXIT` | `StakeWiseV3ExitQueueBalanceAdapter` — assets owed from the StakeWise V3 exit queue |
| `ethena-cooldown` | `ETHENA_COOLDOWN` | `EthenaCooldownBalanceAdapter` — USDe in the sUSDe unstaking cooldown |
| `bridge-escrow` | `BRIDGE_ESCROW` | `BridgeEscrow` (bridge layer, **not** a balance adapter) — funds in flight across a bridge |

Every slug maps to exactly one `positionId` schema — see the next section. Slugs are stable and
version-qualified (`-v2` / `-v3`); a protocol upgrade that changes the position shape gets a new slug
rather than overloading an existing one.

---

## `positionId` — which instance

`positionId` is `abi.encode(...)` of the position's stable key. The exact schema depends on
`protocolId` — one slug, one schema. Full table:

| `protocolId` slug | `positionId` = `abi.encode(...)` |
|---|---|
| `wallet` | `(address asset)` |
| `aave-v3-lending` | `(address pool)` |
| `spark-lend` | `(address pool)` |
| `aave-v3-safety-module` | `(address stakeToken)` |
| `aave-v3-umbrella` | `(address stakeToken)` |
| `morpho-vaults` | `(address vault)` |
| `morpho-markets` | `(bytes32 marketId)` |
| `euler-vaults` | `(address vault)` |
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
| `uniswap-v3` | `(address npm, uint256 tokenId)` |
| `uniswap-v2` | `(address pair)` |
| `pancakeswap-v3` | `(address npm, uint256 tokenId)` |
| `pancakeswap-v2` | `(address pair)` |
| `stakewise-v3` | `(address vault)` |
| `cap` | `(address token)` — cUSD or stcUSD |
| `erc4626` | `(address vault)` |
| `merkl` | `(address distributor)` — reward token in balanceAsset |
| `nexus-mutual-staking` | `(uint256 tokenId, uint256 poolId)` |
| `stader-withdrawal` | `(address userWithdrawalManager)` — account-global anchor |
| `kelp-withdrawal` | `(address withdrawalManager)` — account-global anchor |
| `lido-withdrawal` | `(address withdrawalQueue)` — account-global anchor |
| `etherfi-withdrawal` | `(address withdrawRequestNFT)` — account-global anchor |
| `stakewise-exit` | `(address vaultsRegistry)` — account-global anchor |
| `ethena-cooldown` | `(address sUSDe)` — account-global anchor |
| `bridge-escrow` | `(address escrow, address token)` |

**Account-global positionId** means there is only ever one such position per account for that
protocol (e.g. the Lido withdrawal queue), so the positionId encodes the queue/manager's immutable
anchor address rather than a per-request id. Note: `wallet` positions are NOT account-global — each
uses `abi.encode(asset)` to identify the specific token.

---

## `PositionKind` — what kind of position

```solidity
enum PositionKind {
    Wallet,     // plain ERC20 / native balance (ERC20DefaultBalanceAdapter)
    Supplied,   // lending supply, vault shares, unstaked LP principal
    Borrowed,   // any debt position (isDebt = true)
    Collateral, // supply locked as collateral (e.g. Aave usageAsCollateralEnabled = true)
    Staking,    // staking principal: tokens locked in a staking contract
    Rewards,    // accrued but not yet claimed reward tokens (CRV, CVX, BAL, COMP, …)
    Fees        // uncollected protocol or LP fees (e.g. Uniswap V3 position fees)
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
- `balanceAdapter` — provenance only; redeploying an adapter doesn't change the position
- `isDebt` — derivable from `positionKind == Borrowed`

---

## Adapter reference — positionId decode and legs

The table below and the TypeScript examples cover every adapter in the codebase. All
decodes use `AbiCoder.defaultAbiCoder()` from ethers.js. Protocol ID constants come from
`ProtocolIds.sol` (`keccak256(toUtf8Bytes("<slug>"))`).

### PositionKind summary per adapter

| Adapter | `protocolId` slug | Legs emitted (`PositionKind`) |
|---|---|---|
| `ERC20DefaultBalanceAdapter` | `wallet` | `Wallet` |
| `AaveV3InstancesMeta` | `aave-v3-lending` | `Supplied`, `Collateral`, `Borrowed` |
| `SparkLend` | `spark-lend` | `Supplied`, `Collateral`, `Borrowed` |
| `AaveV3SafetyModule` | `aave-v3-safety-module` | `Staking`, `Rewards` |
| `AaveUmbrella` | `aave-v3-umbrella` | `Staking`, `Rewards` |
| `MorphoVaultsMeta` | `morpho-vaults` | `Supplied` |
| `MorphoMarketsMeta` | `morpho-markets` | `Collateral`, `Supplied`, `Borrowed` |
| `EulerVaultsMeta` | `euler-vaults` | `Supplied`, `Collateral`, `Borrowed` |
| `GearboxMarketsMeta` | `gearbox-v3` | `Supplied` |
| `FluidFTokensMeta` | `fluid-ftokens` | `Supplied` |
| `FluidVaultsMeta` | `fluid-vaults` | `Collateral`, `Borrowed` |
| `CompoundV3CometsMeta` | `compound-v3` | `Supplied`, `Borrowed`, `Collateral`, `Rewards` |
| `StakeWiseV3VaultsMeta` | `stakewise-v3` | `Staking`, `Borrowed` |
| `BalancerV3PoolsMeta` | `balancer-v3-pool` | `Supplied` |
| `BalancerV3GaugesMeta` | `balancer-v3-gauge` | `Staking`, `Rewards` |
| `BalancerV2PoolsMeta` | `balancer-v2-pool` | `Supplied` |
| `BalancerV2GaugesMeta` | `balancer-v2-gauge` | `Staking`, `Rewards` |
| `CurvePoolsMeta` | `curve-pool` | `Supplied` |
| `CurveGaugesMeta` | `curve-gauge` | `Staking`, `Rewards` |
| `ConvexRewardsMeta` | `convex` | `Staking`, `Rewards` |
| `UniswapV3PoolsMeta` / `PancakeSwapV3PoolsMeta` | `uniswap-v3` / `pancakeswap-v3` | `Supplied`, `Fees` |
| `UniswapV2PoolsMeta` / `PancakeSwapV2PoolsMeta` | `uniswap-v2` / `pancakeswap-v2` | `Supplied` |
| `Cap` | `cap` | `Supplied` (cUSD), `Staking` (stcUSD) |
| `ERC4626Wrap` | `erc4626` | `Supplied` |
| `MerklRewards` | `merkl` | `Rewards` |
| `NexusMutualStakingPoolsBalanceAdapter` | `nexus-mutual-staking` | `Staking`, `Rewards` |
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
const [asset] = abi.decode(["address"], pos.positionId);
// asset — the ERC20 token address (same as balanceAsset.asset)
// positionKind = Wallet
```

#### Aave V3 / Spark — `aave-v3-lending` / `spark-lend`

Per-instance positionId: every leg of the instance (all reserves, all kinds) shares one
positionId = the pool. The reserve is the position's `balanceAsset.asset`; legs are
distinguished by `balanceAsset` + `positionKind`.

```typescript
const [pool] = abi.decode(["address"], pos.positionId);
const reserve = pos.balanceAsset.asset; // the reserve is the position's asset, NOT in positionId
// pool   — IPool (V3) / SparkPool
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
// Staking    → staked principal (denominated in the stake token's STAKED_TOKEN())
// Rewards    → claimable AAVE rewards
```

#### Aave Umbrella — `aave-v3-umbrella`

```typescript
const [stakeToken] = abi.decode(["address"], pos.positionId);
// stakeToken — UmbrellaStakeToken (e.g. stkwaEthUSDC.v1, stkGHO.v1)
// Staking    → principal, denominated in the bare reserve (USDC, WETH, GHO …)
// Rewards    → claimable rewards, same bare reserve denomination
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
// marketId — Morpho market ID (keccak of MarketParams)
// Collateral → collateral token supplied
// Supplied   → loan token supplied (lending side)
// Borrowed   → loan token borrowed
```

#### Euler Vaults — `euler-vaults`

Covers both EulerEarn aggregator vaults and core eVaults (EVK). All legs of one vault share
the same positionId.

```typescript
const [vault] = abi.decode(["address"], pos.positionId);
// vault — Euler V2 ERC4626 vault (EulerEarn or core eVault)
// Supplied   → convertToAssets(balanceOf(account)), not enabled as EVC collateral
// Collateral → same supply, enabled as EVC collateral
// Borrowed   → debtOf(account) on core eVaults (EulerEarn aggregators have no debt leg)
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
// Rewards     → COMP rewards (claimable)
```

#### StakeWise V3 — `stakewise-v3`

```typescript
const [vault] = abi.decode(["address"], pos.positionId);
// vault — StakeWise V3 ERC4626-like vault
// Staking  → vault shares → underlying (ETH / GNO)
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
// Staking  → one leg per pool token (gauge-staked BPT share)
// Rewards  → BAL + extra reward token legs
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
// Staking  → one leg per pool token (gauge-staked BPT share)
// Rewards  → BAL + extra reward token legs
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
// Staking  → one leg per pool coin (staked LP share, pro-rata)
// Rewards  → CRV (lower-bound) + extra reward token legs
```

#### Convex — `convex`

```typescript
const [rewarder] = abi.decode(["address"], pos.positionId);
// rewarder — Convex BaseRewardPool address
// Staking  → one leg per underlying Curve pool coin (staked LP, pro-rata)
// Rewards  → CRV, CVX, and extra reward token legs
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
// Fees     → unclaimed fee legs (token0 and token1)

// Collect fees:
if (pos.positionKind === PositionKind.Fees) {
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
const [token] = abi.decode(["address"], pos.positionId);
// token — the Cap token: cUSD (held synthetic dollar) or stcUSD (staked savings)
// Supplied → that leg's redeemable value in the underlying (USDC)
// labels: ["Stablecoin", "cUSD"] for cUSD; ["Savings", "stcUSD"] for stcUSD
```

#### ERC4626 wrapper — `erc4626`

```typescript
const [wrapper] = abi.decode(["address"], pos.positionId);
// wrapper — ERC4626 share token (e.g. an Aave stata-token or Nexus RWI Vault share)
// Supplied → convertToAssets(balanceOf(account)) in wrapper.asset()
```

#### Merkl rewards — `merkl`

```typescript
const [distributor] = abi.decode(["address"], pos.positionId);
// distributor — the Merkl Distributor (claim target); the reward token is in balanceAsset.asset
// Rewards → unclaimed allocation (proof-cached; may be stale between proof updates)
```

#### Nexus Mutual staking pools — `nexus-mutual-staking`

```typescript
const [tokenId, poolId] = abi.decode(["uint256", "uint256"], pos.positionId);
// tokenId — the Nexus StakingNFT id (one position); poolId — the staking pool it belongs to
// One Staking (active + expired stake) and one Rewards leg per tokenId, both NXM-denominated.
// An account may hold several positions across several pools; each surfaces under its own positionId.
```

#### Lido / Stader / Kelp withdrawal queues — `lido-withdrawal` / `stader-withdrawal` / `kelp-withdrawal`

```typescript
const [anchor] = abi.decode(["address"], pos.positionId);
// positionId = abi.encode(<anchor>) — account-global; one position per account per queue.
//   anchor = withdrawalQueue (Lido) / userWithdrawalManager (Stader) / withdrawalManager (Kelp)
// Supplied → summed ETH owed across all open (unclaimed) request IDs
// balanceAsset is the underlying paid on claim: native ETH sentinel for Lido,
//   WETH for Stader, and the LST asset (e.g. stETH) for Kelp — all set per-deploy via UNDERLYING_TOKEN
```

---

## Human-readable labels — `IPositionDescribable` and verbose reads

The typed fields are for machines. For human-readable display, two mechanisms exist:

### `IPositionDescribable` (on each adapter)

```solidity
interface IPositionDescribable {
    function protocolName() external view returns (string memory); // "Aave V3", "Morpho", …
    // Ordered hierarchy below the protocol, leaf last, e.g. ["Market", "wstETH/USDC"].
    function positionLabels(bytes calldata positionId) external view returns (string[] memory);
}
```

All adapters implement this. Meta-adapters derive the hierarchy on-chain from live state (ERC20
symbols, vault names, pool composition) and return `[category, …leaf]`. Per-instance adapters return
a fixed array.

### Verbose read methods — on `NAVCalculator`

`NAVCalculator` exposes verbose read methods that wrap the typed positions with human-readable labels:

```solidity
struct VerbosePosition {
    Position position;     // full enriched position (typed identity + pricing)
    string   protocolName; // e.g. "Curve", "Morpho"
    string[] labels;       // ordered hierarchy below protocol, leaf last, e.g. ["Staking Gauge", "USDC/crvUSD"]
}

navCalculator.getAccountPositionsVerbose(account, quoteAsset)
navCalculator.getAccountPositionsForAssetVerbose(account, asset, quoteAsset)
navCalculator.getAccountNavVerbose(account, quoteAsset)  // NAV + all verbose positions in one call
```

Labels come from each adapter's `IPositionDescribable` implementation; the full breadcrumb is
`[protocolName, ...labels]`. If an adapter doesn't implement it, `protocolName` is empty and
`labels` is an empty array. **Never use these strings for identity, indexing, or reconciliation**
— they are display-only and may change as labels evolve.

### Complete per-adapter schema

The single source of truth tying together everything above — `protocolId`, `protocolName()`, the
`positionLabels` breadcrumb, the `positionId` ABI schema, the `PositionKind` legs, and a worked
example — for every balance adapter on `main`.

- **Full breadcrumb** = `[protocolName(), ...positionLabels(positionId)]`; the **leaf** is the last element.
- **`protocolId`** column is the `keccak256` slug (constants in [`src/utils/ProtocolIds.sol`](../../src/utils/ProtocolIds.sol)).
- **Leaf source:** `const` = hardcoded literal · `derived` = read live from chain · `gov` = constructor arg.
  No leaf is governance-fed today; for meta-adapters only `protocolName()` (the breadcrumb root, marked ¹)
  is a constructor arg, the category is a `const` literal, and the leaf is `derived` on-chain. Meta-adapters
  use a `_labels(category, leaf)` helper that **drops an empty leaf**, so a failed read degrades to `[category]`.

#### Plain adapters (`src/balances/BalanceAdapters/`)

| Adapter | `protocolId` | `protocolName()` | `positionLabels` → (source) | `positionId` schema | `PositionKind` legs | Example breadcrumb |
|---|---|---|---|---|---|---|
| `ERC20DefaultBalanceAdapter` | `wallet` | `"Wallet"` | `[<symbol>]` (derived); `["native"]`; `[]` on revert | `abi.encode(address asset)` | Wallet | `["Wallet","USDC"]` |
| `AaveUmbrellaBalanceAdapter` | `aave-v3-umbrella` | `"Aave Umbrella"` | `["Umbrella Module"]` (const) | `abi.encode(address stakeToken)` | Staking / Rewards | `["Aave Umbrella","Umbrella Module"]` |
| `AaveV3SafetyModuleBalanceAdapter` | `aave-v3-safety-module` | `"Aave V3"` | `["Safety Module"]` (const) | `abi.encode(address stakeToken)` | Staking / Rewards | `["Aave V3","Safety Module"]` |
| `CapBalanceAdapter` (cUSD) | `cap` | `"Cap"` | `["Stablecoin","cUSD"]` (const) | `abi.encode(address CUSD)` | Supplied | `["Cap","Stablecoin","cUSD"]` |
| `CapBalanceAdapter` (stcUSD) | `cap` | `"Cap"` | `["Savings","stcUSD"]` (const) | `abi.encode(address STCUSD)` | Staking | `["Cap","Savings","stcUSD"]` |
| `ERC4626WrapBalanceAdapter` | `erc4626` | `"ERC4626"` | `["Vault"]` (const) | `abi.encode(address wrapper)` | Supplied | `["ERC4626","Vault"]` |
| `EthenaCooldownBalanceAdapter` | `ethena-cooldown` | `"Ethena"` | `["Unstaking Cooldown"]` (const) | `abi.encode(address sUSDe)` | Supplied | `["Ethena","Unstaking Cooldown"]` |
| `SparkLendBalanceAdapter` | `spark-lend` | `"Spark"` | `["Market","SparkLend"]` (const) | `abi.encode(address POOL)` | Collateral/Supplied / Borrowed | `["Spark","Market","SparkLend"]` |
| `LidoWithdrawalQueueBalanceAdapter` | `lido-withdrawal` | `"Lido"` | `["stETH Withdrawal Queue"]` (const) | `abi.encode(address withdrawalQueue)` | Supplied | `["Lido","stETH Withdrawal Queue"]` |
| `StaderWithdrawalQueueBalanceAdapter` | `stader-withdrawal` | `"Stader"` | `["ETHx Withdrawal Queue"]` (const) | `abi.encode(address userWithdrawalManager)` | Supplied | `["Stader","ETHx Withdrawal Queue"]` |
| `KelpWithdrawalQueueBalanceAdapter` | `kelp-withdrawal` | `"Kelp DAO"` | `["rsETH Withdrawal Queue"]` (const) | `abi.encode(address withdrawalManager)` | Supplied | `["Kelp DAO","rsETH Withdrawal Queue"]` |

#### Meta-adapters (`src/balances/MetaBalanceAdapters/`)

`protocolName()` is a constructor arg (¹). Default `positionId` = base `_instancePositionId` (instance
address widened → `abi.encode(address instance)`); overrides are flagged.

| Adapter | `protocolId` | `protocolName()`¹ | `positionLabels` → (source) | `positionId` schema | `PositionKind` legs | Example breadcrumb |
|---|---|---|---|---|---|---|
| `AaveV3InstancesMetaBalanceAdapter` | `aave-v3-lending` | `"Aave V3"` | `["Market Instance", <getMarketId()>]` (derived) | **override** `abi.encode(address pool)` | Collateral/Supplied / Borrowed | `["Aave V3","Market Instance","Aave Ethereum Market"]` |
| `CompoundV3CometsMetaBalanceAdapter` | `compound-v3` | `"Compound V3"` | `["Market", <comet.name()>]` (derived) | `abi.encode(address comet)` | Supplied/Borrowed / Collateral / Rewards | `["Compound V3","Market","cUSDCv3"]` |
| `ConvexRewardsMetaBalanceAdapter` | `convex` | `"Convex"` | `["Curve LP", "<coins> Convex"]` (derived) | `abi.encode(address rewarder)` | Staking / Rewards | `["Convex","Curve LP","DAI/USDC/USDT Convex"]` |
| `EulerVaultsMetaBalanceAdapter` | `euler-vaults` | `"Euler"` | `["Vault", <vault.name()>]` (derived) | `abi.encode(address vault)` | Collateral/Supplied / Borrowed | `["Euler","Vault","eUSDC"]` |
| `FluidFTokensMetaBalanceAdapter` | `fluid-ftokens` | `"Fluid"` | `["Lending", "<fToken.symbol()> supply"]` (derived) | `abi.encode(address fToken)` | Supplied | `["Fluid","Lending","fUSDC supply"]` |
| `FluidVaultsMetaBalanceAdapter` | `fluid-vaults` | `"Fluid"` | `["Vault", <vault.name()>]` (derived) | `abi.encode(address vault)` | Collateral / Borrowed | `["Fluid","Vault","Fluid T1 USDC"]` |
| `GearboxMarketsMetaBalanceAdapter` | `gearbox-v3` | `"Gearbox"` | `["Market", <market.name()>]` (derived) | `abi.encode(address market)` | Supplied | `["Gearbox","Market","dDAI"]` |
| `MorphoMarketsMetaBalanceAdapter` | `morpho-markets` | `"Morpho"` | `["Market", "<coll>/<loan> market"]` (derived) | **override** `abi.encode(bytes32 marketId)` (raw) | Collateral / Supplied / Borrowed | `["Morpho","Market","wETH/USDC market"]` |
| `MorphoVaultsMetaBalanceAdapter` | `morpho-vaults` | `"Morpho"` | `["Vault", <vault.name()>]` (derived) | `abi.encode(address vault)` | Supplied | `["Morpho","Vault","Morpho DAI"]` |
| `StakeWiseV3VaultsMetaBalanceAdapter` | `stakewise-v3` | `"StakeWise V3"` | `["Vaults", <vault.name()>]` (derived) | `abi.encode(address vault)` | Staking / Borrowed (osToken) | `["StakeWise V3","Vaults","StakeWise Vault ETH"]` |
| `BalancerV2PoolsMetaBalanceAdapter` | `balancer-v2-pool` | `"Balancer V2"` | `["Liquidity Pool", <BPT.name()>]` (derived) | **override** `abi.encode(bytes32 poolId)` (raw) | Supplied | `["Balancer V2","Liquidity Pool","50WETH-50USDC"]` |
| `BalancerV2GaugesMetaBalanceAdapter` | `balancer-v2-gauge` | `"Balancer V2"` | `["Staking Gauge", <gauge.symbol()>]` (derived) | `abi.encode(address gauge)` | Staking / Rewards | `["Balancer V2","Staking Gauge","…-gauge"]` |
| `BalancerV3PoolsMetaBalanceAdapter` | `balancer-v3-pool` | `"Balancer V3"` | `["Liquidity Pool", <pool.name()>]` (derived) | `abi.encode(address pool)` | Supplied | `["Balancer V3","Liquidity Pool","Balancer 50 WETH 50 USDC"]` |
| `BalancerV3GaugesMetaBalanceAdapter` | `balancer-v3-gauge` | `"Balancer V3"` | `["Staking Gauge", <gauge.symbol()>]` (derived) | `abi.encode(address gauge)` | Staking / Rewards | `["Balancer V3","Staking Gauge","…-gauge"]` |
| `CurvePoolsMetaBalanceAdapter` | `curve-pool` | `"Curve"` | `["Liquidity Pool", "<coins> LP"]` (derived) | `abi.encode(address pool)` | Supplied | `["Curve","Liquidity Pool","USDC/USDT/DAI LP"]` |
| `CurveGaugesMetaBalanceAdapter` | `curve-gauge` | `"Curve"` | `["Staking Gauge", "<coins> gauge"]` (derived) | `abi.encode(address gauge)` | Staking / Rewards | `["Curve","Staking Gauge","USDC/USDT/DAI gauge"]` |
| `UniswapV2PoolsMetaBalanceAdapter` | `uniswap-v2` | `"Uniswap V2"` | `["Liquidity Pool", "<sym0>/<sym1> LP"]` (derived) | `abi.encode(address pair)` | Supplied | `["Uniswap V2","Liquidity Pool","WETH/USDC LP"]` |
| `PancakeSwapV2PoolsMetaBalanceAdapter` | `pancakeswap-v2` | `"PancakeSwap V2"` | `["Liquidity Pool", "<sym0>/<sym1> LP"]` (derived, inherited) | `abi.encode(address pair)` | Supplied | `["PancakeSwap V2","Liquidity Pool","WBNB/BUSD LP"]` |

#### Assisted adapters (`src/balances/AssistedBalanceAdapters/`)

| Adapter | `protocolId` | `protocolName()` | `positionLabels` → (source) | `positionId` schema | `PositionKind` legs | Example breadcrumb |
|---|---|---|---|---|---|---|
| `MerklRewardsBalanceAdapter` | `merkl` | `"Merkl"` (const) | `["Claimable Rewards"]` (const) | `abi.encode(address DISTRIBUTOR)` | Rewards | `["Merkl","Claimable Rewards"]` |
| `EtherFiWithdrawalQueueBalanceAdapter` | `etherfi-withdrawal` | `"ether.fi"` (const) | `["eETH Withdrawal Queue"]` (const) | `abi.encode(address withdrawRequestNFT)` | Supplied | `["ether.fi","eETH Withdrawal Queue"]` |
| `StakeWiseV3ExitQueueBalanceAdapter` | `stakewise-exit` | `"StakeWise V3"` (const) | `["Exit Queue"]` (const) | `abi.encode(address vaultsRegistry)` | Supplied | `["StakeWise V3","Exit Queue"]` |
| `NexusMutualStakingPoolsBalanceAdapter` | `nexus-mutual-staking` | `"Nexus Mutual"` (const) | `["Staking"]` (const) | `abi.encode(uint256 tokenId, uint256 poolId)` | Staking / Rewards | `["Nexus Mutual","Staking"]` |
| `UniswapV3PoolsMetaBalanceAdapter` | `uniswap-v3` | `"Uniswap V3"` (gov) | `["Liquidity Pool", "NFT #<tokenId>"]` (derived) | `abi.encode(address npm, uint256 tokenId)` | Supplied / Fees | `["Uniswap V3","Liquidity Pool","NFT #12345"]` |
| `PancakeSwapV3PoolsMetaBalanceAdapter` | `pancakeswap-v3` | `"PancakeSwap V3"` (gov) | `["Liquidity Pool", "NFT #<tokenId>"]` (derived, inherited) | `abi.encode(address npm, uint256 tokenId)` | Supplied / Fees | `["PancakeSwap V3","Liquidity Pool","NFT #12345"]` |

#### What each `positionId` value is

Every encoded value above is the **canonical on-chain coordinate** of the position — the contract (or
contract + id) you would call to act on it. Decode each with the schema in the table; here is exactly
what each argument refers to:

| Encoded value | What it is |
|---|---|
| `address asset` | The ERC20 token held in the wallet (or the native-token sentinel `0xEeee…EEeE` for ETH/native). The same address is also in `balanceAsset.asset`. |
| `address pool` (Aave V3) | The Aave V3 `Pool` contract of that market instance (resolved from the instance's `ProtocolDataProvider`). One Aave position per instance; the reserve token is in `balanceAsset`, not here. |
| `address POOL` (Spark) | The SparkLend `Pool` contract (SparkLend is Aave V3's `Pool` logic, deployed by Spark). Reserve token is in `balanceAsset`. |
| `address comet` | The Compound V3 `Comet` market contract (e.g. the cUSDCv3 Comet). Base token, collaterals and COMP rewards are all distinguished by `balanceAsset` + `positionKind`. |
| `address vault` | The ERC4626 (or vault) share-token contract: a MetaMorpho vault, an Euler `EVault`, a Fluid T1 vault, or a StakeWise V3 vault. It is the contract whose `convertToAssets`/valuation is read. |
| `address fToken` | The Fluid lending `fToken` (an ERC4626 share token, e.g. `fUSDC`). |
| `address market` (Gearbox) | The Gearbox V3 pool contract (an ERC4626 "diesel" pool, e.g. `dUSDC`). |
| `bytes32 marketId` (Morpho) | Morpho's `Id` for one isolated market — `keccak256` of the market params `(loanToken, collateralToken, oracle, irm, lltv)`. **Raw `bytes32`, not an address.** Collateral, supply and borrow legs of the market share it. |
| `address stakeToken` | The Aave staking-token contract: a Safety Module `stk*` token (stkAAVE / stkGHO / stkABPT) or an Aave Umbrella stake token. Staked principal and claimable rewards share it. |
| `address CUSD` / `address STCUSD` | The Cap protocol's cUSD (synthetic dollar) or stcUSD (staked cUSD / savings) token contract — one per leg, so the two legs carry different addresses. |
| `address wrapper` | The generic ERC4626 wrapper share token the adapter was deployed for (e.g. `waEthLidoGHO`, `sGHO`). Distinct deployments carry distinct wrapper addresses. |
| `address pair` | The **Uniswap V2 / PancakeSwap V2 pool contract**, which is *also* the LP (liquidity-provider) ERC20 token — in V2 the pair contract and its LP token are the same address. token0/token1 legs share it. |
| `address pool` (Balancer V3 / Curve) | The liquidity-pool contract: a Balancer V3 pool (also its BPT token) or a Curve pool. Per-coin `Supplied` legs share it. |
| `bytes32 poolId` (Balancer V2) | The Balancer V2 Vault `poolId` — the pool's 32-byte id used by the Balancer `Vault` (the first 20 bytes are the pool address). **Raw `bytes32`, not an address** (Balancer V2 keys pools by id, not address). |
| `address gauge` | The staking **gauge** contract (Balancer V2/V3 or Curve) the LP is staked into. Staked principal and claimable reward legs share it. |
| `address rewarder` (Convex) | The Convex `BaseRewardPool` ("rewarder") for that Curve LP. The underlying Curve pool, its coins and the CRV/CVX/extra rewards are derived from it. |
| `address npm, uint256 tokenId` | **`npm` = the `NonfungiblePositionManager`** (Uniswap V3 mainnet `0xC364…FE88`, or the PancakeSwap V3 NPM) — the ERC721 contract that mints LP-position NFTs. **`tokenId`** = the specific LP NFT. Keyed per NFT (not per pool) since one pool can hold many NFTs; the four legs (token0/token1 × liquidity/fees) share it. |
| `uint256 tokenId, uint256 poolId` (Nexus) | **`tokenId`** = the Nexus Mutual `StakingNFT` id (one staking position); **`poolId`** = the Nexus staking pool that NFT belongs to. Staking and reward legs (both NXM) share it. |
| `address DISTRIBUTOR` (Merkl) | The Merkl `Distributor` (Angle Labs) — the claim target / trust anchor. All reward tokens claimed from it share this id and are told apart by `balanceAsset`. |
| `address withdrawalQueue` (Lido) | Lido's `WithdrawalQueueERC721` — the contract that escrows stETH withdrawal requests and pays out ETH on claim. |
| `address userWithdrawalManager` (Stader) | Stader's `UserWithdrawalManager` — escrows ETHx unstake requests, pays ETH (valued to WETH) on claim. |
| `address withdrawalManager` (Kelp) | Kelp DAO's `LRTWithdrawalManager` — escrows rsETH exit requests across payout assets. |
| `address withdrawRequestNFT` (ether.fi) | ether.fi's `WithdrawRequestNFT` — the ERC721 that represents eETH withdrawal requests and is the claim target. |
| `address vaultsRegistry` (StakeWise) | StakeWise V3's `VaultsRegistry` — the immutable anchor gating which vaults the exit-queue cache accepts. |
| `address sUSDe` (Ethena) | Ethena's `StakedUSDeV2` (sUSDe) — the staking contract that holds the unstaking cooldown and is the claim target; the owed USDe is in `balanceAsset`. |

For the six account-global adapters (Lido, Stader, Kelp, ether.fi, StakeWise V3 exit, Ethena cooldown)
the encoded contract is the adapter's single immutable anchor — there is one aggregated leg per account,
so the anchor (not a per-request id) is the coordinate.

**Multi-leg rule.** Where an adapter emits several legs (lending supply/borrow/collateral; gauge
stake/rewards; Uniswap V3 liquidity/fees; StakeWise vault/osToken-debt), all legs **share one
`positionId` and one label set** — they are distinguished by `positionKind` and, for per-token legs, by
`balanceAsset.asset` (the underlying token), never by extra label elements.

**Account-global adapters.** The withdrawal/exit queues (Lido, Stader, Kelp, ether.fi, StakeWise V3)
and the Ethena cooldown report one aggregated leg per account, so their `positionId` encodes the
adapter's immutable anchor contract (the queue/manager/registry, or sUSDe) rather than a per-request
id; the owed asset lives in `balanceAsset.asset`. No adapter emits an empty `positionId`.

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
   - Vault shares, LP principal → `Supplied`
   - Staking principal → `Staking`
   - Unclaimed reward tokens → `Rewards`
   - Uncollected LP/protocol fees → `Fees`
   - ERC20 wallet balance → `Wallet`
4. Implement `IPositionDescribable` to provide human-readable labels:
   - `protocolName()` — static `pure` string for per-instance adapters; same constant for meta-adapters
   - `positionLabels(bytes positionId) → string[]` — ordered hierarchy below protocol, leaf last. Derive
     on-chain for meta-adapters (decode positionId, read token symbols) returning `[category, …leaf]`; a
     fixed array for per-instance adapters
5. Update this table above and the `ProtocolIds` schema comment.

See [`howto/add-balance-adapter.md`](add-balance-adapter.md) for the full end-to-end recipe.
