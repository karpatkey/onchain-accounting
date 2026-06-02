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
| `sky-savings` | `""` (account-global) |
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

## Decoding `positionId` — worked examples

### Aave V3 supply/borrow

```typescript
import { AbiCoder, keccak256, toUtf8Bytes } from "ethers";

const AAVE_V3_LENDING = keccak256(toUtf8Bytes("aave-v3-lending"));
const abi = AbiCoder.defaultAbiCoder();

function decodeAaveV3(pos) {
  if (pos.protocolId !== AAVE_V3_LENDING) throw new Error("wrong protocol");
  const [pool, reserve] = abi.decode(["address", "address"], pos.positionId);
  return { pool, reserve };
}

// Action routing from identity:
if (pos.positionKind === PositionKind.Borrowed) {
  await pool.repay(reserve, pos.amount, 2 /* variable */, account);
} else if (pos.positionKind === PositionKind.Supplied || pos.positionKind === PositionKind.Collateral) {
  await pool.withdraw(reserve, pos.amount, account);
}
```

### Uniswap V3 LP + fees

```typescript
const UNISWAP_V3 = keccak256(toUtf8Bytes("uniswap-v3"));

function decodeUniV3(pos) {
  const [npm, tokenId] = abi.decode(["address", "uint256"], pos.positionId);
  return { npm, tokenId };
}

// Both the LP principal (Supplied) and the fee legs (Earned) share the same
// positionId — same NFT, different kind:
const { npm, tokenId } = decodeUniV3(pos);
if (pos.positionKind === PositionKind.Earned) {
  await npmContract.collect({ tokenId, recipient: account, amount0Max, amount1Max });
}
```

### Morpho market

```typescript
const MORPHO_MARKETS = keccak256(toUtf8Bytes("morpho-markets"));

function decodeMorphoMarket(pos) {
  const [marketId] = abi.decode(["bytes32"], pos.positionId);
  return { marketId };
}
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
