# Position Identity Schema

Every `PositionBalance` returned by the NAV stack carries a stable, machine-readable identity.
This document explains all fields, provides a concrete example for every adapter, and describes
how to decode and use the identity for indexing, reconciliation, and action routing.

---

## `PositionBalance` — field reference

```solidity
struct PositionBalance {
    Asset        balanceAsset;        // token the amount is denominated in
    address      balanceAdapter;      // adapter that reported this row (provenance only)
    uint256      amount;              // magnitude, always positive
    bool         isDebt;              // NAV sign: true = subtract, false = add
    bytes32      protocolBrand;       // keccak256("brand") — broadest roll-up (display/grouping only)
    bytes32      protocolId;          // keccak256("ecosystem") — grouping roll-up (display/grouping only)
    bytes32      protocolSubId;       // keccak256("protocol-product") — selects positionId schema; part of the key
    bytes        positionId;          // abi.encode(...) — stable on-chain key
    PositionKind positionKind;        // Wallet | Supplied | Borrowed | Collateral | Staking | Rewards | Fees
    bool         isLocked;            // true = not withdrawable now (pending withdrawal OR active/cooling stake); false = withdrawable now; mutable per-leg attribute, NOT part of the key
    bytes32      positionInstanceId;  // ephemeral per-item id (NFT/request/ticket) as bytes32; bytes32(0) when none; EXCLUDED from the key
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

**`protocolBrand` / `protocolId` / `protocolSubId`** — `bytes32` each

A three-level protocol taxonomy, all `keccak256` of canonical kebab-case ASCII slugs (constants
in `src/utils/ProtocolIds.sol`):

- **`protocolBrand`** — the broadest, version-stripped brand roll-up (e.g. `"aave"`, `"balancer"`).
  Display / grouping only; **not** part of the reconciliation key. Equals `protocolId` for
  unversioned protocols.
- **`protocolId`** — the protocol-ecosystem slug (e.g. `"aave-v3"`, `"curve"`). A grouping roll-up —
  several `protocolSubId`s share it (e.g. `aave-v3-lending` + `aave-v3-safety-module` both roll up
  to `aave-v3`). Display / grouping only; **not** part of the key (it is functionally determined by
  `protocolSubId`). Equals `protocolSubId` for single-product ecosystems.
- **`protocolSubId`** — the specific protocol-product slug (e.g. `"aave-v3-lending"`). This is the
  one that maps to exactly one `positionId` ABI-decode schema — switch on `protocolSubId` to know
  how to decode `positionId` without runtime sniffing — and it is the protocol component of the
  reconciliation key.

**`positionId`** — `bytes`

`abi.encode(...)` of the **static, timeless** on-chain key for this position. Withdrawal /
exit queues and the Ethena cooldown encode their immutable anchor (queue / manager / vault /
sUSDe / asset) — never a per-request id. The schema is uniquely determined by `protocolSubId`;
full table below.

**`positionKind`** — `PositionKind`

Semantic category of the leg. Together with `protocolSubId`, `positionId`, and
`balanceAsset.asset` it forms the per-chain reconciliation key:
`keccak256(abi.encode(chainId, protocolSubId, positionId, balanceAsset.asset, positionKind))`.

**`isLocked`** — `bool`

`true` = **not withdrawable now** (a pending withdrawal request, OR an active / cooling stake);
`false` = **withdrawable now**. So the pending portion of a withdrawal queue and the active stake
of a staking-with-cooldown adapter (Aave SM, Umbrella — active stake needs a cooldown before it can
be withdrawn) are both locked; a finalized request or an in-window elapsed cooldown is unlocked.
The withdrawal-queue / cooldown / staking-with-cooldown adapters split an account's holding
into up to two legs that **share the same static `positionId`** — a claimable leg
(`isLocked=false`) and a locked / pending leg (`isLocked=true`). `isLocked` is a **mutable
per-leg attribute and is NOT part of the reconciliation key**: a leg flips `true→false` as its
portion finalizes/unlocks, so keying on it would split one economic position into two keys over
its lifetime. The two legs therefore **share one key and are summed** in reconciliation (the sum
is the full holding); read `isLocked` per leg for the claimable-vs-locked breakdown. `false` for
every other adapter. "Partial = locked": any not-yet-withdrawable amount lands on the locked leg. See
[ADR 0016](../decisions/0016-islocked-position-status.md).

**`positionInstanceId`** — `bytes32`

The **sole ephemeral** identity field: a per-item coordinate — a Uniswap V3 / PancakeSwap V3 / Nexus
Mutual NFT id, a withdrawal / exit request id, or a StakeWise exit ticket — each a `uint256` widened
to `bytes32`. `bytes32(0)` for adapters with no per-item granularity. It is **excluded** from the
reconciliation key by design, so the legs of one anchor sum and identity survives item churn. A
consumer that wants per-item granularity MAY append it to the key, at the cost of an ephemeral key
(it blinks in/out as items are minted / burned / claimed). Never use it for stable identity.

### The enriched sibling: `Position`

NAVCalculator's `getAccountPositions` returns `Position`, which adds pricing on top:

```solidity
struct Position {
    // PositionBalance's balance fields: balanceAsset, balanceAdapter, amount, isDebt +
    Asset   quoteAsset;       // quote currency (USD, ETH, …)
    int256  value;            // signed value in quoteAsset (negative for debt)
    int256  price;            // price used: quoteAsset per balanceAsset unit
    uint8   priceDecimals;    // decimal precision of price
    bool    stale;            // true if the price feed was stale at query time
    bool    quoteAssetStale;  // true if the quote asset's own feed was stale (value falls back to USD 8dp)
    // + the identity fields: protocolBrand, protocolId, protocolSubId, positionId,
    //   positionKind, isLocked, positionInstanceId
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
    protocolSubId: keccak256("wallet"),    // protocolBrand = protocolId = protocolSubId for wallet
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
    protocolSubId: keccak256("spark-lend"),
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
    protocolSubId: keccak256("aave-v3-safety-module"),
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
    protocolSubId: keccak256("aave-v3-umbrella"),
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
    protocolSubId: keccak256("cap"),
    positionId:    abi.encode(0x<cUSD>),   // Cap cUSD token address
    positionKind:  PositionKind.Supplied
})
// Leg 2 — staked stcUSD (label ["Savings", "stcUSD"])
PositionBalance({
    balanceAsset:  Asset({ asset: 0xA0b8…6eB48, symbol: "USDC", decimals: 6 }),
    balanceAdapter: 0x<CapAdapter>,
    amount:        1_000_000_000,          // 1 000 USDC (stcUSD → cUSD → USDC)
    isDebt:        false,
    protocolSubId: keccak256("cap"),
    positionId:    abi.encode(0x<stcUSD>), // Cap stcUSD token address
    positionKind:  PositionKind.Staking   // stcUSD is staked cUSD
})
```

#### `KelpWithdrawalQueue` — rsETH exit queue

```solidity
// Static positionId = abi.encode(withdrawalManager), shared by all of the account's requests.
// One leg PER open request per asset (told apart by isLocked); the payout asset is in balanceAsset,
// and the request's userNonce rides in positionInstanceId.
PositionBalance({
    balanceAsset:       Asset({ asset: 0xae7a…2Ca0, symbol: "stETH", decimals: 18 }),
    balanceAdapter:     0x<KelpWithdrawalQueueAdapter>,
    amount:             2e18,                   // 2 stETH still pending (this request)
    isDebt:             false,
    protocolSubId:      keccak256("kelp-withdrawal"),
    positionId:         abi.encode(0x<LRTWithdrawalManager>),  // Kelp LRTWithdrawalManager (static anchor)
    positionKind:       PositionKind.Supplied,
    isLocked:           true,                   // pending; a claimable (isLocked=false) request is its own leg
    positionInstanceId: bytes32(uint256(42))    // ephemeral userNonce (per-request only)
})
```

#### `LidoWithdrawalQueue` — stETH → ETH queue

```solidity
// One leg PER open withdrawal request, all sharing the static positionId = abi.encode(withdrawalQueue);
// denominated in ETH (not stETH). The ERC721 request id rides in positionInstanceId, never in positionId.
PositionBalance({
    balanceAsset:       Asset({ asset: 0xEeee…EeeE, symbol: "ETH", decimals: 18 }),
    balanceAdapter:     0x<LidoWithdrawalQueueAdapter>,
    amount:             1e18,                   // this request's claimable (finalized) or amountOfStETH (pending) ETH
    isDebt:             false,
    protocolSubId:      keccak256("lido-withdrawal"),
    positionId:         abi.encode(0x<LidoWithdrawalQueue>),  // Lido WithdrawalQueueERC721 (static anchor, shared by all requests)
    positionKind:       PositionKind.Supplied,
    isLocked:           false,                  // false = finalized/claimable; a pending request is its own leg with isLocked=true
    positionInstanceId: bytes32(uint256(54321)) // ephemeral ERC721 request id (display / per-item only)
})
```

#### `MerklRewardsAssisted` — unclaimed Merkl allocation

> Note: no Merkl adapter is deployed on `main` today — the former `MerklRewardsAssistedBalanceAdapter` was removed and a re-add is pending. The schema below is retained for the returning adapter.

```solidity
// One leg per reward token; proof-cached balance (may lag until next proof update).
PositionBalance({
    balanceAsset:  Asset({ asset: 0xD533…cd52, symbol: "CRV", decimals: 18 }),
    balanceAdapter: 0x<MerklRewardsAssistedAdapter>,
    amount:        250e18,                 // 250 CRV unclaimed
    isDebt:        false,
    protocolSubId: keccak256("merkl"),
    positionId:    abi.encode(0x3Ef3…D9Ae),  // Merkl Distributor (reward token is in balanceAsset)
    positionKind:  PositionKind.Rewards
})
```

#### `StaderWithdrawalQueue` — ETHx → ETH queue

```solidity
// Static positionId = abi.encode(userWithdrawalManager), shared by all of the account's requests.
// One leg PER open request (told apart by isLocked); denominated in WETH, request id in positionInstanceId.
PositionBalance({
    balanceAsset:       Asset({ asset: 0xC02a…6Cc2, symbol: "WETH", decimals: 18 }),
    balanceAdapter:     0x<StaderWithdrawalQueueAdapter>,
    amount:             5e17,                   // 0.5 WETH still pending (this request)
    isDebt:             false,
    protocolSubId:      keccak256("stader-withdrawal"),
    positionId:         abi.encode(0x<StaderUserWithdrawalManager>),  // Stader UserWithdrawalManager (static anchor)
    positionKind:       PositionKind.Supplied,
    isLocked:           true,                   // not finalized; a finalized request is its own leg with isLocked=false
    positionInstanceId: bytes32(uint256(7001))  // ephemeral Stader request id (per-request only)
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
    protocolSubId: keccak256("aave-v3-lending"),
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
    protocolSubId: keccak256("morpho-vaults"),
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
    protocolSubId: keccak256("morpho-markets"),
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
    protocolSubId: keccak256("euler-vaults"),
    positionId:    abi.encode(0x<EulerVault>),
    positionKind:  PositionKind.Supplied
})
```

#### `GearboxV3MarketsMeta` — Gearbox V3 farming pool

```solidity
PositionBalance({
    balanceAsset:  Asset({ asset: 0xA0b8…6eB48, symbol: "USDC", decimals: 6 }),
    balanceAdapter: 0x<GearboxV3MarketsMeta>,
    amount:        1_000_000_000,
    isDebt:        false,
    protocolSubId: keccak256("gearbox-v3-markets"),
    positionId:    abi.encode(0x<GearboxV3Market>),  // ERC4626 pool address
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
    protocolSubId: keccak256("fluid-ftokens"),
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
    protocolSubId: keccak256("fluid-vaults"),
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
    protocolSubId: keccak256("compound-v3-comets"),
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
    protocolSubId: keccak256("stakewise-v3-vaults"),
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
    protocolSubId: keccak256("balancer-v3-pools"),
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
    protocolSubId: keccak256("balancer-v3-gauges"),
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
    protocolSubId: keccak256("balancer-v2-pools"),
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
    protocolSubId: keccak256("balancer-v2-gauges"),
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
    protocolSubId: keccak256("curve-pools"),
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
    protocolSubId: keccak256("curve-gauges"),
    positionId:    abi.encode(0x<CurveGauge>),
    positionKind:  PositionKind.Staking
})
```

#### `ConvexCurveLPStakingMeta` — Convex staked Curve LP

```solidity
// Staked LP decomposed into pool coins. Other legs: Rewards (CRV, CVX, extras).
PositionBalance({
    balanceAsset:  Asset({ asset: 0x<crvUSD>, symbol: "crvUSD", decimals: 18 }),
    balanceAdapter: 0x<ConvexCurveLPStakingMeta>,
    amount:        1_000e18,
    isDebt:        false,
    protocolSubId: keccak256("convex-curve-lp-staking"),  // protocolId = protocolBrand = keccak256("convex")
    positionId:    abi.encode(0x<ConvexBaseRewardPool>),
    positionKind:  PositionKind.Staking
})
```

#### `UniswapV3PoolsMeta` — Uniswap V3 NFT position

```solidity
// positionId = the pool contract address (factory.getPool(token0,token1,fee)). Two Supplied legs
// (token0, token1 in-range liquidity) + two Fees legs share it. The NFT id is NOT in positionId — it
// is the typed positionInstanceId on each leg.
PositionBalance({
    balanceAsset:       Asset({ asset: 0xA0b8…6eB48, symbol: "USDC", decimals: 6 }),
    balanceAdapter:     0x<UniswapV3PoolsMeta>,
    amount:             600_000_000,            // 600 USDC in-range liquidity (NFT #12345)
    isDebt:             false,
    protocolSubId:      keccak256("uniswap-v3"), // protocolId = protocolSubId; protocolBrand = keccak256("uniswap")
    positionId:         abi.encode(0x<pool>),   // the WBTC/WETH-style pool address
    positionKind:       PositionKind.Supplied,
    positionInstanceId: bytes32(uint256(12345)) // ephemeral NFT token id (per-item only)
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
    protocolSubId: keccak256("uniswap-v2"),
    positionId:    abi.encode(0x<USDCWETHPair>),
    positionKind:  PositionKind.Supplied
})
```

#### `PancakeSwapV3PoolsMeta` / `PancakeSwapV2PoolsMeta`

Thin subclasses of the UniswapV3/V2 adapters with different factory/`pair` addresses and the
`pancakeswap-v3` / `pancakeswap-v2` protocol slugs. All field schemas are identical (V3 positionId = pool
address, NFT id in `positionInstanceId`; V2 positionId = pair address).

---

## `getAccountPositionsVerbose` — full return values by adapter

`navCalculator.getAccountPositionsVerbose(account, address(0))` (USD quote) returns `VerbosePosition[]`.
Each entry wraps a `Position` (all `PositionBalance` fields + `value`, `price`, `priceDecimals`,
`stale`, `quoteAsset`) with `protocolName` and `labels` (`string[]`), both sourced from the adapter's
`IPositionDescribable` implementation via a fail-open staticcall.

The tables below show what the call returns for a representative account position in each protocol.
**`value (USD)`** is the signed contribution to NAV (negative = debt). `protocolName` comes from
`IPositionDescribable.protocolName()`; `labels` comes from `IPositionDescribable.positionLabels(positionId)`
(the ordered hierarchy below `protocolName`, leaf last) — computed lazily from `positionId`, so
meta-adapters derive it on-chain from live state and per-instance adapters return a fixed array.

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

#### `KelpWithdrawalQueue` — pending + claimable unstake

Scenario: 3 stETH in the Kelp queue — 2 still pending, 1 claimable now. Two legs sharing one static
positionId (`abi.encode(withdrawalManager)`), told apart by `isLocked`; the payout asset (stETH) is in `balanceAsset`.

| asset  | amount | value (USD) | positionKind | isLocked | protocolName | labels |
|--------|--------|-------------|--------------|----------|--------------|---------------|
| stETH  | 1.0    | +2 480      | `Supplied`   | false    | `"Kelp DAO"` | `["Withdrawal Queue", "rsETH"]` |
| stETH  | 2.0    | +4 960      | `Supplied`   | true     | `"Kelp DAO"` | `["Withdrawal Queue", "rsETH"]` |

#### `LidoWithdrawalQueue` — claimable unstake

Scenario: one finalized request (1 ETH, claimable now) plus one pending request (0.5 ETH). One leg **per
request**, both sharing the static `withdrawalQueue` positionId and the same static labels; each carries its
ERC721 request id in the typed `positionInstanceId`.

| asset | amount | value (USD) | positionKind | isLocked | positionInstanceId | protocolName | labels |
|-------|--------|-------------|--------------|----------|--------------------|--------------|---------------|
| ETH   | 1.0    | +2 500      | `Supplied`   | false    | `54321`            | `"Lido"`     | `["Withdrawal Queue", "stETH"]` |
| ETH   | 0.5    | +1 250      | `Supplied`   | true     | `54322`            | `"Lido"`     | `["Withdrawal Queue", "stETH"]` |

#### `MerklRewardsAssisted` — unclaimed rewards

Scenario: 250 CRV unclaimed in Merkl distributor. (Schema shown for the pending re-add — no Merkl adapter is live on `main` today.)

| asset | amount | value (USD) | positionKind | protocolName | labels |
|-------|--------|-------------|--------------|--------------|---------------|
| CRV   | 250    | +125        | `Rewards`    | `"Merkl"`    | `["Claimable Rewards"]` |

#### `StaderWithdrawalQueue` — pending unstake

Scenario: 0.5 WETH pending (not finalized) from ETHx unstake ⇒ only the `isLocked=true` leg.
A finalized portion would appear as a second leg with `isLocked=false` sharing the same positionId.

| asset | amount | value (USD) | positionKind | isLocked | protocolName | labels |
|-------|--------|-------------|--------------|----------|--------------|---------------|
| WETH  | 0.5    | +1 250      | `Supplied`   | true     | `"Stader"`   | `["Withdrawal Queue", "ETHx"]` |

---

### Meta-adapters

#### `AaveV3InstancesMeta`

Scenario: 1 500 USDC supplied (not collateral), 1 WETH as collateral, 500 USDC borrowed — all on Aave V3 Core.

| asset | amount | value (USD) | positionKind | protocolName | labels     |
|-------|--------|-------------|--------------|--------------|-------------------|
| USDC  | 1 500  | +1 500      | `Supplied`   | `"Aave V3"`  | `["Market", "Aave V3 Ethereum Market"]` |
| WETH  | 1.0    | +2 500      | `Collateral` | `"Aave V3"`  | `["Market", "Aave V3 Ethereum Market"]` |
| USDC  | 500    | −500        | `Borrowed`   | `"Aave V3"`  | `["Market", "Aave V3 Ethereum Market"]` |
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
| wstETH  | 2.0    | +5 800      | `Collateral` | `"Morpho"`   | `["Market", "wstETH/USDC"]`  |
| USDC    | 1 000  | −1 000      | `Borrowed`   | `"Morpho"`   | `["Market", "wstETH/USDC"]`  |
| **NAV** | | **+4 800** | | | |

#### `EulerVaultsMeta`

Scenario: 4 000 USDC supplied in an Euler V2 vault (not enabled as EVC collateral).

| asset | amount | value (USD) | positionKind | protocolName | labels        |
|-------|--------|-------------|--------------|--------------|----------------------|
| USDC  | 4 000  | +4 000      | `Supplied`   | `"Euler"`    | `["Vault", "Euler USDC vault"]` |

#### `GearboxV3MarketsMeta`

Scenario: 1 000 USDC in Gearbox USDC farming pool.

| asset | amount | value (USD) | positionKind | protocolName  | labels          |
|-------|--------|-------------|--------------|---------------|------------------------|
| USDC  | 1 000  | +1 000      | `Supplied`   | `"Gearbox"`   | `["Market", "Gearbox USDC Farm"]`  |

#### `FluidFTokensMeta`

Scenario: 1 000 USDC in Fluid fUSDC.

| asset | amount | value (USD) | positionKind | protocolName | labels  |
|-------|--------|-------------|--------------|--------------|----------------|
| USDC  | 1 000  | +1 000      | `Supplied`   | `"Fluid"`    | `["Lending", "fUSDC"]` |

#### `FluidVaultsMeta`

Scenario: 1 WETH collateral, 500 USDC debt in a Fluid T1 vault.

| asset | amount | value (USD) | positionKind | protocolName | labels     |
|-------|--------|-------------|--------------|--------------|-------------------|
| WETH  | 1.0    | +2 500      | `Collateral` | `"Fluid"`    | `["Vault", "ETH/USDC #21"]` |
| USDC  | 500    | −500        | `Borrowed`   | `"Fluid"`    | `["Vault", "ETH/USDC #21"]` |
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
| ETH   | 2.0    | +5 000      | `Staking`    | `"StakeWise V3"`  | `["Vault"]` |
| ETH   | 0.5    | −1 250      | `Borrowed`   | `"StakeWise V3"`  | `["Vault"]` |
| **NAV** | | **+3 750** | | | |

#### `BalancerV3PoolsMeta`

Scenario: wallet holds BPT representing 800 USDC + 0.32 WETH in a Balancer V3 USDC/WETH pool.

| asset | amount | value (USD) | positionKind | protocolName    | labels        |
|-------|--------|-------------|--------------|-----------------|----------------------|
| USDC  | 800    | +800        | `Supplied`   | `"Balancer V3"` | `["AMM Liquidity Pool", "Balancer 50 WETH 50 USDC"]`  |
| WETH  | 0.32   | +800        | `Supplied`   | `"Balancer V3"` | `["AMM Liquidity Pool", "Balancer 50 WETH 50 USDC"]`  |
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
| USDC  | 800    | +800        | `Supplied`   | `"Balancer V2"` | `["AMM Liquidity Pool", "50WETH-50USDC"]` |
| WETH  | 0.32   | +800        | `Supplied`   | `"Balancer V2"` | `["AMM Liquidity Pool", "50WETH-50USDC"]` |
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
| crvUSD | 1 000  | +1 000      | `Supplied`   | `"Curve"`    | `["AMM Liquidity Pool", "crvUSD/USDC"]`  |
| USDC   | 1 000  | +1 000      | `Supplied`   | `"Curve"`    | `["AMM Liquidity Pool", "crvUSD/USDC"]`  |
| **NAV** | | **+2 000** | | | |

#### `CurveGaugesMeta`

Scenario: staked gauge LP (same pool as above) with 100 CRV rewards.

| asset  | amount | value (USD) | positionKind | protocolName | labels          |
|--------|--------|-------------|--------------|--------------|------------------------|
| crvUSD | 1 000  | +1 000      | `Staking`    | `"Curve"`    | `["Staking Gauge", "crvUSD/USDC"]`  |
| USDC   | 1 000  | +1 000      | `Staking`    | `"Curve"`    | `["Staking Gauge", "crvUSD/USDC"]`  |
| CRV    | 100    | +50         | `Rewards`    | `"Curve"`    | `["Staking Gauge", "crvUSD/USDC"]`  |
| **NAV** | | **+2 050** | | | |

#### `ConvexCurveLPStakingMeta`

Scenario: Convex-staked crvUSD/USDC LP with 100 CRV + 50 CVX rewards.

| asset  | amount | value (USD) | positionKind | protocolName | labels              |
|--------|--------|-------------|--------------|--------------|----------------------------|
| crvUSD | 1 000  | +1 000      | `Staking`    | `"Convex"`   | `["Staking", "Curve LP", "crvUSD/USDC"]`     |
| USDC   | 1 000  | +1 000      | `Staking`    | `"Convex"`   | `["Staking", "Curve LP", "crvUSD/USDC"]`     |
| CRV    | 100    | +50         | `Rewards`    | `"Convex"`   | `["Staking", "Curve LP", "crvUSD/USDC"]`     |
| CVX    | 50     | +150        | `Rewards`    | `"Convex"`   | `["Staking", "Curve LP", "crvUSD/USDC"]`     |
| **NAV** | | **+2 200** | | | |

#### `UniswapV3PoolsMeta`

Scenario: one NFT position (#12345) in the USDC/WETH 0.05% pool, in-range, with 20 USDC + 0.008 WETH in accrued fees.

| asset | amount  | value (USD) | positionKind | positionInstanceId | protocolName   | labels  |
|-------|---------|-------------|--------------|--------------------|----------------|----------------|
| USDC  | 600     | +600        | `Supplied`   | `12345`            | `"Uniswap V3"` | `["AMM Liquidity Pool", "USDC/WETH 0.05%"]` |
| WETH  | 0.24    | +600        | `Supplied`   | `12345`            | `"Uniswap V3"` | `["AMM Liquidity Pool", "USDC/WETH 0.05%"]` |
| USDC  | 20      | +20         | `Fees`       | `12345`            | `"Uniswap V3"` | `["AMM Liquidity Pool", "USDC/WETH 0.05%"]` |
| WETH  | 0.008   | +20         | `Fees`       | `12345`            | `"Uniswap V3"` | `["AMM Liquidity Pool", "USDC/WETH 0.05%"]` |
| **NAV** | | **+1 240** | | | | |

(positionId for all four legs = `abi.encode(0x88e6…5640)`, the USDC/WETH 0.05% pool; the NFT id lives only in the typed `positionInstanceId`.)

#### `UniswapV2PoolsMeta`

Scenario: wallet holds USDC/WETH V2 pair LP representing 700 USDC + 0.28 WETH.

| asset | amount | value (USD) | positionKind | protocolName   | labels     |
|-------|--------|-------------|--------------|----------------|-------------------|
| USDC  | 700    | +700        | `Supplied`   | `"Uniswap V2"` | `["AMM Liquidity Pool", "USDC/WETH"]`  |
| WETH  | 0.28   | +700        | `Supplied`   | `"Uniswap V2"` | `["AMM Liquidity Pool", "USDC/WETH"]`  |
| **NAV** | | **+1 400** | | | |

#### `PancakeSwapV3PoolsMeta` / `PancakeSwapV2PoolsMeta`

Same structure as UniswapV3/V2 respectively; `protocolName` = `"PancakeSwap V3"` / `"PancakeSwap V2"`.

---

## `protocolSubId` — which protocol

`protocolSubId` is `keccak256` of a canonical ASCII slug. A single slug maps to exactly one
`positionId` ABI-decode schema, so you can switch on `protocolSubId` and know exactly how to
decode `positionId` without any runtime sniffing. (The broader `protocolBrand` and `protocolId`
fields are roll-ups for display / grouping and are NOT part of the identity key.)

All constants live in [`src/utils/ProtocolIds.sol`](../../src/utils/ProtocolIds.sol).

```solidity
bytes32 protocolSubId = keccak256("aave-v3-lending");  // == ProtocolIds.AAVE_V3_LENDING
```

### Every `protocolSubId` — slug, constant, and what it identifies

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
| `gearbox-v3-markets` | `GEARBOX_V3_MARKETS` | `GearboxV3MarketsMetaBalanceAdapter` — Gearbox V3 passive-pool deposit |
| `gearbox-v3-credit-accounts` | `GEARBOX_V3_CREDIT_ACCOUNTS` | `GearboxV3CreditAccountsMetaBalanceAdapter` — Gearbox V3 credit-account collateral/debt |
| `compound-v3-comets` | `COMPOUND_V3_COMETS` | `CompoundV3CometsMetaBalanceAdapter` — Compound V3 Comet base/collateral/rewards |
| `fluid-ftokens` | `FLUID_FTOKENS` | `FluidFTokensMetaBalanceAdapter` — Fluid fToken (ERC4626) lending supply |
| `fluid-vaults` | `FLUID_VAULTS` | `FluidVaultsMetaBalanceAdapter` — Fluid T1 vault collateral/borrow |
| `balancer-v3-pools` | `BALANCER_V3_POOLS` | `BalancerV3PoolsMetaBalanceAdapter` — wallet-held Balancer V3 LP |
| `balancer-v3-gauges` | `BALANCER_V3_GAUGES` | `BalancerV3GaugesMetaBalanceAdapter` — gauge-staked Balancer V3 LP + rewards |
| `balancer-v2-pools` | `BALANCER_V2_POOLS` | `BalancerV2PoolsMetaBalanceAdapter` — wallet-held Balancer V2 LP |
| `balancer-v2-gauges` | `BALANCER_V2_GAUGES` | `BalancerV2GaugesMetaBalanceAdapter` — gauge-staked Balancer V2 LP + rewards |
| `curve-pools` | `CURVE_POOLS` | `CurvePoolsMetaBalanceAdapter` — wallet-held Curve LP |
| `curve-gauges` | `CURVE_GAUGES` | `CurveGaugesMetaBalanceAdapter` — gauge-staked Curve LP + rewards |
| `convex-curve-lp-staking` | `CONVEX_CURVE_LP_STAKING` | `ConvexCurveLPStakingMetaBalanceAdapter` — Convex-staked Curve LP + CRV/CVX/extra rewards |
| `uniswap-v3` | `UNISWAP_V3` | `UniswapV3PoolsMetaBalanceAdapter` — Uniswap V3 LP NFT liquidity + fees |
| `uniswap-v2` | `UNISWAP_V2` | `UniswapV2PoolsMetaBalanceAdapter` — Uniswap V2 LP |
| `pancakeswap-v3` | `PANCAKESWAP_V3` | `PancakeSwapV3PoolsMetaBalanceAdapter` — PancakeSwap V3 LP NFT liquidity + fees |
| `pancakeswap-v2` | `PANCAKESWAP_V2` | `PancakeSwapV2PoolsMetaBalanceAdapter` — PancakeSwap V2 LP |
| `stakewise-v3-vaults` | `STAKEWISE_V3_VAULTS` | `StakeWiseV3VaultsMetaBalanceAdapter` — StakeWise V3 vault stake + osToken debt |
| `nexus-mutual-staking-pools` | `NEXUS_MUTUAL_STAKING_POOLS` | `NexusMutualStakingPoolsAssistedBalanceAdapter` — Nexus Mutual StakingNFT stake + rewards |
| `cap` | `CAP` | `CapBalanceAdapter` — Cap cUSD (held) and stcUSD (staked) |
| `merkl` | `MERKL` | Reserved Merkl-rewards slug — no live adapter on `main` (the former `MerklRewardsAssistedBalanceAdapter` was removed; re-add pending). Would emit unclaimed (claimable) Merkl reward tokens |
| `lido-withdrawal` | `LIDO_WITHDRAWAL` | `LidoWithdrawalQueueBalanceAdapter` — ETH owed from the Lido stETH withdrawal queue |
| `stader-withdrawal` | `STADER_WITHDRAWAL` | `StaderWithdrawalQueueBalanceAdapter` — ETH owed from the Stader ETHx withdrawal queue |
| `kelp-withdrawal` | `KELP_WITHDRAWAL` | `KelpWithdrawalQueueBalanceAdapter` — assets owed from the Kelp rsETH exit queue |
| `etherfi-withdrawal` | `ETHERFI_WITHDRAWAL` | `EtherFiWithdrawalQueueAssistedBalanceAdapter` — ETH owed from the ether.fi eETH withdrawal queue |
| `stakewise-v3-exit` | `STAKEWISE_V3_EXIT` | `StakeWiseV3ExitQueueAssistedBalanceAdapter` — assets owed from the StakeWise V3 exit queue |
| `erc4626` | `ERC4626` | Reserved generic ERC4626 wrapper slug — no live adapter on `main` (the former `ERC4626WrapperBalanceAdapter` was removed) |
| `ethena-cooldown` | `ETHENA_COOLDOWN` | `EthenaCooldownBalanceAdapter` — USDe in the sUSDe unstaking cooldown |
| `bridge-escrow` | `BRIDGE_ESCROW` | `BridgeEscrow` (bridge layer, **not** a balance adapter) — funds in flight across a bridge |

Every slug maps to exactly one `positionId` schema — see the next section. Slugs are stable and
version-qualified (`-v2` / `-v3`); a protocol upgrade that changes the position shape gets a new slug
rather than overloading an existing one.

---

## `positionId` — which instance

`positionId` is `abi.encode(...)` of the position's stable key. The exact schema depends on
`protocolSubId` — one slug, one schema. Full table:

| `protocolSubId` slug | `positionId` = `abi.encode(...)` |
|---|---|
| `wallet` | `(address asset)` |
| `aave-v3-lending` | `(address pool)` |
| `spark-lend` | `(address pool)` |
| `aave-v3-safety-module` | `(address stakeToken)` — both staking legs (locked active stake + unlocked in-window cooldown) and the reward leg share it; told apart by `isLocked` and `positionKind` |
| `aave-v3-umbrella` | `(address stakeToken)` — both staking legs (locked active stake + unlocked in-window cooldown) and the reward leg share it; told apart by `isLocked` and `positionKind` |
| `morpho-vaults` | `(address vault)` |
| `morpho-markets` | `(bytes32 marketId)` |
| `euler-vaults` | `(address vault)` |
| `gearbox-v3-markets` | `(address market)` |
| `gearbox-v3-credit-accounts` | `(address creditAccount)` |
| `compound-v3-comets` | `(address comet)` |
| `fluid-ftokens` | `(address fToken)` |
| `fluid-vaults` | `(address vault)` |
| `balancer-v3-pools` | `(address pool)` |
| `balancer-v3-gauges` | `(address gauge)` |
| `balancer-v2-pools` | `(bytes32 poolId)` |
| `balancer-v2-gauges` | `(address gauge)` |
| `curve-pools` | `(address pool)` |
| `curve-gauges` | `(address gauge)` |
| `convex-curve-lp-staking` | `(address rewarder)` |
| `uniswap-v3` | `(address pool)` — NFT id in `positionInstanceId` |
| `uniswap-v2` | `(address pair)` |
| `pancakeswap-v3` | `(address pool)` — NFT id in `positionInstanceId` |
| `pancakeswap-v2` | `(address pair)` |
| `stakewise-v3-vaults` | `(address vault)` |
| `cap` | `(address token)` — cUSD or stcUSD |
| `erc4626` | `(address vault)` |
| `merkl` | `(address distributor)` — reward token in balanceAsset |
| `nexus-mutual-staking-pools` | `(address stakingPool)` — NFT id in `positionInstanceId` |
| `stader-withdrawal` | `(address userWithdrawalManager)` — static; up to two legs (claimable + locked) sharing it, told apart by `isLocked` |
| `kelp-withdrawal` | `(address withdrawalManager)` — static; up to two legs (claimable + locked) sharing it, told apart by `isLocked`; payout asset in `balanceAsset` |
| `lido-withdrawal` | `(address withdrawalQueue)` — static; up to two legs (claimable + locked) sharing it, told apart by `isLocked` |
| `etherfi-withdrawal` | `(address withdrawRequestNFT)` — static; up to two legs (claimable + locked) sharing it, told apart by `isLocked` |
| `stakewise-v3-exit` | `(address vault)` — static, per vault; claimable (exited) + locked (queued) legs sharing it, told apart by `isLocked` |
| `ethena-cooldown` | `(address sUSDe)` — static; single cooldown leg, `isLocked` while still cooling |
| `bridge-escrow` | `(address escrow, address token)` |

**Static positionId, claimable/locked split.** Withdrawal / exit queues and the Ethena
cooldown use a static, timeless positionId — the immutable anchor (queue / manager / vault /
sUSDe / asset), never a per-request id. They split an account's holding into up to two legs
(a claimable leg `isLocked=false` and a pending/locked leg `isLocked=true`) that **share** that
positionId and one stable key — `isLocked` is a per-leg attribute (NOT part of the key), so the two
legs are summed in reconciliation. The Aave SM / Umbrella
staking-with-cooldown adapters follow the same model: both staking legs share one
`abi.encode(address stakeToken)` (no discriminator), distinguished by `isLocked` (active stake is
non-withdrawable ⇒ locked; only a cooldown elapsed-and-in-window is unlocked), and the reward leg
shares it too, told apart by `positionKind`. Per-request ids (NFT / ticket / nonce) are not in any
positionId — they ride in the typed, ephemeral `positionInstanceId` field. Note: `wallet` positions are
NOT account-global — each uses `abi.encode(asset)` to identify the specific token.

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
    protocolSubId,
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
    [chainId, position.protocolSubId, position.positionId, position.balanceAsset.asset, position.positionKind]
));
```

`isLocked` is a per-leg attribute, NOT part of the key: the claimable (`isLocked=false`) and locked
(`isLocked=true`) legs share a static `positionId` AND one key (the withdrawal-queue / cooldown /
staking-with-cooldown adapters), so they are summed in reconciliation.

**The key identifies a position _group_, not necessarily a single emitted leg.** Adapters that emit
one leg per underlying item emit **multiple legs that share the same full key**, distinguished only by
the ephemeral `positionInstanceId` (never part of the key):
- the withdrawal queues — **one leg per open request** (Lido / Stader / Kelp / ether.fi / StakeWise
  V3); the request id (ERC721 request id / `userNonce` / cached tokenId / `positionTicket`) is the
  `positionInstanceId`;
- the NFT-position adapters — **one leg per NFT** (Uniswap V3 / PancakeSwap V3 / Nexus Mutual);
  the NFT id is the `positionInstanceId`.

This is by design: the per-item id is ephemeral (a withdrawal request is burned on claim; an LP/stake
NFT can be transferred or burned), so it is never put in `positionId`. **Consumers reconciling at the
position level must SUM amounts across legs that share the key** — this is exactly what NAV does, so
the on-chain total is always correct; only a consumer that _upserts_ (deduplicates) by the key would
collapse those legs and under-count. Consumers needing per-item granularity read `positionInstanceId`.

**Excluded from the key by design:**
- `balanceAdapter` — provenance only; redeploying an adapter doesn't change the position
- `isDebt` — the canonical NAV-sign field; read it directly, do not infer it from `positionKind`
- `protocolBrand` / `protocolId` — display / grouping roll-ups; the key uses `protocolSubId`
- `positionInstanceId` — the ephemeral per-item id; appending it yields per-item granularity at the
  cost of a key that blinks in/out as items are minted / burned / claimed

---

## Adapter reference — positionId decode and legs

The summary table below and the TypeScript examples cover the primary balance adapters; the
exhaustive per-adapter matrix (including the withdrawal / cooldown and assisted adapters) is the
*Complete per-adapter schema* section further down. All
decodes use `AbiCoder.defaultAbiCoder()` from ethers.js. Protocol ID constants come from
`ProtocolIds.sol` (`keccak256(toUtf8Bytes("<slug>"))`).

### PositionKind summary per adapter

| Adapter | `protocolSubId` slug | Legs emitted (`PositionKind`) |
|---|---|---|
| `ERC20DefaultBalanceAdapter` | `wallet` | `Wallet` |
| `AaveV3InstancesMeta` | `aave-v3-lending` | `Supplied`, `Collateral`, `Borrowed` |
| `SparkLend` | `spark-lend` | `Supplied`, `Collateral`, `Borrowed` |
| `AaveV3SafetyModule` | `aave-v3-safety-module` | `Staking`, `Rewards` |
| `AaveUmbrella` | `aave-v3-umbrella` | `Staking`, `Rewards` |
| `MorphoVaultsMeta` | `morpho-vaults` | `Supplied` |
| `MorphoMarketsMeta` | `morpho-markets` | `Collateral`, `Supplied`, `Borrowed` |
| `EulerVaultsMeta` | `euler-vaults` | `Supplied`, `Collateral`, `Borrowed` |
| `GearboxV3MarketsMeta` | `gearbox-v3-markets` | `Supplied` |
| `FluidFTokensMeta` | `fluid-ftokens` | `Supplied` |
| `FluidVaultsMeta` | `fluid-vaults` | `Collateral`, `Borrowed` |
| `CompoundV3CometsMeta` | `compound-v3-comets` | `Supplied`, `Borrowed`, `Collateral`, `Rewards` |
| `StakeWiseV3VaultsMeta` | `stakewise-v3-vaults` | `Staking`, `Borrowed` |
| `BalancerV3PoolsMeta` | `balancer-v3-pools` | `Supplied` |
| `BalancerV3GaugesMeta` | `balancer-v3-gauges` | `Staking`, `Rewards` |
| `BalancerV2PoolsMeta` | `balancer-v2-pools` | `Supplied` |
| `BalancerV2GaugesMeta` | `balancer-v2-gauges` | `Staking`, `Rewards` |
| `CurvePoolsMeta` | `curve-pools` | `Supplied` |
| `CurveGaugesMeta` | `curve-gauges` | `Staking`, `Rewards` |
| `ConvexCurveLPStakingMeta` | `convex-curve-lp-staking` | `Staking`, `Rewards` |
| `UniswapV3PoolsMeta` / `PancakeSwapV3PoolsMeta` | `uniswap-v3` / `pancakeswap-v3` | `Supplied`, `Fees` |
| `UniswapV2PoolsMeta` / `PancakeSwapV2PoolsMeta` | `uniswap-v2` / `pancakeswap-v2` | `Supplied` |
| `Cap` | `cap` | `Supplied` (cUSD), `Staking` (stcUSD) |
| `NexusMutualStakingPoolsAssistedBalanceAdapter` | `nexus-mutual-staking-pools` | `Staking`, `Rewards` |
| `LidoWithdrawalQueue` | `lido-withdrawal` | `Supplied` (one leg per request; `isLocked` = pending; request id in `positionInstanceId`) |
| `StaderWithdrawalQueue` | `stader-withdrawal` | `Supplied` (one leg per request; `isLocked` = pending; request id in `positionInstanceId`) |
| `KelpWithdrawalQueue` | `kelp-withdrawal` | `Supplied` (one leg per request per asset; `isLocked` = pending; `userNonce` in `positionInstanceId`) |

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

Per-market positionId: one positionId per market (`bytes32 marketId`); the collateral, loan-supply,
and loan-borrow legs of that market share it.

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

#### Gearbox V3 — `gearbox-v3-markets`

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

#### Compound V3 — `compound-v3-comets`

```typescript
const [comet] = abi.decode(["address"], pos.positionId);
// comet — Comet market (e.g. cUSDCv3, cWETHv3)
// Supplied    → base-token supply
// Borrowed    → base-token borrow
// Collateral  → individual collateral asset legs
// Rewards     → COMP rewards (claimable)
```

#### StakeWise V3 — `stakewise-v3-vaults`

```typescript
const [vault] = abi.decode(["address"], pos.positionId);
// vault — StakeWise V3 ERC4626-like vault
// Staking  → vault shares → underlying (ETH / GNO)
// Borrowed → minted osToken debt → underlying equivalent
```

#### Balancer V3 Pools — `balancer-v3-pools`

```typescript
const [pool] = abi.decode(["address"], pos.positionId);
// pool — Balancer V3 pool / BPT address
// Supplied → one leg per pool token (wallet-held, unstaked BPT)
```

#### Balancer V3 Gauges — `balancer-v3-gauges`

```typescript
const [gauge] = abi.decode(["address"], pos.positionId);
// gauge — Balancer V3 liquidity gauge
// Staking  → one leg per pool token (gauge-staked BPT share)
// Rewards  → BAL + extra reward token legs
```

#### Balancer V2 Pools — `balancer-v2-pools`

The instance coordinate IS the raw bytes32 poolId (not an address). The BPT address is its
top 160 bits.

```typescript
const [poolId] = abi.decode(["bytes32"], pos.positionId);
const bpt = "0x" + poolId.slice(2, 42);          // top 20 bytes of poolId
// Supplied → one leg per underlying pool token (wallet-held BPT)
```

#### Balancer V2 Gauges — `balancer-v2-gauges`

```typescript
const [gauge] = abi.decode(["address"], pos.positionId);
// gauge — Balancer V2 liquidity gauge (child or root)
// Staking  → one leg per pool token (gauge-staked BPT share)
// Rewards  → BAL + extra reward token legs
```

#### Curve Pools — `curve-pools`

```typescript
const [pool] = abi.decode(["address"], pos.positionId);
// pool — Curve pool address (also LP token for classic/TriCryptoNG pools)
// Supplied → one leg per registered pool coin (wallet-held LP, pro-rata)
```

#### Curve Gauges — `curve-gauges`

```typescript
const [gauge] = abi.decode(["address"], pos.positionId);
// gauge — Curve liquidity gauge
// Staking  → one leg per pool coin (staked LP share, pro-rata)
// Rewards  → CRV (lower-bound) + extra reward token legs
```

#### Convex — `convex-curve-lp-staking`

```typescript
const [rewarder] = abi.decode(["address"], pos.positionId);
// rewarder — Convex BaseRewardPool address
// Staking  → one leg per underlying Curve pool coin (staked LP, pro-rata)
// Rewards  → CRV, CVX, and extra reward token legs
```

#### Uniswap V3 / PancakeSwap V3 — `uniswap-v3` / `pancakeswap-v3`

Per-pool positionId: positionId is the pool contract address (`factory.getPool(token0,token1,fee)` —
each fee tier is its own pool). An account's multiple NFTs in the same pool share this positionId; the
specific NFT id is the typed, ephemeral `pos.positionInstanceId` on each leg. All legs of one NFT
(token0/token1 liquidity + fees) share the positionId.

```typescript
const [pool] = abi.decode(["address"], pos.positionId);
// pool — the Uniswap/PancakeSwap V3 pool contract (identifies token pair + fee tier)
// The NFT id is the typed pos.positionInstanceId (a uint256 widened to bytes32), not in positionId.
// Supplied → in-range liquidity (token0 and token1 legs)
// Fees     → unclaimed fee legs (token0 and token1)

// To act on a specific NFT, recover the tokenId from positionInstanceId:
const tokenId = BigInt(pos.positionInstanceId);
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

Reserved generic slug for a plain ERC4626 wrapper share token. The `ERC4626` constant exists in
`ProtocolIds.sol`, but no adapter on `main` currently emits positions under it (the former
`ERC4626WrapperBalanceAdapter` was removed).

```typescript
const [wrapper] = abi.decode(["address"], pos.positionId);
// wrapper — ERC4626 share token (e.g. an Aave stata-token or sGHO)
// Supplied → convertToAssets(balanceOf(account)) in wrapper.asset()
```

#### Merkl rewards — `merkl`

```typescript
const [distributor] = abi.decode(["address"], pos.positionId);
// distributor — the Merkl Distributor (claim target); the reward token is in balanceAsset.asset
// Rewards → unclaimed allocation (proof-cached; may be stale between proof updates)
```

#### Nexus Mutual staking pools — `nexus-mutual-staking-pools`

```typescript
const [stakingPool] = abi.decode(["address"], pos.positionId);
// stakingPool — the Nexus staking-pool contract (StakingViewer.stakingPool(poolId)).
// The StakingNFT id is the typed pos.positionInstanceId, not in positionId.
// One Staking (active + expired stake) and one Rewards leg per StakingNFT, both NXM-denominated.
// An account may hold several positions across several pools.
```

#### Lido / Stader / Kelp withdrawal queues — `lido-withdrawal` / `stader-withdrawal` / `kelp-withdrawal`

```typescript
const [anchor] = abi.decode(["address"], pos.positionId);
// positionId = abi.encode(<anchor>) — STATIC; the same value for all of an account's legs in this queue.
//   anchor = withdrawalQueue (Lido) / userWithdrawalManager (Stader) / LRTWithdrawalManager (Kelp)
// Supplied → up to two legs sharing this positionId: a claimable leg (pos.isLocked === false) and a
//   pending/locked leg (pos.isLocked === true). Sum both for the total owed; read pos.isLocked to
//   route Claim vs wait. Per-request detail (the NFT / nonce) is the typed pos.positionInstanceId.
// balanceAsset is the underlying paid on claim: native ETH sentinel for Lido,
//   WETH for Stader, and the LST asset (e.g. stETH) for Kelp — all set per-deploy via UNDERLYING_TOKEN
```

---

## Human-readable labels — `IPositionDescribable` and verbose reads

The typed fields are for machines. For human-readable display there is a **single mechanism**:
the two `IPositionDescribable` methods — `protocolName()` and `positionLabels(positionId)`. Labels
are NOT carried on `PositionBalance`; they are derived **lazily from `positionId`** and surfaced only
in the verbose reads, so the display work stays off the NAV hot path.

### `IPositionDescribable` (on each adapter)

```solidity
interface IPositionDescribable {
    function protocolName() external view returns (string memory); // "Aave V3", "Morpho", …
    function positionLabels(bytes calldata positionId) external view returns (string[] memory);
}
```

`protocolName()` is a constant per adapter. `positionLabels(positionId)` returns the ordered,
arbitrary-depth display hierarchy BELOW the protocol (leaf last, e.g. `["Market", "wstETH/USDC"]`),
derived purely from `positionId` — the ephemeral per-item id rides in `PositionBalance.positionInstanceId`,
not in the labels. Meta-adapters derive the leaf on-chain from live state (ERC20 symbols, vault names,
pool composition) and use the `_labels(category, leaf)` helper, which drops an empty leaf so a failed
read degrades to `[category]`; per-instance adapters return a fixed array. NAVCalculator's verbose
reads call both methods via a **fail-open staticcall** — an adapter that does not implement the
interface simply yields an empty protocol name / label set.

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

`protocolName` comes from each adapter's `IPositionDescribable.protocolName()`; `labels` comes from
`IPositionDescribable.positionLabels(position.positionId)`. The full breadcrumb is
`[protocolName, ...labels]`. If an adapter doesn't implement `IPositionDescribable`, both `protocolName`
and `labels` are empty.
**Never use these strings for identity, indexing, or reconciliation** — they are display-only and may
change as labels evolve.

### Complete per-adapter schema

The single source of truth tying together everything above — `protocolSubId`, `protocolName()`, the
`positionLabels(positionId)` breadcrumb, the `positionId` ABI schema, the `PositionKind`
legs, and a worked example — for every balance adapter on `main`.

- **Full breadcrumb** = `[protocolName(), ...positionLabels(positionId)]`; the **leaf** is the last element.
- **`protocolSubId`** column is the `keccak256` slug (constants in [`src/utils/ProtocolIds.sol`](../../src/utils/ProtocolIds.sol)).
- **Leaf source:** `const` = hardcoded literal · `derived` = read live from chain · `gov` = constructor arg.
  No leaf is governance-fed today; for meta-adapters only `protocolName()` (the breadcrumb root, marked ¹)
  is a constructor arg, the category is a `const` literal, and the leaf is `derived` on-chain. Meta-adapters
  use a `_labels(category, leaf)` helper that **drops an empty leaf**, so a failed read degrades to `[category]`.
- Labels are returned by `positionLabels(positionId)`; the ephemeral per-item id (request / NFT / ticket)
  is **not** a label — it is the typed `PositionBalance.positionInstanceId`.

#### Plain adapters (`src/balances/BalanceAdapters/`)

| Adapter | `protocolSubId` | `protocolName()` | `positionLabels()` → (source) | `positionId` schema | `PositionKind` legs | Example breadcrumb |
|---|---|---|---|---|---|---|
| `ERC20DefaultBalanceAdapter` | `wallet` | `"Wallet"` | `[<symbol>]` (derived); `["native"]`; `[]` on revert | `abi.encode(address asset)` | Wallet | `["Wallet","USDC"]` |
| `AaveUmbrellaBalanceAdapter` | `aave-v3-umbrella` | `"Aave Umbrella"` | `["Umbrella Module"]` (const) | `abi.encode(address stakeToken)` | Staking / Rewards | `["Aave Umbrella","Umbrella Module"]` |
| `AaveV3SafetyModuleBalanceAdapter` | `aave-v3-safety-module` | `"Aave V3"` | `["Safety Module"]` (const) | `abi.encode(address stakeToken)` | Staking / Rewards | `["Aave V3","Safety Module"]` |
| `CapBalanceAdapter` (cUSD) | `cap` | `"Cap"` | `["Stablecoin","cUSD"]` (const) | `abi.encode(address CUSD)` | Supplied | `["Cap","Stablecoin","cUSD"]` |
| `CapBalanceAdapter` (stcUSD) | `cap` | `"Cap"` | `["Savings","stcUSD"]` (const) | `abi.encode(address STCUSD)` | Staking | `["Cap","Savings","stcUSD"]` |
| `EthenaCooldownBalanceAdapter` | `ethena-cooldown` | `"Ethena"` | `["Unstaking Cooldown"]` (const) | `abi.encode(address sUSDe)` | Supplied (`isLocked` while cooling) | `["Ethena","Unstaking Cooldown"]` |
| `SparkLendBalanceAdapter` | `spark-lend` | `"Spark"` | `["Market","SparkLend"]` (const) | `abi.encode(address POOL)` | Collateral/Supplied / Borrowed | `["Spark","Market","SparkLend"]` |
| `LidoWithdrawalQueueBalanceAdapter` | `lido-withdrawal` | `"Lido"` | `["Withdrawal Queue", "stETH"]` (const) | `abi.encode(address withdrawalQueue)` | Supplied — one leg **per request** (each `isLocked` = pending), shared positionId, request id in `positionInstanceId` | `["Lido","Withdrawal Queue","stETH"]` |
| `StaderWithdrawalQueueBalanceAdapter` | `stader-withdrawal` | `"Stader"` | `["Withdrawal Queue", "ETHx"]` (const) | `abi.encode(address userWithdrawalManager)` | Supplied — one leg **per request** (each `isLocked` = pending), shared positionId, request id in `positionInstanceId` | `["Stader","Withdrawal Queue","ETHx"]` |
| `KelpWithdrawalQueueBalanceAdapter` | `kelp-withdrawal` | `"Kelp DAO"` | `["Withdrawal Queue", "rsETH"]` (const) | `abi.encode(address withdrawalManager)` | Supplied — one leg **per request** per asset (each `isLocked` = pending), shared positionId, request id in `positionInstanceId` | `["Kelp DAO","Withdrawal Queue","rsETH"]` |

#### Meta-adapters (`src/balances/MetaBalanceAdapters/`)

`protocolName()` is a constructor arg (¹). Default `positionId` = base `_instancePositionId` (instance
address widened → `abi.encode(address instance)`); overrides are flagged.

| Adapter | `protocolSubId` | `protocolName()`¹ | `positionLabels()` → (source) | `positionId` schema | `PositionKind` legs | Example breadcrumb |
|---|---|---|---|---|---|---|
| `AaveV3InstancesMetaBalanceAdapter` | `aave-v3-lending` | `"Aave V3"` | `["Market", <getMarketId()>]` (derived) | `abi.encode(address pool)` (computed inline) | Collateral/Supplied / Borrowed | `["Aave V3","Market","Aave Ethereum Market"]` |
| `CompoundV3CometsMetaBalanceAdapter` | `compound-v3-comets` | `"Compound V3"` | `["Market", <comet.name()>]` (derived) | `abi.encode(address comet)` | Supplied/Borrowed / Collateral / Rewards | `["Compound V3","Market","cUSDCv3"]` |
| `ConvexCurveLPStakingMetaBalanceAdapter` | `convex-curve-lp-staking` | `"Convex"` | `["Staking", "Curve LP", "<coins>"]` (derived) | `abi.encode(address rewarder)` | Staking / Rewards | `["Convex","Staking","Curve LP","DAI/USDC/USDT"]` |
| `EulerVaultsMetaBalanceAdapter` | `euler-vaults` | `"Euler"` | `["Vault", <vault.name()>]` (derived) | `abi.encode(address vault)` | Collateral/Supplied / Borrowed | `["Euler","Vault","eUSDC"]` |
| `FluidFTokensMetaBalanceAdapter` | `fluid-ftokens` | `"Fluid"` | `["Lending", <fToken.symbol()>]` (derived) | `abi.encode(address fToken)` | Supplied | `["Fluid","Lending","fUSDC"]` |
| `FluidVaultsMetaBalanceAdapter` | `fluid-vaults` | `"Fluid"` | `["Vault", "<collateral>/<debt> #<vaultId>"]` (derived) | `abi.encode(address vault)` | Collateral / Borrowed | `["Fluid","Vault","wstETH/USDC #4"]` |
| `GearboxV3MarketsMetaBalanceAdapter` | `gearbox-v3-markets` | `"Gearbox"` | `["Market", <market.name()>]` (derived) | `abi.encode(address market)` | Supplied | `["Gearbox","Market","dDAI"]` |
| `GearboxV3CreditAccountsMetaBalanceAdapter` | `gearbox-v3-credit-accounts` | `"Gearbox"` | `["Credit Account", <creditManager.name() / underlying symbol>]` (derived) | `abi.encode(address creditAccount)` | Collateral / Borrowed | `["Gearbox","Credit Account","USDC v3"]` |
| `MorphoMarketsMetaBalanceAdapter` | `morpho-markets` | `"Morpho"` | `["Market", "<coll>/<loan>"]` (derived) | **override** `abi.encode(bytes32 marketId)` (raw) | Collateral / Supplied / Borrowed | `["Morpho","Market","wETH/USDC"]` |
| `MorphoVaultsMetaBalanceAdapter` | `morpho-vaults` | `"Morpho"` | `["Vault", <vault.name()>]` (derived) | `abi.encode(address vault)` | Supplied | `["Morpho","Vault","Morpho DAI"]` |
| `StakeWiseV3VaultsMetaBalanceAdapter` | `stakewise-v3-vaults` | `"StakeWise V3"` | `["Vault"]` (category only) | `abi.encode(address vault)` | Staking / Borrowed (osToken) | `["StakeWise V3","Vault"]` |
| `BalancerV2PoolsMetaBalanceAdapter` | `balancer-v2-pools` | `"Balancer V2"` | `["AMM Liquidity Pool", <BPT.name()>]` (derived) | **override** `abi.encode(bytes32 poolId)` (raw) | Supplied | `["Balancer V2","AMM Liquidity Pool","50WETH-50USDC"]` |
| `BalancerV2GaugesMetaBalanceAdapter` | `balancer-v2-gauges` | `"Balancer V2"` | `["Staking Gauge", <gauge.symbol()>]` (derived) | `abi.encode(address gauge)` | Staking / Rewards | `["Balancer V2","Staking Gauge","…-gauge"]` |
| `BalancerV3PoolsMetaBalanceAdapter` | `balancer-v3-pools` | `"Balancer V3"` | `["AMM Liquidity Pool", <pool.name()>]` (derived) | `abi.encode(address pool)` | Supplied | `["Balancer V3","AMM Liquidity Pool","Balancer 50 WETH 50 USDC"]` |
| `BalancerV3GaugesMetaBalanceAdapter` | `balancer-v3-gauges` | `"Balancer V3"` | `["Staking Gauge", <gauge.symbol()>]` (derived) | `abi.encode(address gauge)` | Staking / Rewards | `["Balancer V3","Staking Gauge","…-gauge"]` |
| `CurvePoolsMetaBalanceAdapter` | `curve-pools` | `"Curve"` | `["AMM Liquidity Pool", "<coins>"]` (derived) | `abi.encode(address pool)` | Supplied | `["Curve","AMM Liquidity Pool","USDC/USDT/DAI"]` |
| `CurveGaugesMetaBalanceAdapter` | `curve-gauges` | `"Curve"` | `["Staking Gauge", "<coins>"]` (derived) | `abi.encode(address gauge)` | Staking / Rewards | `["Curve","Staking Gauge","USDC/USDT/DAI"]` |
| `UniswapV2PoolsMetaBalanceAdapter` | `uniswap-v2` | `"Uniswap V2"` | `["AMM Liquidity Pool", "<sym0>/<sym1>"]` (derived) | `abi.encode(address pair)` | Supplied | `["Uniswap V2","AMM Liquidity Pool","WETH/USDC"]` |
| `UniswapV3PoolsMetaBalanceAdapter` | `uniswap-v3` | `"Uniswap V3"` | `["AMM Liquidity Pool", "<sym0>/<sym1> <fee>%"]` (derived) | `abi.encode(address pool)` | Supplied / Fees | `["Uniswap V3","AMM Liquidity Pool","USDC/WETH 0.05%"]` |
| `PancakeSwapV2PoolsMetaBalanceAdapter` | `pancakeswap-v2` | `"PancakeSwap V2"` | `["AMM Liquidity Pool", "<sym0>/<sym1>"]` (derived, inherited) | `abi.encode(address pair)` | Supplied | `["PancakeSwap V2","AMM Liquidity Pool","WBNB/BUSD"]` |
| `PancakeSwapV3PoolsMetaBalanceAdapter` | `pancakeswap-v3` | `"PancakeSwap V3"` | `["AMM Liquidity Pool", "<sym0>/<sym1> <fee>%"]` (derived, inherited) | `abi.encode(address pool)` | Supplied / Fees | `["PancakeSwap V3","AMM Liquidity Pool","CAKE/WBNB 0.25%"]` |

#### Assisted adapters (`src/balances/AssistedBalanceAdapters/`)

| Adapter | `protocolSubId` | `protocolName()` | `positionLabels()` → (source) | `positionId` schema | `PositionKind` legs | Example breadcrumb |
|---|---|---|---|---|---|---|
| `EtherFiWithdrawalQueueAssistedBalanceAdapter` | `etherfi-withdrawal` | `"ether.fi"` (const) | `["Withdrawal Queue", "eETH"]` (const) | `abi.encode(address withdrawRequestNFT)` | Supplied — one leg **per request** (cached NFT tokenId in `positionInstanceId`; each `isLocked` = pending), shared positionId | `["ether.fi","Withdrawal Queue","eETH"]` |
| `StakeWiseV3ExitQueueAssistedBalanceAdapter` | `stakewise-v3-exit` | `"StakeWise V3"` (const) | `["Exit Queue", <receiptSymbol>]` (derived) | `abi.encode(address vault)` (per vault) | Supplied — **per request (ticket)** with the `positionTicket` in `positionInstanceId`, up to two legs (claimable + still-queued) sharing the per-vault positionId | `["StakeWise V3","Exit Queue","osETH"]` |
| `NexusMutualStakingPoolsAssistedBalanceAdapter` | `nexus-mutual-staking-pools` | `"Nexus Mutual"` (const) | `["Staking Pools", "Pool #<id>"]` (derived) | `abi.encode(address stakingPool)` | Staking / Rewards | `["Nexus Mutual","Staking Pools","Pool #5"]` |

(`MerklRewardsAssistedBalanceAdapter` was removed from `main` and is not listed here; the `merkl` slug is reserved for its pending re-add — see the note in the `protocolSubId` table above.)

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
| `address market` (Gearbox) | The Gearbox V3 pool contract (an ERC4626 "diesel" pool, e.g. `dUSDC`) for `gearbox-v3-markets`. |
| `address creditAccount` (Gearbox) | A Gearbox V3 credit account for `gearbox-v3-credit-accounts`; all its legs (collateral / borrow) share it. |
| `bytes32 marketId` (Morpho) | Morpho's `Id` for one isolated market — `keccak256` of the market params `(loanToken, collateralToken, oracle, irm, lltv)`. **Raw `bytes32`, not an address.** Collateral, supply and borrow legs of the market share it. |
| `address stakeToken` | The Aave staking-token contract: a Safety Module `stk*` token (stkAAVE / stkGHO / stkABPT) or an Aave Umbrella stake token. All legs share it — both staking legs (locked active stake + unlocked in-window cooldown, told apart by `isLocked`) and the claimable-rewards leg (told apart by `positionKind`). |
| `address CUSD` / `address STCUSD` | The Cap protocol's cUSD (synthetic dollar) or stcUSD (staked cUSD / savings) token contract — one per leg, so the two legs carry different addresses. |
| `address wrapper` | The generic ERC4626 wrapper share token the adapter was deployed for (e.g. `waEthLidoGHO`, `sGHO`). Distinct deployments carry distinct wrapper addresses. |
| `address pair` | The **Uniswap V2 / PancakeSwap V2 pool contract**, which is *also* the LP (liquidity-provider) ERC20 token — in V2 the pair contract and its LP token are the same address. token0/token1 legs share it. |
| `address pool` (Balancer V3 / Curve) | The liquidity-pool contract: a Balancer V3 pool (also its BPT token) or a Curve pool. Per-coin `Supplied` legs share it. |
| `bytes32 poolId` (Balancer V2) | The Balancer V2 Vault `poolId` — the pool's 32-byte id used by the Balancer `Vault` (the first 20 bytes are the pool address). **Raw `bytes32`, not an address** (Balancer V2 keys pools by id, not address). |
| `address gauge` | The staking **gauge** contract (Balancer V2/V3 or Curve) the LP is staked into. Staked principal and claimable reward legs share it. |
| `address rewarder` (Convex) | The Convex `BaseRewardPool` ("rewarder") for that Curve LP. The underlying Curve pool, its coins and the CRV/CVX/extra rewards are derived from it. |
| `address pool` (Uniswap V3 / PancakeSwap V3) | The Uniswap/PancakeSwap **V3 pool contract** (`factory.getPool(token0, token1, fee)`) — each fee tier is its own deployed pool, so the address identifies the token pair + fee tier. Keyed per pool; an account's NFTs in the same pool share it, and the four legs (token0/token1 × liquidity/fees) share it. The specific NFT id is **not** in positionId — it is the typed `positionInstanceId`. |
| `address stakingPool` (Nexus) | The Nexus Mutual **staking-pool contract** (`StakingViewer.stakingPool(poolId)`, deterministic per poolId). Staking and reward legs (both NXM) share it. The `StakingNFT` id is the typed `positionInstanceId`, not in positionId. |
| `address DISTRIBUTOR` (Merkl) | The Merkl `Distributor` (Angle Labs) — the claim target / trust anchor. All reward tokens claimed from it share this id and are told apart by `balanceAsset`. |
| `address withdrawalQueue` (Lido) | Lido's `WithdrawalQueueERC721` — the contract that escrows stETH withdrawal requests and pays out ETH on claim. Static; claimable + locked legs share it. |
| `address userWithdrawalManager` (Stader) | Stader's `UserWithdrawalManager` — escrows ETHx unstake requests, pays ETH (valued to WETH) on claim. Static; claimable + locked legs share it. |
| `address withdrawalManager` (Kelp) | Kelp DAO's `LRTWithdrawalManager` — escrows rsETH exit requests and pays out the requested asset on claim. Static; the payout asset (e.g. stETH) is in `balanceAsset`, not the positionId. Claimable + locked legs share it. |
| `address withdrawRequestNFT` (ether.fi) | ether.fi's `WithdrawRequestNFT` — the ERC721 that represents eETH withdrawal requests and is the claim target. Static; claimable + locked legs share it. |
| `address vault` (StakeWise) | The StakeWise V3 vault the exit position belongs to; positionId is keyed per vault. Static; claimable (exited) + locked (queued) legs of that vault share it. (The adapter's `VaultsRegistry` gates which vaults the cache accepts, but is not the positionId.) |
| `address sUSDe` (Ethena) | Ethena's `StakedUSDeV2` (sUSDe) — the staking contract that holds the unstaking cooldown and is the claim target; the owed USDe is in `balanceAsset`. Static; single leg, `isLocked` while cooling. |

For the withdrawal / exit queue and cooldown adapters (Lido, Stader, Kelp, ether.fi, StakeWise V3
exit, Ethena) the encoded value is a **static, timeless** coordinate (the queue/manager/vault/sUSDe)
— never a per-request id. Each splits an account's holding into up to
two legs (claimable `isLocked=false` + locked `isLocked=true`) that share that positionId; the owed/payout asset is in `balanceAsset`.

**Multi-leg rule.** Where an adapter emits several legs (lending supply/borrow/collateral; gauge
stake/rewards; Uniswap V3 liquidity/fees; StakeWise vault/osToken-debt), all legs **share one
`positionId` and one label set** — they are distinguished by `positionKind` and, for per-token legs, by
`balanceAsset.asset` (the underlying token), never by extra label elements.

**Withdrawal-queue / cooldown adapters.** The withdrawal/exit queues (Lido, Stader, Kelp, ether.fi,
StakeWise V3) and the Ethena cooldown use a **static, timeless** `positionId` — the immutable anchor
(queue/manager/vault or sUSDe) — never a per-request id. They split an
account's holding into up to two legs that share that positionId: a claimable leg (`isLocked=false`)
and a pending/locked leg (`isLocked=true`); the two legs share one key and `isLocked` is a per-leg
attribute (NOT part of the key), so they are summed in reconciliation. The owed
asset lives in `balanceAsset.asset`. No adapter emits an empty `positionId`.

---

## Adding a new adapter

When implementing a new balance adapter:

1. Add the slug(s) to [`src/utils/ProtocolIds.sol`](../../src/utils/ProtocolIds.sol) and document the
   `positionId` schema in its NatSpec comment. Set `protocolBrand` / `protocolId` / `protocolSubId`
   per the three-level taxonomy (the per-product `protocolSubId` is what selects the schema and joins
   the key; reuse the same constant for the broader two when the protocol is unversioned / single-product).
2. Choose a `positionId` encoding: `abi.encode(primaryKey)` where `primaryKey` is the most
   specific stable on-chain address or identifier for this adapter instance. Any ephemeral per-item id
   (NFT / request / ticket) goes in the typed `positionInstanceId`, never in `positionId`.
3. Assign `positionKind` per leg:
   - Lending supply (freely withdrawable) → `Supplied`
   - Lending supply as collateral → `Collateral`
   - Debt → `Borrowed`
   - Vault shares, LP principal → `Supplied`
   - Staking principal → `Staking`
   - Unclaimed reward tokens → `Rewards`
   - Uncollected LP/protocol fees → `Fees`
   - ERC20 wallet balance → `Wallet`
4. Provide human-readable labels by implementing both `IPositionDescribable` methods:
   - `protocolName()` — static `pure` string for per-instance adapters; the same constant (constructor
     arg) for meta-adapters
   - `positionLabels(bytes positionId)` — return a `string[]` hierarchy below the protocol, leaf last,
     derived from `positionId`. Derive on-chain for meta-adapters (read token symbols, vault/pool names)
     via the `_labels(category, leaf)` helper; a fixed array for per-instance adapters. Labels are NOT
     carried on `PositionBalance` — they are computed lazily in the verbose reads.
5. Update the tables above and the `ProtocolIds` schema comment.

See [`howto/add-balance-adapter.md`](add-balance-adapter.md) for the full end-to-end recipe.
