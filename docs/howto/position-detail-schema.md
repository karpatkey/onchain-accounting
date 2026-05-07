# `positionDetail` JSON Schema

Each `PositionBalance` and `Position` returned by the NAV stack carries a `positionDetail` field — a
fully-closed JSON object that gives the frontend (and off-chain tooling) structured metadata about
**what kind of position this is**, without having to parse the `protocol` string.

## Wire format

```
{"protocol":"<protocol>","product":"<product>"[,"type":"<type>"][,"token":"<token>"]}
```

All adapters store a **base string** (no closing `}`) in a private constructor-pinned variable and
append the closing fragment at query time, so the returned string is always valid JSON.

## Keys

| Key | Required | Example values | Notes |
|-----|----------|----------------|-------|
| `protocol` | ✓ | `"Aave V3"`, `"Morpho"`, `"Curve"`, `"wallet"` | Mirrors the adapter's `protocol` field. Stable name for the top-level protocol. |
| `product` | ✓ | see table below | The market or product name as shown in the protocol's own UI. |
| `type` | ✗ | `"Supply"`, `"Borrow"`, `"Collateral"`, `"Reward"`, `"Staked"`, `"fees"` | Disambiguates sub-positions within one adapter instance. |
| `token` | ✗ | `"WETH"`, `"CRV"`, `"CVX"` | Added by adapters that return multiple token legs (e.g. Convex, Curve rewards). |

## `product` and `name` values by adapter type

`product` describes the **category** of the position within the protocol. `name` (optional) identifies the
specific **market or instance**, using the name shown in the protocol's own UI.

| Adapter | `product` | `name` |
|---------|-----------|--------|
| Aave V3 — Mainnet Core pool | `"Lending"` | `"Core Instance"` |
| Aave V3 — Mainnet Prime pool | `"Lending"` | `"Prime Instance"` |
| Aave V3 — Optimism pool | `"Lending"` | `"Optimism Market"` |
| Aave V3 — Gnosis pool | `"Lending"` | `"Gnosis Market"` |
| Aave V3 — Arbitrum pool | `"Lending"` | `"Arbitrum Market"` |
| Aave V3 — Base pool | `"Lending"` | `"Base Market"` |
| Aave V2 — Mainnet | `"Lending"` | `"Mainnet Market"` |
| Spark / SparkLend | `"Lending"` | `"SparkLend"` |
| Aave V3 Safety Module | `"Staking"` | — |
| Aave Umbrella | `"Staking"` | — |
| Morpho Vault | `"Vault"` | vault display name (e.g. `"kpk ETH Prime V1"`) |
| Morpho Market | `"Market"` | collateral/loan pair (e.g. `"wstETH/USDC"`) |
| Compound V3 | `"Lending"` | base token (e.g. `"USDC"`) |
| Fluid fToken | `"Lending"` | fToken symbol (e.g. `"fUSDC"`) |
| Fluid Vault | `"Vault"` | collateral/debt pair (e.g. `"wstETH/USDC"`) |
| Gearbox Market | `"Market"` | pool name (e.g. `"kpk WETH market"`) |
| Curve gauge | `"LP"` | pair name (e.g. `"weETH/WETH"`) |
| Convex rewards | `"LP"` | pair name (e.g. `"weETH/WETH"`) |
| Balancer V3 pool | `"LP"` | pool name (e.g. `"rETH/Aave WETH"`) |
| Aura gauge | `"LP"` | pool name (e.g. `"Aave GHO/USDT/USDC"`) |
| Cap | `"Lending"` | `"cUSD + stcUSD"` |
| StakeWise V3 vault | `"Staking"` | vault name (e.g. `"Genesis Vault"`) |
| StakeWise V3 osToken | `"Staking"` | token symbol (e.g. `"osETH"`) |
| Stader withdrawal queue | `"Staking"` | `"ETH Withdrawal Queue"` |
| Merkl rewards | `"Rewards"` | `"Unclaimed Rewards"` |
| Uniswap V3 pool | `"LP"` | pair + fee (e.g. `"WBTC/WETH 0.3%"`) |
| Uniswap V2 pair | `"LP"` | pair (e.g. `"ETH/COW"`) |
| PancakeSwap V2 pair | `"LP"` | pair (e.g. `"ETH/COW LP"`) |
| PancakeSwap V3 pool | `"LP"` | pair + fee (e.g. `"WETH/COW 0.25%"`) |
| ERC20 default (wallet) | `"Holding"` | — |

Aave V3 market names follow the naming used in the Aave App (app.aave.com → market selector labels).

## `positionId`

The `positionId` field is a hex string that stably identifies this specific adapter **instance** (not
the position type). It is the most specific immutable address pinned by the adapter's constructor:

| Adapter type | `positionId` source |
|---|---|
| AaveV3 / AaveV2 / Spark | `dataProvider` address |
| Aave V3 Safety Module | `stkAAVE` address (first hardcoded stake token) |
| Aave Umbrella | `rewardsController` address |
| Morpho Vault | `vault` address |
| Morpho Market | `marketId` (bytes32 hex) |
| Compound V3 | `comet` address |
| Fluid fToken | `fToken` address |
| Fluid Vault | `vault` address |
| Gearbox Market | `market` address |
| Curve gauge | `gauge` address |
| Convex | `rewarder` address |
| Balancer V3 | `pool` address |
| Aura | `pool` address |
| Cap | `stcUsd` address |
| StakeWise V3 Vault | `vault` address |
| StakeWise V3 osToken | `osToken` address |
| Stader | `userWithdrawalManager` address |
| Merkl Rewards | `distributor` address |
| Uniswap V3 / PancakeSwap V3 | `pool` address |
| Uniswap V2 / PancakeSwap V2 | `pair` address |
| ERC20 default (wallet) | `0x000…0` (zero address sentinel) |

## Adding a new adapter

When implementing a new balance adapter:

1. Choose a `positionDetail` base string following the schema above.
   - Decide `product` by looking at the protocol's own UI for the market/product name.
   - Only add `type` or `token` if the adapter emits multiple positions per call that differ by
     position type or token.
2. Pick `positionId` as the most specific immutable address in the constructor.
3. Store both as private constructor-pinned variables.
4. Emit: `string.concat(_positionDetail, "}")` for single-type adapters, or
   `string.concat(_positionDetail, ",\"type\":\"", typeLabel, "\"}")` for multi-type adapters.
5. Add `positionDetail` and `positionId` to the adapter's `constructor` block in every chain
   config that uses it (`script/config/chains/<chainId>.json`).
