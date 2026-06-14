# How to add a new balance adapter

End-to-end walkthrough. Read [`/CLAUDE.md`](../../CLAUDE.md) and [`../onboarding-claude.md`](../onboarding-claude.md) first if you have not.

The framework reference is [`src/balances/BALANCE_ADAPTERS.md`](../../src/balances/BALANCE_ADAPTERS.md). This doc is the *recipe*; that doc is the *spec*.

Throughout, replace `MyProtocol` with your protocol name. Pick a name that's stable, recognizable, and matches the on-chain protocol identity (e.g., `SparkLend`, `GearboxMarkets`, `BalancerV3Pools`).

---

## 0. Decide what the adapter reports

Before writing code, answer:

| Question | Why it matters |
|---|---|
| Which **assets** does this adapter report on? | Drives `underlyingAssetsSupported()`. List them as token addresses. |
| For each asset, is the position a **credit** (supply, stake, LP) or **debt** (borrow)? | Drives `isDebt`. Each `PositionBalance` is "asset + amount + isDebt". |
| Does the protocol have **multiple instances** (one per pool/market/vault)? | Two routes — see "Per-instance vs meta-adapter" below. |
| Is there a **canonical underlying asset** (e.g., what the position is denominated in when valued)? | Adapters return amounts in the underlying token's decimals. The price registry will price the underlying. |
| Are there **rewards** that should count toward NAV? | If yes, the adapter must include them as additional `PositionBalance` entries with the reward token as the underlying asset. |

**Rule of thumb:** the adapter is a *view*. It reads protocol state and translates it into `PositionBalance[]`. It does not price, sign, or aggregate; NAVCalculator does that.

### Per-instance vs meta-adapter

If the protocol has **many fungible instances** (Morpho vaults/markets, Balancer pools/gauges, Aave instances, Uniswap V3/V2 pools), prefer a **meta-adapter** over one contract per instance:

- **Per-instance** (the default skeleton below): pin the pool/market/vault address in the constructor. One deployed contract per instance. Right for singletons (DAI DSR, a withdrawal queue, SparkLend) or one-off adapters with unusual constructor args.
- **Meta-adapter** (`IMetaBalanceAdapter` / `MetaBalanceAdapter`): one immutable contract for *all* instances of the protocol; the active set is configured on NAVCalculator via `setMetaInstances` (a `MANAGER` TX), not by deploying more contracts. Extend `MetaBalanceAdapter` and implement `_instancePositions(account, instance, assetFilter)` + `_instanceAssets(instance)`. Optionally override `_instancePositionId(bytes32 instance)` to customise positionId encoding — the default is `abi.encode(_toAddress(instance))` (address-keyed protocols); override with `abi.encode(instance)` for raw-bytes32 coordinates (Morpho marketIds, Balancer V2 poolIds); adapters where positionId varies per leg (Aave V3/V2 per-reserve, Uniswap V3 per-NFT) skip the hook and build positionId inline. Adding a pool/vault later is a config TX, not a deploy. See `GearboxMarketsMeta.sol`, §6.1 of `src/balances/BALANCE_ADAPTERS.md`, and [ADR 0010](../decisions/0010-meta-balance-adapters.md). Meta-adapters still take **no admin functions** — the governed state lives on NAVCalculator.

Today 21 meta-adapters cover all major multi-instance protocols (Aave V2/V3, Compound V3, Morpho Vaults/Markets, Gearbox, Balancer V2/V3 pools + gauges, Aura, Curve pools + gauges, Convex, Fluid fTokens + Vaults, StakeWise V3, Uniswap V2/V3, PancakeSwap V2/V3). For a new multi-instance protocol, a meta-adapter is almost always the right choice.

---

## 1. Write the adapter contract

File: `src/balances/protocols/<MyProtocol>.sol` (single-file) or `src/balances/protocols/<protocol>/<MyProtocol>.sol` (multi-file).

### 1.1 Identity pattern

Every `PositionBalance` now carries typed identity fields instead of free-form strings:

| Field | Type | What to put |
|---|---|---|
| `protocolId` | `bytes32` | A constant from `src/utils/ProtocolIds.sol` — `keccak256` of a lowercase kebab-case slug. Add a new constant if needed (see §1.2). |
| `positionId` | `bytes` | `abi.encode(keyAddress)` or `abi.encode(a, b)` computed at query time. See the schema comments in `ProtocolIds.sol` for the canonical shape per protocol family. |
| `positionKind` | `PositionKind` | Enum from `src/utils/PositionKind.sol`: `Wallet`, `Supplied`, `Borrowed`, `Collateral`, `Staking`, `Rewards`, or `Fees`. |

### 1.2 Adding a new ProtocolIds constant

If no existing constant fits your protocol, add one to `src/utils/ProtocolIds.sol`:

```solidity
bytes32 internal constant MY_PROTOCOL = keccak256("my-protocol-v1");
```

Slug rules: lowercase ASCII, kebab-case, include the major version. Document the `positionId` ABI-encode schema in the NatSpec block at the top of the file.

### 1.3 Per-instance adapter skeleton

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

contract MyProtocolBalanceAdapter is IBalanceAdapter, IPositionDescribable {
    /// @notice The protocol contract this adapter reads from.
    address public immutable PROTOCOL_CONTRACT;

    /// @notice NAVCalculator (asset registry source).
    INAVCalculator public immutable NAV_CALCULATOR;

    bytes32 private constant PROTOCOL_ID = ProtocolIds.MY_PROTOCOL;

    constructor(address protocolContract_, address navCalculator_) {
        if (protocolContract_ == address(0) || navCalculator_ == address(0)) revert InvalidArguments();
        require(protocolContract_.code.length > 0, "Protocol contract must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        PROTOCOL_CONTRACT = protocolContract_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    // ─── IERC165 ─────────────────────────────────────────────────────────────

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId
            || interfaceId == type(IPositionDescribable).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // ─── IPositionDescribable ─────────────────────────────────────────────────

    /// @inheritdoc IPositionDescribable
    function protocolName() external pure returns (string memory) {
        return "My Protocol";
    }

    /// @inheritdoc IPositionDescribable
    /// @dev `positionId` is `abi.encode(protocolContract, asset)`.
    function describePosition(bytes calldata positionId) external view returns (string memory) {
        // Decode and return a human-readable label, e.g. from an ERC20 symbol call.
        // Return "" if it cannot be derived.
        if (positionId.length < 32) return "";
        (, address asset) = abi.decode(positionId, (address, address));
        try IERC20Metadata(asset).symbol() returns (string memory s) {
            return string.concat(s, " supply");
        } catch {
            return "";
        }
    }

    // ─── IBalanceAdapter ────────────────────────────────────────────────

    function underlyingAssetsSupported() external view returns (address[] memory) {
        // Return the deduplicated list of assets this adapter reports on.
    }

    function getAdapterBalanceForAsset(address account, address asset)
        external view returns (uint256 amount, bool isDebt)
    {
        // Single-asset path. Return (0, false) for unsupported assets or zero account.
    }

    function getAdapterBalances(address account)
        external view returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        // Iterate underlyingAssetsSupported(); include only non-zero amounts.
    }

    function getAdapterPositions(address account, address assetFilter)
        external view returns (INAVCalculator.PositionBalance[] memory positions)
    {
        // Filter by registered + supported assets, build PositionBalance entries.
        // positionId is computed here, not stored. For a two-leg example see SparkLend.sol.
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        // ... intersection, loop, build entries:
        // positions[n++] = INAVCalculator.PositionBalance({
        //     balanceAsset: assetMeta,
        //     balanceAdapter: address(this),
        //     amount: supplyAmount,
        //     isDebt: false,
        //     protocolId: PROTOCOL_ID,
        //     positionId: abi.encode(PROTOCOL_CONTRACT, asset),
        //     positionKind: PositionKind.Supplied
        // });
    }
}
```

Reuse patterns from existing adapters:

- **Per-instance, multi-asset (supply + borrow legs):** `src/balances/protocols/SparkLend.sol`.
- **Per-instance, single-asset vault:** `src/balances/protocols/Cap.sol`, `src/balances/protocols/DaiDsr.sol`.
- **Meta-adapter, single-leg:** `src/balances/protocols/GearboxMarketsMeta.sol`, `src/balances/protocols/MorphoVaultsMeta.sol`.
- **Meta-adapter, multi-leg (LP + rewards):** `src/balances/protocols/curve/CurveGaugesMeta.sol`, `src/balances/protocols/balancer/BalancerV3GaugesMeta.sol`.

Conventions:

- All addresses set in the constructor are **immutable**. No setters.
- `protocolId` is a `bytes32` constant declared at the class level (`bytes32 private constant PROTOCOL_ID = ProtocolIds.MY_PROTOCOL`). It is never a constructor param.
- `positionId` is computed at query time via `abi.encode(...)`. It is never stored. The encode schema must match the NatSpec in `ProtocolIds.sol` for this protocol family.
- `positionKind` is a `PositionKind` enum value (`Wallet`, `Supplied`, `Borrowed`, `Collateral`, `Staking`, `Rewards`, `Fees`). It is never a string.
- `amount` in `PositionBalance` is **always positive**. Use `isDebt = true` to mark debt.
- `balanceAdapter` is always `address(this)`. It is the audit trail.
- For asset metadata on the `PositionBalance.balanceAsset` field, call `NAV_CALCULATOR.getRegisteredAssets()` and only emit positions for assets present in that list.
- Use a **minimal interface** for each external protocol call — declare it at the bottom of the file (or in a sibling `I<Protocol>.sol`). Do not import the protocol's full library.
- Implement `IPositionDescribable` (`protocolName()` pure, `describePosition(bytes)` view). NAVCalculator's verbose read methods call these via try/catch, so they are non-breaking, but implementing them gives clients useful labels for free.

---

## 2. Tests

Two files, both required for review.

### 2.1 Unit test (mocks only)

File: `test/balances/protocols/<MyProtocol>.t.sol`.

Cover:

- Constructor: zero-address guards, non-contract guards.
- `supportsInterface` returns true for `IBalanceAdapter` and `IERC165`, false otherwise.
- `getAdapterBalanceForAsset` returns `(0, false)` for zero account, zero asset, unsupported asset.
- `getAdapterBalances` returns empty arrays for zero account.
- `getAdapterPositions` returns empty for zero account; respects `assetFilter`.
- Non-registered assets (per `NAV_CALCULATOR.getRegisteredAssets()`) are dropped from `getAdapterPositions`.
- `PositionBalance` fields: assert `protocolId == ProtocolIds.MY_PROTOCOL`, `positionKind == PositionKind.Supplied` (or appropriate), and `positionId == abi.encode(...)` with the expected bytes.

Use `MockNAVCalculator` (grep for `MockNAVCalculator` in the test tree) and a thin mock of the protocol contract.

### 2.2 Fork test (real protocol)

File: `test/balances/protocols/fork/<MyProtocol>.fork.t.sol`.

Cover:

- Deploy the adapter against the **real** protocol contract on a pinned block + chain.
- Pick a real holder with a non-trivial position; assert the returned balance is within a reasonable range of an off-chain reference (e.g., the protocol's own UI or a CSV check).
- Reward accrual: time-warp with `vm.warp(block.timestamp + 1 days)` and confirm rewards increase (where applicable).
- Asset registry filtering: confirm positions for assets *not* registered with NAVCalculator are dropped.

Pin the block in the test:

```solidity
function setUp() public {
    vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 21_395_285);
    // ...
}
```

Run with `FOUNDRY_PROFILE=slow` to throttle RPC.

---

## 3. Wire chain config

File: `script/config/chains/<chainId>.json`.

Add an entry under `balanceAdapters`. For a **per-instance adapter** the constructor block lists only the protocol-specific addresses the adapter needs:

```json
"MyProtocol": {
  "enabled": true,
  "constructor": {
    "protocolContract": "0x..."
  },
  "deployed": ""
}
```

For a **meta-adapter**, add a `metaInstances` array (the instance coordinates passed to `setMetaInstances` on NAVCalculator). The constructor block lists only chain-level constants (the protocol's global contracts). For example, the Gearbox meta-adapter:

```json
"GearboxMarketsMeta": {
  "enabled": true,
  "constructor": {
    "protocol": "Gearbox"
  },
  "metaInstances": [
    "0x9396DCbf78fc526bb003665337C5E73b699571EF",
    "0xA9d17f6D3285208280a1Fd9B94479c62e0AABa64"
  ],
  "deployed": ""
}
```

Notes:

- The key (`MyProtocol` or `MyProtocol_<instance>`) is the lookup name used by `04_DeployBalanceAdapters.s.sol`.
- For multi-instance per-instance adapters, use an instance disambiguator in the key (`AaveV3_Core`, `AaveV3_Prime`).
- For chains where the protocol does not exist, set `"enabled": false` or omit the key.
- The `navCalculator` param is **not** listed in `constructor` — the deploy script resolves it automatically from the deployed NAVCalculatorProxy address.

---

## 4. Wire the deploy script

File: `script/deploy/04_DeployBalanceAdapters.s.sol`.

Add a `_deployMyProtocol` helper that reads only the protocol-specific constructor addresses. No string identity params:

```solidity
function _deployMyProtocol(string memory adapterName, address navCalculator) internal returns (address) {
    address protocolContract = vm.parseAddress(
        ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocolContract")
    );
    MyProtocolBalanceAdapter adapter = new MyProtocolBalanceAdapter(protocolContract, navCalculator);
    return address(adapter);
}
```

Then add a dispatch entry inside `_deployAdapter`:

```solidity
if (_equals(adapterName, "MyProtocol") || _startsWith(adapterName, "MyProtocol_")) {
    return _deployMyProtocol(adapterName, navCalculator);
}
```

And a `_deployIfEnabled("MyProtocol")` call in `run()`.

For a **meta-adapter**, the helper typically only reads a `protocol` string (the human-readable name passed to the `MetaBalanceAdapter` base constructor) plus any chain-global contract addresses the constructor needs. See `_deployGearboxMarketsMeta` or `_deploySparkLend` in the same file for concrete patterns.

---

## 5. Deploy and register

The full deploy ordering is in [`../../script/deploy/README.md`](../../script/deploy/README.md). For a new adapter on an existing chain:

```bash
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --chain-id <chainId> \
  --account $DEPLOYER_NAME \
  --broadcast
```

`04` writes the deployed address back into `script/config/chains/<chainId>.json` under `balanceAdapters.MyProtocol.deployed`. Verify it's there before opening the PR.

Registration: the OIV Safe calls `NAVCalculator.addBalanceAdapter(adapter)` via the `06_Configure.s.sol` Safe TX bundle. For meta-adapters, the same bundle also calls `setMetaInstances(adapter, instances[])` to wire the active instance set.

Then verify on-chain:

```bash
cast call $NAVCalculator "isAdapterRegistered(address)(bool)" $adapter --rpc-url $RPC
```

---

## 6. Refresh integration test snapshots

If your adapter affects NAV for an existing test account in `test/integration/accounts.json` (or you're adding a new test account that exercises it), run the bump script before opening the PR:

```bash
script/test/refresh-integration-snapshot.sh
```

This regenerates the expected `navUsd8dp` values, optionally cross-checks against DeBank, and updates `accounts.json` in place. Don't edit the per-chain `NAV.<Chain>.integration.fork.t.sol` files directly. Full walkthrough: [`./refresh-integration-test-blocks.md`](./refresh-integration-test-blocks.md).

## 7. Open the PR

PR checklist:

- [ ] `forge build` clean
- [ ] `forge test --match-path "test/balances/protocols/MyProtocol*"` clean
- [ ] `FOUNDRY_PROFILE=slow forge test --match-path "test/balances/protocols/fork/MyProtocol*"` clean
- [ ] Chain config updated for every chain where the adapter applies
- [ ] If a new `ProtocolIds` constant was added, it is documented in the NatSpec block of `src/utils/ProtocolIds.sol`
- [ ] No unrelated files committed (run `git status` before staging)
- [ ] PR description includes: protocol name, what the adapter reports, the chain(s) it's enabled on, any reward semantics, and the fork-test holder address used as ground truth
- [ ] If the adapter changes NAV for an integration-test account, ran `script/test/refresh-integration-snapshot.sh` and committed the resulting `test/integration/accounts.json` diff

If you're touching the deployment lifecycle (new chain, new role, new migration), also update or add the relevant ADR under [`../decisions/`](../decisions/).
