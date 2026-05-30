# How to add a new balance adapter

End-to-end walkthrough. Read [`/CLAUDE.md`](../../CLAUDE.md) and [`../onboarding-claude.md`](../onboarding-claude.md) first if you have not.

The framework reference is [`src/balances/BALANCE_ADAPTERS.md`](../../src/balances/BALANCE_ADAPTERS.md). This doc is the *recipe*; that doc is the *spec*.

Throughout, replace `MyProtocol` with your protocol name. Pick a name that's stable, recognizable, and matches the on-chain protocol identity (e.g., `AaveV3SafetyModule`, `MorphoVault`, `BalancerV3`).

---

## 0. Decide what the adapter reports

Before writing code, answer:

| Question | Why it matters |
|---|---|
| Which **assets** does this adapter report on? | Drives `underlyingAssetsSupported()`. List them as token addresses. |
| For each asset, is the position a **credit** (supply, stake, LP) or **debt** (borrow)? | Drives `isDebt`. Each `PositionBalance` is "asset + amount + isDebt". |
| Does the protocol have **multiple instances** (one per pool/market/vault)? | Two routes — see "Single-instance vs meta-adapter" below. |
| Is there a **canonical underlying asset** (e.g., what the position is denominated in when valued)? | Adapters return amounts in the underlying token's decimals. The price registry will price the underlying. |
| Are there **rewards** that should count toward NAV? | If yes, the adapter must include them as additional `PositionBalance` entries with the reward token as the underlying asset. |

**Rule of thumb:** the adapter is a *view*. It reads protocol state and translates it into `PositionBalance[]`. It does not price, sign, or aggregate; NAVCalculator does that.

### Single-instance vs meta-adapter

If the protocol has **many fungible instances** (Morpho vaults/markets, Balancer pools, Aave instances), prefer a **meta-adapter** over one contract per instance:

- **Single-instance** (the default skeleton below): pin the pool/market/vault in the constructor. One deployed contract per instance. Right for singletons (DAI DSR, a withdrawal queue) or when there is exactly one instance you care about.
- **Meta-adapter** (`IMetaBalanceOracleAdapter` / `MetaBalanceOracle`): one immutable contract for *all* instances of the protocol; the active set is configured on NAVCalculator via `setMetaInstances` (a `MANAGER` TX), not by deploying more contracts. Extend `MetaBalanceOracle` and implement `_instancePositions(account, instance, assetFilter)` + `_instanceAssets(instance)`; derive identity on-chain from the instance coordinate. Adding a pool/vault later is a config TX, not a deploy. See `MorphoVaultsMeta.sol`, §6.1 of `src/balances/BALANCE_ADAPTERS.md`, and [ADR 0010](../decisions/0010-meta-balance-adapters.md). Meta-adapters still take **no admin functions** — the governed state lives on NAVCalculator.

---

## 1. Write the adapter contract

File: `src/balances/protocols/<protocol>/<MyProtocol>.sol`.

Skeleton:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";

contract MyProtocolBalanceOracle is IBalanceOracleAdapter {
    /// @notice The protocol contract this adapter reads from.
    address public immutable PROTOCOL_CONTRACT;

    /// @notice NAVCalculator (asset registry source).
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Protocol identifier emitted on every PositionBalance (e.g. "Aave V3", "Morpho").
    string private _protocol;
    /// @notice JSON metadata BASE for the PositionBalance.positionDetail field — no closing `}`.
    /// @dev Single-type adapters emit `string.concat(_positionDetail, "}")`. Multi-leg adapters
    ///      use `PositionType.withType(_positionDetail, PositionType.<CONSTANT>)` from
    ///      `src/utils/PositionType.sol`. See docs/howto/position-detail-schema.md.
    string private _positionDetail;
    /// @notice Stable hex identifier for this adapter instance (most-specific immutable address —
    ///         vault, comet, gauge, marketId, …). Used by frontends as a cross-block React key.
    /// @dev Pass as constructor arg for almost every adapter. MorphoMarket is the documented
    ///      exception: it derives `_positionId` automatically from `marketId` via
    ///      `Strings.toHexString(uint256(marketId), 32)` — no `positionId_` constructor param.
    string private _positionId;

    constructor(
        address protocolContract_,
        address navCalculator_,
        string memory protocol_,
        string memory positionDetail_,
        string memory positionId_
    ) {
        if (protocolContract_ == address(0) || navCalculator_ == address(0)) revert InvalidArguments();
        require(protocolContract_.code.length > 0, "Protocol contract must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        PROTOCOL_CONTRACT = protocolContract_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
        _protocol = protocol_;
        _positionDetail = positionDetail_;
        _positionId = positionId_;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function underlyingAssetsSupported() external view returns (address[] memory) {
        // Return the deduplicated list of assets this adapter reports on.
    }

    function getOracleBalanceForAsset(address account, address asset)
        external view returns (uint256 amount, bool isDebt)
    {
        // Single-asset path. Return (0, false) for unsupported assets or zero account.
    }

    function getOracleBalances(address account)
        external view returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        // Iterate underlyingAssetsSupported(); include only non-zero amounts.
    }

    function getOraclePositions(address account, address assetFilter)
        external view returns (INAVCalculator.PositionBalance[] memory positions)
    {
        // Filter by registered + supported assets, build PositionBalance entries.
    }
}
```

Reuse patterns from existing adapters:

- **Single-instance, multi-asset:** `src/balances/protocols/aave/AaveV3Instance.sol`, `src/balances/protocols/compound/CompoundV3Comet.sol`.
- **Single-asset wrapper (vault/staked):** `src/balances/protocols/morpho/MorphoVault.sol`, `src/balances/protocols/maker/DaiDsr.sol`.
- **LP + rewards:** `src/balances/protocols/curve/Curve.sol`, `src/balances/protocols/balancer/BalancerV3.sol`, `src/balances/protocols/aura/Aura.sol`.

Conventions:

- All addresses set in the constructor are **immutable**. No setters.
- The three identity strings (`_protocol`, `_positionDetail`, `_positionId`) are **mandatory constructor params** as of PR #35 — they pin user-facing metadata into immutable storage and flow through every emitted `PositionBalance`. Schema reference: [`docs/howto/position-detail-schema.md`](position-detail-schema.md); canonical per-adapter values: [`script/config/adapter-identities.json`](../../script/config/adapter-identities.json). Exception: `MorphoMarket` takes only `marketId_` (positionId derived automatically via `Strings.toHexString`).
- For each external call to the protocol, use a **minimal interface** declared at the bottom of the file (or in a sibling `I<Protocol>.sol`) — do not import the protocol's full library.
- For asset metadata (symbol/decimals on the `PositionBalance.underlyingAsset` field), call `NAV_CALCULATOR.getRegisteredAssets()` and only emit positions for assets present in that list. This is what `ERC20DefaultOracle` does.
- `amount` in `PositionBalance` is **always positive**. Use `isDebt` to mark debt.
- When emitting a `PositionBalance`, set `protocol = _protocol`, `positionId = _positionId`, and `positionDetail = string.concat(_positionDetail, "}")` for single-type adapters or `PositionType.withType(_positionDetail, PositionType.<CONSTANT>)` (from [`src/utils/PositionType.sol`](../../src/utils/PositionType.sol)) for multi-leg adapters.

---

## 2. Write the factory

> **⚠ Aspirational section.** The factory framework (`BalanceAdapterFactoryBase`, `BalanceAdapterRegistry`, the `5_DeployAdapterFactories` script, etc.) is described in [ADR 0001](../decisions/0001-balance-adapter-factory-pattern.md) but is **not yet implemented in the codebase as of `4def473` (2026-05-06)**. `src/balances/factories/` does not exist. Until the framework lands, **skip this section** and use the current direct-deploy path:
>
> 1. Skip writing a factory contract. Your adapter is a single Solidity file under `src/balances/protocols/<protocol>/` (or directly under `src/balances/protocols/` for single-file adapters).
> 2. Add a `_deployIfEnabled("MyProtocol_<instance>")` call to `script/deploy/04_DeployBalanceAdapters.s.sol` so the production deploy picks it up. Wire dispatch via `_deployBalanceAdapter` (e.g. follow the pattern of `_deployMorphoVault`).
> 3. Add the chain-config entry under `chains/<id>.json.balanceAdapters.MyProtocol_<instance>` with the constructor params your adapter needs.
> 4. Registration on `NAVCalculator` happens via `script/deploy/06_Configure.s.sol`'s Safe TX bundle calling `addBalanceOracle(adapter)` directly — no factory in the loop.
> 5. Skip §3 (factory tests), §5 (factory deploy block), and §6 (registry handoff) below; jump to §4 (adapter unit + fork tests) and §7 (Safe TX flow via `06_Configure`).
>
> The aspirational instructions below describe the target end state; preserve them so the recipe is ready to use the moment ADR 0001 ships, but **do not** create `src/balances/factories/*` files in your PR until that framework is shipped.

File: `src/balances/protocols/<protocol>/<MyProtocol>AdapterFactory.sol`.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterFactoryBase} from "src/balances/factories/BalanceAdapterFactoryBase.sol";
import {IBalanceAdapterRegistry} from "src/balances/factories/IBalanceAdapterRegistry.sol";
import {MyProtocolBalanceOracle} from "src/balances/protocols/<protocol>/MyProtocol.sol";

contract MyProtocolAdapterFactory is BalanceAdapterFactoryBase {
    constructor(address registry, address navCalculator, address initialOwner)
        BalanceAdapterFactoryBase(keccak256("MyProtocol"), registry, navCalculator, initialOwner)
    {}

    function deploy(address protocolContract, string calldata protocol, string calldata positionDetail, bytes32 salt)
        external onlyOwner returns (address adapter)
    {
        bytes memory initCode = abi.encodePacked(
            type(MyProtocolBalanceOracle).creationCode,
            abi.encode(protocolContract, protocol, positionDetail, NAV_CALCULATOR)
        );
        adapter = _deployCreate2(salt, initCode);
        _track(adapter, true);
        IBalanceAdapterRegistry(REGISTRY).register(adapter);
        emit AdapterDeployed(adapter, salt);
    }

    function predict(address protocolContract, string calldata protocol, string calldata positionDetail, bytes32 salt)
        external view returns (address)
    {
        bytes memory initCode = abi.encodePacked(
            type(MyProtocolBalanceOracle).creationCode,
            abi.encode(protocolContract, protocol, positionDetail, NAV_CALCULATOR)
        );
        return _predictCreate2(salt, keccak256(initCode));
    }
}
```

Notes:

- `keccak256("MyProtocol")` becomes the registry's protocol key. Pick a name and **never change it** — the key is immutable on-chain.
- Mirror `deploy` and `predict` parameter shapes exactly. Diverging breaks address determinism.
- `NAV_CALCULATOR` is appended to the constructor args here so the factory knows the right NAVCalculator and adapters can't be deployed against the wrong one.

Look at `src/balances/protocols/balancer/BalancerV3AdapterFactory.sol` or `src/balances/protocols/morpho/MorphoVaultAdapterFactory.sol` for working examples.

---

## 3. Tests

Two files, both required for review.

### 3.1 Unit test (mocks only)

File: `test/balances/protocols/<MyProtocol>.t.sol`.

Cover:

- Constructor: zero-address guards, non-contract guards.
- `supportsInterface` returns true for `IBalanceOracleAdapter` and `IERC165`, false otherwise.
- `getOracleBalanceForAsset` returns `(0, false)` for zero account, zero asset, unsupported asset.
- `getOracleBalances` returns empty arrays for zero account.
- `getOraclePositions` returns empty for zero account; respects `assetFilter`.
- Non-registered assets (per `NAV_CALCULATOR.getRegisteredAssets()`) are dropped from `getOraclePositions`.

Use `MockNAVCalculator` (or whatever existing mock test files use — grep for `MockNAVCalculator`) and a thin mock of the protocol contract.

### 3.2 Fork test (real protocol)

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

## 4. Wire chain config

File: `script/config/chains/<chainId>.json`.

Add an entry under `balanceAdapters`:

```json
"MyProtocol_<instance>": {
  "enabled": true,
  "constructor": {
    "protocolContract": "0x...",
    "protocol": "My Protocol",
    "positionDetail": "{\"protocol\":\"My Protocol\",\"product\":\"Lending\",\"name\":\"<instance>\"",
    "positionId": "0x..."
  },
  "deployed": ""
}
```

The key (`MyProtocol_<instance>`) is the lookup name used by `04_DeployBalanceAdapters.s.sol`. The constructor block must list **every parameter** the adapter takes, in any order — `ConfigReader.readAdapterParam` looks them up by name.

For multi-instance protocols (e.g., one Aave market per chain, one Morpho vault per asset), use the instance disambiguator in the key (`AaveV3_Core`, `AaveV3_Prime`, `MorphoVault_kpkUSDCPrime_V1`).

For chains where the protocol does not exist, set `"enabled": false` (or omit the key entirely if you prefer; the deploy script skips disabled entries).

---

## 5. Wire the deploy script

File: `script/deploy/04_DeployBalanceAdapters.s.sol`.

Add a `_deployMyProtocol` helper that mirrors the existing ones (`_deployAaveV3SafetyModule`, `_deployBalancerV3`, etc.):

```solidity
function _deployMyProtocol(string memory adapterName, address navCalculator) internal returns (address) {
    address protocolContract = vm.parseAddress(
        ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocolContract")
    );
    string memory protocol =
        ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
    string memory positionDetail =
        ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "positionDetail");
    string memory positionId =
        ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "positionId");

    MyProtocolBalanceOracle adapter =
        new MyProtocolBalanceOracle(protocolContract, navCalculator, protocol, positionDetail, positionId);
    return address(adapter);
}
```

Then add a dispatch entry in the script's main loop so the new key (or its prefix, depending on the existing pattern) routes here. Search the file for `if (Strings.equal(...))` or the existing dispatch table and add your case there.

For factory-driven deployment, the equivalent is in `script/deploy/05_DeployAdapterFactories.s.sol` — add a `FactorySpec` entry following the existing pattern. Most new adapters today should ship with a factory, so do this in addition to `04`.

---

## 6. Deploy and register

The full deploy ordering is in [`../../script/deploy/README.md`](../../script/deploy/README.md). For a new adapter on an existing chain:

```bash
# Deploy the adapter (or factory, depending on your route)
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --chain-id <chainId> \
  --account $DEPLOYER_NAME \
  --broadcast

# (If factory-driven) deploy the factory
forge script script/deploy/05_DeployAdapterFactories.s.sol \
  --chain-id <chainId> \
  --account $DEPLOYER_NAME \
  --broadcast
```

`04` writes the deployed address back into `script/config/chains/<chainId>.json` under `balanceAdapters.MyProtocol_<instance>.deployed`. Verify it's there before opening the PR.

Registration:

- **Factory route (preferred):** factory `deploy(...)` ends with `REGISTRY.register(adapter)` automatically. Nothing else to do.
- **Pre-existing adapter / no factory yet:** the OIV Safe calls `BalanceAdapterRegistry.registerExternal(keccak256("MyProtocol"), adapter)`.

Then verify on-chain:

```bash
cast call $NAVCalculator "isOracleRegistered(address)(bool)" $adapter --rpc-url $RPC
```

---

## 7. Refresh integration test snapshots

If your adapter affects NAV for an existing test account in `test/integration/accounts.json` (or you're adding a new test account that exercises it), run the bump script before opening the PR:

```bash
script/test/refresh-integration-snapshot.sh
```

This regenerates the expected `navUsd8dp` values, optionally cross-checks against DeBank, and updates `accounts.json` in place. Don't edit the per-chain `NAV.<Chain>.integration.fork.t.sol` files directly. Full walkthrough: [`./refresh-integration-test-blocks.md`](./refresh-integration-test-blocks.md).

## 8. Open the PR

PR checklist:

- [ ] `forge build` clean
- [ ] `forge test --match-path "test/balances/protocols/MyProtocol*"` clean
- [ ] `FOUNDRY_PROFILE=slow forge test --match-path "test/balances/protocols/fork/MyProtocol*"` clean
- [ ] Chain config updated for every chain where the adapter applies
- [ ] No unrelated files committed (run `git status` before staging)
- [ ] PR description includes: protocol name, what the adapter reports, the chain(s) it's enabled on, any reward semantics, and the fork-test holder address used as ground truth
- [ ] If the adapter changes NAV for an integration-test account, ran `script/test/refresh-integration-snapshot.sh` and committed the resulting `test/integration/accounts.json` diff

If you're touching the deployment lifecycle (new factory, new role, new migration), also update or add the relevant ADR under [`../decisions/`](../decisions/).
