# How to add a new balance adapter

End-to-end walkthrough. Read [`/CLAUDE.md`](../../CLAUDE.md) and [`../onboarding-claude.md`](../onboarding-claude.md) first if you have not.

The framework reference is [`src/balances/BALANCE_ADAPTERS.md`](../../src/balances/BALANCE_ADAPTERS.md). This doc is the *recipe*; that doc is the *spec*.

Throughout, replace `MyProtocol` with your protocol name. Pick a name that's stable, recognizable, and matches the on-chain protocol identity (e.g., `SparkLend`, `GearboxV3Markets`, `BalancerV3Pools`).

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

If the protocol has **many fungible instances** (Morpho vaults/markets, Balancer pools/gauges, Aave instances, Uniswap/PancakeSwap V2 pairs), prefer a **meta-adapter** over one contract per instance:

- **Per-instance** (the default skeleton below): pin the pool/market/vault address in the constructor. One deployed contract per instance. Right for singletons (a savings vault, a withdrawal queue, SparkLend) or one-off adapters with unusual constructor args.
- **Meta-adapter** (`IMetaBalanceAdapter` / `MetaBalanceAdapter`): one immutable contract for *all* instances of the protocol; the active set is configured on NAVCalculator via `addMetaInstances`/`removeMetaInstances` (a `MANAGER` TX), not by deploying more contracts. Extend `MetaBalanceAdapter` and implement the two data hooks `_instancePositions(account, instance, assetFilter)` + `_instanceAssets(instance)`, plus the three identity hooks `_protocolBrand()` / `_protocolId()` / `_protocolSubId()` (the version-stripped brand, the ecosystem roll-up, and the per-product slug — see §1.1). Build each leg with the base's `_leg(asset, amount, isDebt, positionId, kind)` helper (it stamps the three identity fields, `balanceAdapter = address(this)`, `isLocked = false`, and `positionInstanceId = bytes32(0)`), and derive `positionLabels` via the base's `_labels(category, leaf)` helper. Override `_instancePositionId(bytes32 instance)` whenever your positionId is not the default `abi.encode(_toAddress(instance))` — `abi.encode(instance)` for raw-bytes32 coordinates (Morpho marketIds, Balancer V2 poolIds), or a derived value (Aave V3's coordinate is a ProtocolDataProvider but its positionId is the Pool resolved from it). **This hook is load-bearing, not decorative:** the base's `positionIds()` maps the governed instance set through it to satisfy `IPositionEnumerable`, so it MUST equal the positionId your `_instancePositions` passes to `_leg`. Computing the positionId inline while leaving the hook on its default is a silent break — the enumeration advertises ids no position carries, the configuration-view join returns nothing, and every test stays green. Call the hook from `_instancePositions` rather than re-deriving. Adding a pool/vault later is a config TX, not a deploy. See `GearboxV3MarketsMetaBalanceAdapter.sol`, §6.1 of `src/balances/BALANCE_ADAPTERS.md`, and [ADR 0010](../decisions/0010-meta-balance-adapters.md). Meta-adapters still take **no admin functions** — the governed state lives on NAVCalculator.

Today meta-adapters cover all major multi-instance protocols (Aave V3, Compound V3, Morpho Vaults/Markets, Euler V2, Gearbox V3 markets + credit accounts, Balancer V2/V3 pools + gauges, Curve pools + gauges, Convex, Fluid fTokens + Vaults, StakeWise V3, Uniswap V2/V3, PancakeSwap V2/V3). For a new multi-instance protocol, a meta-adapter is almost always the right choice. (Uniswap V3 / PancakeSwap V3 are meta-adapters too — their `NonfungiblePositionManager` is `ERC721Enumerable`, so an account's LP NFTs are enumerable on-chain and no off-chain assistant is needed.)

---

## 1. Write the adapter contract

File: `src/balances/<family>/<MyProtocol>.sol`, where `<family>` is `BalanceAdapters` (plain), `MetaBalanceAdapters` (multi-instance), or `AssistedBalanceAdapters` (externally-fed). Multi-file protocols keep a `<protocol>/` subdir inside the family folder.

### 1.1 Identity pattern

Every `PositionBalance` now carries typed identity fields instead of free-form strings. The protocol identity is a **three-level taxonomy** (`protocolBrand` → `protocolId` → `protocolSubId`):

| Field | Type | What to put |
|---|---|---|
| `protocolBrand` | `bytes32` | The broadest, version-stripped brand roll-up (e.g. `ProtocolIds.AAVE`, `ProtocolIds.BALANCER`). Display/grouping only — NOT part of the stable identity key. For unversioned protocols the brand equals the ecosystem id (reuse the same constant). |
| `protocolId` | `bytes32` | The ecosystem/version roll-up (e.g. `ProtocolIds.AAVE_V3`). Grouping layer. For single-product ecosystems, reuse the same constant as `protocolSubId` (e.g. `CAP`, `MERKL`, `UNISWAP_V3`). |
| `protocolSubId` | `bytes32` | The per-product slug (e.g. `ProtocolIds.AAVE_V3_LENDING`, `ProtocolIds.SPARK_LEND`) — the protocol component of the **stable reconciliation key**. Each is `keccak256` of a lowercase kebab-case slug. Add a new constant if needed (see §1.2). |
| `positionId` | `bytes` | `abi.encode(keyAddress)` or `abi.encode(a, b)` computed at query time, of the **static, timeless** key (never a per-request id). The `protocolSubId` selects the decode schema — see the schema comments at the top of `ProtocolIds.sol`. |
| `positionKind` | `PositionKind` | Enum from `src/utils/PositionKind.sol`: `Wallet`, `Supplied`, `Borrowed`, `Collateral`, `Staking`, `Rewards`, or `Fees`. |
| `isLocked` | `bool` | `true` if the leg is not withdrawable now (pending withdrawal / unstaking cooldown); `false` if liquid. `false` for most adapters. Withdrawal-queue / cooldown adapters split a holding into a claimable (`false`) and a locked (`true`) leg sharing one static `positionId` and one key; `isLocked` is a mutable per-leg attribute (NOT part of the key), so the two legs are summed in reconciliation. See [ADR 0016](../decisions/0016-islocked-position-status.md). |
| `positionInstanceId` | `bytes32` | The **ephemeral** per-item coordinate (e.g. a Uniswap V3 NFT tokenId, a withdrawal-request id), `bytes32(0)` when there is none. It rides here as a typed field — never as a label and never in `positionId`. |

### 1.2 Adding a new ProtocolIds constant

If no existing constant fits your protocol, add the slug(s) you need to `src/utils/ProtocolIds.sol` — typically a per-product `protocolSubId`, plus a `protocolId` (and `protocolBrand`) when the brand/ecosystem is not already present:

```solidity
bytes32 internal constant MY_PROTOCOL = keccak256("my-protocol-v1");
```

Slug rules: lowercase ASCII, kebab-case, include the major version. Document the `positionId` ABI-encode schema for this `protocolSubId` in the NatSpec block at the top of the file (it is the schema clients use to decode without runtime sniffing).

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
import {ProtocolNames} from "src/utils/ProtocolNames.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

contract MyProtocolBalanceAdapter is IBalanceAdapter, IPositionDescribable {
    /// @notice The protocol contract this adapter reads from.
    address public immutable PROTOCOL_CONTRACT;

    /// @notice NAVCalculator (asset registry source).
    INAVCalculator public immutable NAV_CALCULATOR;

    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.MY_PROTOCOL;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.MY_PROTOCOL;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.MY_PROTOCOL;

    constructor(address protocolContract_, address navCalculator_) {
        if (protocolContract_ == address(0) || navCalculator_ == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(protocolContract_, "Protocol contract");
        AddressCheckLib.requireContract(navCalculator_, "NAVCalculator");

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
    /// @dev Names the PROTOCOL, never the product. Return the `ProtocolNames` constant for your protocol id —
    ///      adapters sharing a `ProtocolIds` protocol id MUST return the same string, and the product goes in
    ///      `positionLabels()` below. Add a constant to `src/utils/ProtocolNames.sol` (and a branch to
    ///      `forProtocolId`) if the protocol is new. `test/ProtocolNameConsistency.t.sol` pins every hardcoded
    ///      adapter to its constant. NOTE: meta-adapters do NOT declare this at all — `MetaBalanceAdapter`
    ///      derives it from `_protocolId()`, so omit it entirely when extending `MetaBalanceAdapter`.
    function protocolName() external pure returns (string memory) {
        return ProtocolNames.MY_PROTOCOL;
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
        //     protocolBrand: PROTOCOL_BRAND,
        //     protocolId: PROTOCOL_ID,
        //     protocolSubId: PROTOCOL_SUB_ID,
        //     positionId: abi.encode(PROTOCOL_CONTRACT),
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
        out[0] = "Market";
        out[1] = "<derived leaf>";
    }
}
```

Reuse patterns from existing adapters:

- **Per-instance, multi-asset (supply + borrow legs):** `src/balances/BalanceAdapters/SparkLendBalanceAdapter.sol`.
- **Per-instance, single-asset vault:** `src/balances/BalanceAdapters/CapBalanceAdapter.sol`.
- **Meta-adapter, single-leg:** `src/balances/MetaBalanceAdapters/GearboxV3MarketsMetaBalanceAdapter.sol`, `src/balances/MetaBalanceAdapters/MorphoVaultsMetaBalanceAdapter.sol`.
- **Meta-adapter, multi-leg (LP + rewards):** `src/balances/MetaBalanceAdapters/curve/CurveGaugesMetaBalanceAdapter.sol`, `src/balances/MetaBalanceAdapters/balancer/BalancerV3GaugesMetaBalanceAdapter.sol`.

Conventions:

- All addresses set in the constructor are **immutable**. No setters.
- The three identity ids (`protocolBrand`, `protocolId`, `protocolSubId`) are `bytes32` constants declared at the class level (e.g. `bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.MY_PROTOCOL`). They are never constructor params. For single-product, unversioned protocols all three may resolve to the same constant.
- `positionId` is computed at query time via `abi.encode(...)`. It is never stored. The encode schema must match the NatSpec in `ProtocolIds.sol` for this `protocolSubId`.
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
- `PositionBalance` fields: assert the identity ids (`protocolBrand` / `protocolId` / `protocolSubId`) equal the expected `ProtocolIds` constants, `positionKind == PositionKind.Supplied` (or appropriate), and `positionId == abi.encode(...)` with the expected bytes.

Use `Mock_NAVCalculator` (in `test/mocks/nav_calculator.sol`) and a thin mock of the protocol contract.

### 2.2 Fork test (real protocol)

File: `test/balances/<family>/fork/<MyProtocol>.fork.t.sol`.

Cover:

- Deploy the adapter against the **real** protocol contract on a pinned block + chain.
- Pick a real holder with a non-trivial position; assert the returned balance is within a reasonable range of an off-chain reference (e.g., the protocol's own UI or a CSV check).
- Reward accrual: time-warp with `vm.warp(block.timestamp + 1 days)` and confirm rewards increase (where applicable).
- Asset registry filtering: confirm positions for assets *not* registered with NAVCalculator are dropped.

Extend `BalanceAdapterTestBase` (in `test/balances/BalanceAdapterTestBase.fork.sol`) and pin the block by overriding `_setupFork()` with the shared `getAlchemyUrl` / `createSelectForkWithCadence` helpers from `test/TestEnvConfigurator.sol`:

```solidity
contract MyProtocolBalanceAdapterForkTest is BalanceAdapterTestBase {
    uint256 public constant FORK_BLOCK = 21_395_285;

    function setUp() public override {
        super.setUp();
        // ... deploy the adapter, register assets, etc.
    }

    function _setupFork() internal override {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
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

For a **meta-adapter**, add the constructor block (only chain-level constants — the protocol's global contracts) to `contracts-deployment-config/meta-balance-adapters/<chainId>.json`. There is **no display-name key**: `MetaBalanceAdapter.protocolName()` derives it from `_protocolId()`, so a meta adapter with no chain-global contracts has an empty constructor block:

```json
{
  "GearboxV3MarketsMeta": {
    "enabled": true,
    "constructor": {}
  },
  "MorphoMarketsMeta": {
    "enabled": true,
    "constructor": {
      "morpho": "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb"
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
  "GearboxV3MarketsMeta": {
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
- For per-instance adapters deployed more than once, use a disambiguator suffix in the key matched by `_startsWith` in the dispatch (e.g. `SparkLend_<suffix>`; the legacy now-superseded per-instance Aave adapters used a chain suffix like `AaveV3_Optimism`). The base name and any suffixed variant must both route to the same `_deploy*` helper.
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

For a **meta-adapter**, the helper reads only the chain-global contract addresses the constructor needs — often none, in which case it just passes `navCalculator`. The display name is **not** a constructor argument: `MetaBalanceAdapter` derives it from `_protocolId()` via `ProtocolNames.forProtocolId`. If your protocol is new, add its constant and a `forProtocolId` branch in `src/utils/ProtocolNames.sol`, or every verbose read will show a blank name. See `_deployGearboxV3MarketsMeta` or `_deploySparkLend` in the same file for concrete patterns.

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

---

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
