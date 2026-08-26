# Cover Polygon PoS staking (POL) in NAV — new meta balance adapter + POL as an asset

## Context

DeBank shows ACCOUNT_11 (`0x0EFcCBb9…fc89`) holding a **Polygon Staking** position worth ~$11.6K —
106,114.2338 POL staked with the "OKX Earn" pool plus ~734 POL of unclaimed rewards. NAV does not
track it, and cannot: **POL is not a registered asset**, and `accounts.json` documents it as a token
"without a Chainlink mainnet price feed — POL (Polygon-only feed)".

**That note is wrong, and disproving it is what makes this work possible.** Chainlink's mainnet
reference data lists proxy `0x7bAC85A8a13A4BcD8abb3eB7d6b4d632c5a57676` under the legacy display name
`MATIC / USD` but with **`baseAsset: POL`** — it is the POL feed, just not named that. Live, 8 dp,
declared heartbeat 86400, 1% deviation, no shutdown date. So POL is priceable on mainnet with a plain
**Chainlink** primary and *no custom feed contract at all*.

Outcome: NAV values Polygon staking positions, and POL becomes a priced asset available to any adapter.

## Measured facts (all verified on-chain, 2026-08-26)

| | |
|---|---|
| StakeManager | `0x5e3Ef299fDDf15eAa0432E6e66473ace8c13D908`; `token()` → **POL** `0x455e53CB…C3F6` |
| Validators | `NFTCounter` = 210 → 209 live `ValidatorShare` contracts |
| Implementation | **all 209 share one impl** `0xbe63b977…e9e8`, so the ABI is uniform |
| Position held | validator **192**, share `0x97997023…4868` (`dPOLc0`, "Delegated POL #c0") |
| Staked | `getTotalStake` → 106,114.233772 POL — matches DeBank exactly |
| Rewards | `getLiquidRewards` → ~734.68 POL |
| One-call read | **`getStakeAndRewards(address)` → `(stakeAmount, liquidRewards)`**, responds on **209/209** shares |
| Unbonding | `unbondNonces(acc)` = 0 — nothing queued for this account |
| Other fixtures | zero; only ACCOUNT_11 stakes |

## Design

### 1. `POL` as a registered asset — no new contract

`script/config/nav-config/assets-and-price-feeds/1.json`, plain Chainlink primary:

```json
"POL": {
  "address": "0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6",
  "accrualKind": "None",
  "labels": ["Polygon", "Staking"],
  "priceFeeds": [{ "type": "Chainlink", "address": "0x7bAC85A8a13A4BcD8abb3eB7d6b4d632c5a57676", "heartbeat": 90000 }]
}
```

- **Heartbeat 90000, not 86400.** The feed *declares* 86400 and the declared-heartbeat guard requires
  margin above it ("declared + 1 h"). At 86400 this reproduces the sUSDS failure — priced `$0` at the
  tail of nearly every publish cycle. USDT and XAUt already sit at 90000 for exactly this reason.
- **No `pegToleranceBps`** (POL floats) and **no monitor feed** — Chainlink's mainnet reference data
  lists exactly one POL feed, so there is no independent source to diverge against.
- A `$comment` must record why a feed named `MATIC / USD` is POL's primary (Chainlink's declared
  `baseAsset: POL`; POL is the 1:1 MATIC successor and `PolygonMigration.unmigrationLocked()` is
  `false` with 9.6 B MATIC held, so the peg is arbitrage-enforced both ways). Without it, it reads as
  a copy-paste error.

### 2. `PolygonStakingMetaBalanceAdapter` — new meta-adapter (ADR 0010)

`src/balances/MetaBalanceAdapters/PolygonStakingMetaBalanceAdapter.sol`, a near-copy of
`StakeWiseV3VaultsMetaBalanceAdapter.sol` — same shape (address-keyed instance, two legs in one
underlying token, single-asset `_instanceAssets`).

- **Constructor `(address underlyingToken_, address navCalculator_)`** — matching the family idiom
  (StakeWise passes its underlying from config rather than deriving it). POL is independently
  checkable via `StakeManager.token()`; note that in the config `$comment` rather than adding a
  constructor arg. (`ValidatorShare.polToken()` returns `address(0)`, so the share is *not* a usable
  source — verified.)
- **Instance** = `ValidatorShare` address widened to `bytes32`. **Do not override
  `_instancePositionId`** — the base default `abi.encode(_toAddress(instance))` is already correct.
- **`_instancePositions`**: `assetFilter` short-circuit first, then `_getAssetInfo(POL)` returning
  **empty (never reverting)** when unregistered, then one `getStakeAndRewards(account)` call yielding
  both legs — `Staking` (stakeAmount) and `Rewards` (liquidRewards), both `isDebt = false`, built via
  `_leg(...)`, over-allocated then shrunk so zero legs drop out.
- **Identity**: `ProtocolIds.POLYGON` for brand *and* id (Polygon is unversioned — the file explicitly
  sanctions reusing one constant), `ProtocolIds.POLYGON_STAKING` for the sub-id.
- **Labels**: `ValidatorShare.name()` is generic and **collides across validators** ("Validator Share
  Token"), so the leaf should come from `validatorId()` → `"Validator #192"`, with the tier-2
  hex-address fallback the family uses. Copy the StakeWise guards verbatim: `pid.length != 32` →
  empty, decode as `uint256` not `address`, `raw >> 160 != 0` → category-only.

**Two legs, not three — deliberate and documented.** `getStakeAndRewards` excludes the unbonding queue
(`unbondNonces` + `unbonds_new` × `withdrawExchangeRate`). Reading it means iterating an unbounded
nonce range per instance per account, and DeBank does not show it either. The direction is
**under-report**, which is the safe one here. Record it in the contract `@dev` and the config
`$comment` so a later reader sees a decision, not an oversight.

### 3. Instance set

Seed with **validator 192 only** (`0x97997023…4868`) — the only one any Safe delegates to. Registering
all 209 would cost 209 external calls per account per NAV read for 208 empty results. Adding one later
is an `addMetaInstances` transaction, not a deploy.

### 4. DeBank allowlist — must land in the same change

`polygon_staking` is **not** in `chains.1.supportedDeBankProtocols`, so this position is excluded from
the filtered anchor today (the committed cache shows `id='polygon_staking'`, `$8,017.17`). Shipping
the adapter alone would push NAV **above** filtered DeBank — new drift in the opposite direction.

## Files

### New
- `src/balances/MetaBalanceAdapters/PolygonStakingMetaBalanceAdapter.sol` (minimal `IValidatorShare`
  interface declared in-file, per family convention — never import the protocol's own library)
- `test/balances/MetaBalanceAdapters/PolygonStakingMetaBalanceAdapter.t.sol` — unit, with a
  `MockValidatorShare` plus the six label-adversary mocks copied from the StakeWise unit test
  (reverting `name()`, empty returndata, raw ABI envelope, gas-burner, `bytes32` name, codeless)
- `test/balances/MetaBalanceAdapters/fork/PolygonStakingMetaBalanceAdapter.fork.t.sol` — fork,
  extending `BalanceAdapterTestBase`

### Identity + registry — three edits, and **`ProtocolNames` is not optional**
- `src/utils/ProtocolIds.sol` — `POLYGON` + `POLYGON_STAKING` constants, and the positionId-schema
  line in the header NatSpec
- **`src/utils/ProtocolNames.sol` — constant + `forProtocolId` branch. `protocolName()` calls this and
  `revert UnknownProtocolId` without it, so the adapter is unusable if this is skipped.**
- `src/utils/PositionKind.sol` — **no change**; `Staking` and `Rewards` already exist, and adding an
  enum value would be a breaking ABI change

### Wiring — both dispatch sites
- `script/deploy/04_DeployBalanceAdapters.s.sol` — import, `_deployIfEnabled("PolygonStakingMeta")`,
  `_equals` dispatch, `_deploy…` helper. Namespace is `"balanceAdapters"` for meta adapters too (the
  plain/meta split is by config *file*, not by this key). **Plain CREATE**, matching every
  "takes an underlying token" adapter; no `DeploySalts` entry needed.
- `test/integration/IntegrationFromConfigBase.fork.sol` — import, `_equals` dispatch, `_deploy…`
  helper using plain `new` and `_chainId`. **A missing entry is a silent skip**, and
  `UndispatchedAdapterGuard` enforces `test/integration/undispatched-adapters.json` in *both*
  directions, so it fails either way rather than quietly under-reporting.

### Config
- `script/config/contracts-deployment-config/meta-balance-adapters/1.json` — `{ underlyingToken: POL }`
- `script/config/nav-config/meta-balance-adapters/1.json` — `instances: [0x97997023…4868]`
- `script/config/nav-config/assets-and-price-feeds/1.json` — the POL entry above
- `test/integration/accounts.json` — allowlist `polygon_staking`; correct the "POL (Polygon-only feed)"
  claim; re-pin ACCOUNT_11's `navUsd8dp`

### Counts that break CI if missed
- `test/ProtocolNameConsistency.t.sol` — `META_ADAPTER_COUNT` **22 → 23** + an `_expectName` line
- `test/balances/MetaBalanceAdapterEnumeration.t.sol` — same count + an `_assertAdvertisesCoordinate` line
- `src/balances/BALANCE_ADAPTERS.md` §7.1 heading "(22)" → "(23)" + a catalogue row
- `README.md` "22 meta-adapters" → 23

### Docs
- `docs/howto/position-identity-schema.md` — five places (examples, verbose example, slug table,
  positionId decode table, PositionKind table) plus the TypeScript decode snippet
- `docs/reference/position-identity-matrix.md` — one row per leg
- `docs/howto/add-balance-adapter.md` — the meta-coverage protocol list

No ADR needed — ADR 0010 already governs the meta family.

## Verification

1. `python3 script/deploy/preflight/preflight_config.py 1` — 0 errors; assets 48 → 49.
2. `forge build`; unit tests (both legs, identity, `assetFilter` match/miss, unregistered underlying →
   empty not revert, per-instance revert isolation, and the full `positionLabels` adversary set).
3. Fork test at a pinned block asserting **exact** figures for validator 192 — staked
   106,114.233772 POL and a non-zero rewards leg — plus `positionId == abi.encode(validatorShare)`.
4. Revert-probe: point an instance at a validator with no delegation → both legs absent (not zero-value
   noise); point at a codeless address → that instance dropped, siblings still reported.
5. `FOUNDRY_PROFILE=slow forge test --match-contract MainnetIntegrationFromConfig --threads 1` —
   ACCOUNT_11's NAV rises by staked+rewards; re-pin `navUsd8dp`; confirm the gap stays inside the 1%
   tolerance once `polygon_staking` is allowlisted (the two moves largely cancel).
6. Deploy `04` + register via `06_Configure` from MANAGER `0xAa5A7C7E…4F72`, then verify **on-chain**
   (code size, `getMetaInstances` exact match, `getAccountNav` delta) — never from the deployment record.
7. Verify on explorers; update the gitbook (new adapter page, `deployment-addresses.md`, POL feed row).

## Risks

- **Irreversible**: registering an asset and an adapter writes to the live NAV.
- **~$11.6K position** — small. The value is making POL priceable and Polygon staking covered going
  forward, not today's dollar delta.
- **Unbonding positions are not reported** — under-report, documented above.
- POL becomes the 49th asset on the `ERC20Default` read path (~585k gas each, superlinear).

---

# Review round (2026-08-27) — /fable-review on PR #328

Four gates ran against `a1fa25d0`: Fable (plan), the workflow code review, Vigilo, Copilot.

**All four converged, independently, on one finding:** `SwapMetaAdapter`'s docstring claimed
`removeBalanceAdapters` clears the outgoing adapter's meta-instance set. It does not — `Balances.sol`
says the set "is left dormant", and `NAVRegistryLib.removeBalanceAdapter` takes no `_metaInstances`
reference. Confirmed on mainnet: `getMetaInstances(<deregistered predecessor>)` still returns the
carried coordinate. Vigilo PoC-validated it.

That mattered because `addMetaBalanceAdapter` *appends* and `removeMetaInstances` reverts for an
unregistered adapter — so the dormant set cannot be cleaned without re-registering its adapter, and
re-registering with an empty list revives it alongside the successor. A double-count, reintroduced by
the cleanup path.

## Accepted residual risk

The residue from the first swap (`0x5903…51fD` holding validator 192) is **not cleaned**. It is inert:
the predecessor is deregistered so nothing queries it, and the deployment record names the successor,
so `06_Configure` never resolves the predecessor. Reviving it takes a deliberate manual
re-registration. The exact five-transaction cleanup ordering that never double-counts is recorded in
`SwapMetaAdapter.s.sol`'s docstring; it was weighed against five live-NAV transactions and deferred.

Also accepted: POL priced by a single un-monitored feed (no second mainnet POL feed exists); the POL
feed absent from `chainlink_declared_heartbeats.json` (13 of 47 chain-1 feeds share that state, and
the registered 90000 already clears the declared 86400); a validator created after 2026-08-26
potentially diverging from the shared ValidatorShare implementation.

## Refuted

Delegated principal should NOT carry `isLocked = true`. ADR 0016 defines `isLocked` as the pending
half of a claimable/locked split, not "has an exit delay" — StakeWise vault stake is `false` for the
same reason, and the genuine locked leg here is the unbond queue, deliberately unreported.
