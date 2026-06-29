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

- **Per-instance** (the default skeleton below): pin the pool/market/vault address in the constructor. One deployed contract per instance. Right for singletons (a savings vault, a withdrawal queue, SparkLend) or one-off adapters with unusual constructor args.
- **Meta-adapter** (`IMetaBalanceAdapter` / `MetaBalanceAdapter`): one immutable contract for *all* instances of the protocol; the active set is configured on NAVCalculator via `addMetaInstances`/`removeMetaInstances` (a `MANAGER` TX), not by deploying more contracts. Extend `MetaBalanceAdapter` and implement `_instancePositions(account, instance, assetFilter)` + `_instanceAssets(instance)`. Optionally override `_instancePositionId(bytes32 instance)` to customise positionId encoding — the default is `abi.encode(_toAddress(instance))` (address-keyed protocols); override with `abi.encode(instance)` for raw-bytes32 coordinates (Morpho marketIds, Balancer V2 poolIds); adapters where positionId varies per leg (Aave V3 per-reserve, Uniswap V3 per-NFT) skip the hook and build positionId inline. Adding a pool/vault later is a config TX, not a deploy. See `GearboxMarketsMetaBalanceAdapter.sol`, §6.1 of `src/balances/BALANCE_ADAPTERS.md`, and [ADR 0010](../decisions/0010-meta-balance-adapters.md). Meta-adapters still take **no admin functions** — the governed state lives on NAVCalculator.

Today 20 meta-adapters cover all major multi-instance protocols (Aave V3, Compound V3, Morpho Vaults/Markets, Euler V2, Gearbox, Balancer V2/V3 pools + gauges, Curve pools + gauges, Convex, Fluid fTokens + Vaults, StakeWise V3, Uniswap V2/V3, PancakeSwap V2/V3). For a new multi-instance protocol, a meta-adapter is almost always the right choice.

---

## 1. Write the adapter contract

File: `src/balances/<family>/<MyProtocol>.sol`, where `<family>` is `BalanceAdapters` (plain), `MetaBalanceAdapters` (multi-instance), or `AssistedBalanceAdapters` (externally-fed). Multi-file protocols keep a `<protocol>/` subdir inside the family folder.

### 1.1 Identity pattern

Every `PositionBalance` now carries typed identity fields instead of free-form strings:

| Field | Type | What to put |
|---|---|---|
| `protocolId` | `bytes32` | A constant from `src/utils/ProtocolIds.sol` — `keccak256` of a lowercase kebab-case slug. Add a new constant if needed (see §1.2). |
| `positionId` | `bytes` | `abi.encode(keyAddress)` or `abi.encode(a, b)` computed at query time, of the **static, timeless** key (never a per-request id). See the schema comments in `ProtocolIds.sol` for the canonical shape per protocol family. |
| `positionKind` | `PositionKind` | Enum from `src/utils/PositionKind.sol`: `Wallet`, `Supplied`, `Borrowed`, `Collateral`, `Staking`, `Rewards`, or `Fees`. |
| `isLocked` | `bool` | `true` if the leg is not withdrawable now (pending withdrawal / unstaking cooldown); `false` if liquid. `false` for most adapters. Withdrawal-queue / cooldown adapters split a holding into a claimable (`false`) and a locked (`true`) leg sharing one static `positionId` — `isLocked` is part of the identity key. |

### 1.2 Adding a new ProtocolIds constant

If no existing constant fits your protocol, add one to `src/utils/ProtocolIds.sol`:

```solidity
bytes32 internal constant MY_PROTOCOL = keccak256("my-protocol-v1");
```

Slug rules: lowercase ASCII, kebab-case, include the major version. Document the `positionId` ABI-encode schema in the NatSpec block at the top of the file.

### 1.3 Per-instance adapter skeleton

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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
        // positionId is computed here, not stored. For a two-leg example see SparkLendBalanceAdapter.sol.
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        // ... intersection, loop, build entries:
        // positions[n++] = INAVCalculator.PositionBalance({
        //     balanceAsset: assetMeta,
        //     balanceAdapter: address(this),
        //     amount: supplyAmount,
        //     isDebt: false,
        //     protocolId: PROTOCOL_ID,
        //     positionId: abi.encode(PROTOCOL_CONTRACT, asset),
        //     positionKind: PositionKind.Supplied,
        //     isLocked: false,  // true only for the pending leg of a withdrawal queue / cooldown
        //     positionInstanceId: bytes32(0)  // ephemeral per-item coordinate (NFT/request id); bytes32(0) if none
        // });
    }

    /// @dev Display hierarchy that sits below `protocolName()` (leaf last), derived on-chain from `positionId`
    ///      (ERC20 symbols, vault/pool names, etc.). Verbose-only, gas-capped — display, never identity.
    function positionLabels(bytes calldata positionId) external view returns (string[] memory out) {
        // Decode `positionId`, read the relevant on-chain name(s)/symbol(s), return [category, leaf].
        out = new string[](2);
        out[0] = "Supplied";
        out[1] = "<derived leaf>";
    }
}
```

Reuse patterns from existing adapters:

- **Per-instance, multi-asset (supply + borrow legs):** `src/balances/BalanceAdapters/SparkLendBalanceAdapter.sol`.
- **Per-instance, single-asset vault:** `src/balances/BalanceAdapters/CapBalanceAdapter.sol`.
- **Meta-adapter, single-leg:** `src/balances/MetaBalanceAdapters/GearboxMarketsMetaBalanceAdapter.sol`, `src/balances/MetaBalanceAdapters/MorphoVaultsMetaBalanceAdapter.sol`.
- **Meta-adapter, multi-leg (LP + rewards):** `src/balances/MetaBalanceAdapters/curve/CurveGaugesMetaBalanceAdapter.sol`, `src/balances/MetaBalanceAdapters/balancer/BalancerV3GaugesMetaBalanceAdapter.sol`.

Conventions:

- All addresses set in the constructor are **immutable**. No setters.
- `protocolId` is a `bytes32` constant declared at the class level (`bytes32 private constant PROTOCOL_ID = ProtocolIds.MY_PROTOCOL`). It is never a constructor param.
- `positionId` is computed at query time via `abi.encode(...)`. It is never stored. The encode schema must match the NatSpec in `ProtocolIds.sol` for this protocol family.
- `positionKind` is a `PositionKind` enum value (`Wallet`, `Supplied`, `Borrowed`, `Collateral`, `Staking`, `Rewards`, `Fees`). It is never a string.
- `amount` in `PositionBalance` is **always positive**. Use `isDebt = true` to mark debt.
- `balanceAdapter` is always `address(this)`. It is the audit trail.
- For asset metadata on the `PositionBalance.balanceAsset` field, call `NAV_CALCULATOR.getRegisteredAssets()` and only emit positions for assets present in that list.
- Use a **minimal interface** for each external protocol call — declare it at the bottom of the file (or in a sibling `I<Protocol>.sol`). Do not import the protocol's full library.
- Implement `protocolName()` **and** `positionLabels(bytes positionId)` from `IPositionDescribable`. `positionLabels` returns a `string[]` display hierarchy below `protocolName` (leaf last), derived on-chain from the `positionId` (ERC20 symbols, vault/pool names, etc.). It is a lazy, verbose-only, gas-capped read off the NAV hot path (NAVCalculator's verbose views call it); display-only, never identity. The per-item ephemeral coordinate (NFT/request id) rides in `PositionBalance.positionInstanceId`, not in labels.

---

## 2. Tests

Two files, both required for review.

### 2.1 Unit test (mocks only)

File: `test/balances/<family>/<MyProtocol>.t.sol`.

Cover:

- Constructor: zero-address guards, non-contract guards.
- `supportsInterface` returns true for `IBalanceAdapter`, `IPositionDescribable`, and `IERC165`, false otherwise.
- `getAdapterBalanceForAsset` returns `(0, false)` for zero account, zero asset, unsupported asset.
- `getAdapterBalances` returns empty arrays for zero account.
- `getAdapterPositions` returns empty for zero account; respects `assetFilter`.
- Non-registered assets (per `NAV_CALCULATOR.getRegisteredAssets()`) are dropped from `getAdapterPositions`.
- `PositionBalance` fields: assert `protocolId == ProtocolIds.MY_PROTOCOL`, `positionKind == PositionKind.Supplied` (or appropriate), and `positionId == abi.encode(...)` with the expected bytes.

Use `Mock_NAVCalculator` (in `test/mocks/nav_calculator.sol`) and a thin mock of the protocol contract.

### 2.2 Fork test (real protocol)

File: `test/balances/<family>/fork/<MyProtocol>.fork.t.sol`.

Cover:

- Deploy the adapter against the **real** protocol contract on a pinned block + chain.
- Pick a real holder with a non-trivial position; assert the returned balance is within a reasonable range of an off-chain reference (e.g., the protocol's own UI or a CSV check).
- Reward accrual: time-warp with `vm.warp(block.timestamp + 1 days)` and confirm rewards increase (where applicable).
- Asset registry filtering: confirm positions for assets *not* registered with NAVCalculator are dropped.

Extend `BalanceAdapterTestBase` (in `test/balances/BalanceAdapterTestBase.fork.sol`) and pin the block via the shared `getAlchemyUrl` / `createForkWithCadence` helpers from `test/TestEnvConfigurator.sol`:

```solidity
contract MyProtocolBalanceAdapterForkTest is BalanceAdapterTestBase {
    uint256 public constant FORK_BLOCK = 21_395_285;

    function setUp() public override {
        super.setUp();
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        // ...
    }
}
```

Run with `FOUNDRY_PROFILE=slow` to throttle RPC.

---

## 3. Wire chain config

Config is split by concern. **Deploy config** (constructor args, read by `04_DeployBalanceAdapters.s.sol`) lives in `script/config/contracts-deployment-config/balance-adapters/<chainId>.json` for plain adapters, or `script/config/contracts-deployment-config/meta-balance-adapters/<chainId>.json` for meta adapters. **NAV registration** (read by `06_Configure.s.sol`) lives in `script/config/nav-config/balance-adapters/<chainId>.json` for plain adapters, or `script/config/nav-config/meta-balance-adapters/<chainId>.json` for meta adapters. Each file's top-level keys are the adapter names — the filename is the chain.

### 3.1 Deploy config

For a **per-instance adapter**, add the constructor block (only the protocol-specific / chain-level addresses the adapter needs — no instances here) to `contracts-deployment-config/balance-adapters/<chainId>.json`:

```json
{
  "MyProtocol": {
    "enabled": true,
    "constructor": {
      "protocolContract": "0x..."
    }
  }
}
```

For a **meta-adapter**, add the constructor block (only chain-level constants — the protocol's global contracts) to `contracts-deployment-config/meta-balance-adapters/<chainId>.json`:

```json
{
  "GearboxMarketsMeta": {
    "enabled": true,
    "constructor": {
      "protocol": "Gearbox"
    }
  }
}
```

### 3.2 NAV registration — plain adapter

Add the name to `nav-config/balance-adapters/<chainId>.json`:

```json
{
  "MyProtocol": { "enabled": true }
}
```

`06_Configure` adds these via `addBalanceAdapters`.

### 3.3 NAV registration — meta adapter

Add the name to `nav-config/meta-balance-adapters/<chainId>.json` with its `instances` array (the instance coordinates applied via `addMetaInstances`/`removeMetaInstances` on NAVCalculator). Use `instancesRaw` instead when the coordinates are raw `bytes32` (Morpho marketIds, Balancer V2 poolIds) rather than addresses:

```json
{
  "GearboxMarketsMeta": {
    "enabled": true,
    "instances": [
      "0x9396DCbf78fc526bb003665337C5E73b699571EF",
      "0xA9d17f6D3285208280a1Fd9B94479c62e0AABa64"
    ]
  }
}
```

Instances are applied incrementally — `06_Configure` registers the meta-adapter via `addMetaBalanceAdapter`, then diffs the configured set against on-chain state and calls `addMetaInstances`/`removeMetaInstances` as needed.

Notes:

- The key (`MyProtocol` or `MyProtocol_<instance>`) is the lookup name used by `04_DeployBalanceAdapters.s.sol`; the same key must appear in the matching `nav-config` file to register on NAV.
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

`04` writes the deployed address into `script/config/deployments/<chainId>.json` under `balanceAdapters.MyProtocol`. Verify it's there before opening the PR.

Registration: `06_Configure.s.sol` registers each adapter on NAVCalculator. Plain adapters listed in `nav-config/balance-adapters/<chainId>.json` are added via `addBalanceAdapters(adapters)`; meta adapters listed in `nav-config/meta-balance-adapters/<chainId>.json` are registered via `addMetaBalanceAdapter(adapter, instances[])` (or the `instancesRaw` variant) and have their active instance set reconciled with `addMetaInstances`/`removeMetaInstances`. Meta-vs-plain is also confirmed on-chain via ERC165.

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
- [ ] `forge test --match-path "test/balances/<family>/MyProtocol*"` clean
- [ ] `FOUNDRY_PROFILE=slow forge test --match-path "test/balances/<family>/fork/MyProtocol*"` clean
- [ ] Chain config updated for every chain where the adapter applies
- [ ] If a new `ProtocolIds` constant was added, it is documented in the NatSpec block of `src/utils/ProtocolIds.sol`
- [ ] No unrelated files committed (run `git status` before staging)
- [ ] PR description includes: protocol name, what the adapter reports, the chain(s) it's enabled on, any reward semantics, and the fork-test holder address used as ground truth
- [ ] If the adapter changes NAV for an integration-test account, ran `script/test/refresh-integration-snapshot.sh` and committed the resulting `test/integration/accounts.json` diff

If you're touching the deployment lifecycle (new chain, new role, new migration), also update or add the relevant ADR under [`../decisions/`](../decisions/).
