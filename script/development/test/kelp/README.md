# Kelp DAO rsETH Withdrawal Queue — balance-adapter verification

## 1. Adapter under test

`src/balances/BalanceAdapters/KelpWithdrawalQueueBalanceAdapter.sol` — the immutable `KelpWithdrawalQueueBalanceAdapter`. Constructor: `(withdrawalManager, navCalculator)` where `withdrawalManager = Kelp LRTWithdrawalManager` (`0x62De59c08eB5dAE4b7E6F7a8cAd3006d6965ec16`). Identity is derived on-chain: `positionId = abi.encode(address(WITHDRAWAL_MANAGER))` (static; the payout asset is carried in `balanceAsset.asset`, not the positionId; **one leg per open request**, all sharing the static `positionId` and distinguished by the request's `userNonce` in `positionInstanceId`, with each leg's `isLocked` reflecting that request's own claimable/pending state), `protocolBrand = protocolId = keccak256("kelp")`, `protocolSubId = keccak256("kelp-withdrawal")`, `positionKind = Supplied`.

### Inheritance + per-chain scope (Phase 0)

- **Inheritance:** extends `BalanceAdapterBase` (the shared plain-adapter base, which declares the `IBalanceAdapter` + `IPositionDescribable` surface and implements the common `supportsInterface`). The adapter adds the balance/position reads and the `IPositionDescribable` display hooks; it does not override the base's `supportsInterface`.
- **Per-chain scope:** Kelp's `LRTWithdrawalManager` is **mainnet-only**. So mainnet (chainId 1) is the only chain that enables `KelpWithdrawalQueue` — see `script/config/nav-config/balance-adapters/1.json` and `script/config/contracts-deployment-config/balance-adapters/1.json`. A single mainnet fork test suffices.
- **Multi-asset (the distinguishing feature):** when a user unstakes rsETH, the rsETH is burned and a per-`(asset, user)` request is recorded denominated in the LST the user chose to receive. Kelp's payout assets are **discovered at runtime** from `lrtConfig().getSupportedAssetList()` — at the fork block: **stETH** (`0xae7a…`), **ETHx** (`0xA35b…`), **native ETH** (`0xEeee…`, ERC-7528 sentinel). The adapter emits **one `Supplied` leg per open request** — each carrying its own `isLocked` (`false` for claimable, `true` for pending) and its `userNonce` in `positionInstanceId`, all sharing the static `positionId = abi.encode(address(WITHDRAWAL_MANAGER))` (the payout asset is in `balanceAsset.asset`) — for every supported asset that is also registered in NAV (ADR 0016).
- **Registration gating (asymmetric, same as sGHO / Aave Umbrella / Lido / Stader):** `getAdapterPositions` drops any asset not registered on NAVCalculator (registered-asset intersection). On the dev NAV, native ETH is registered at bootstrap (`01_DeployNAV.s.sol` pre-registers the sentinel and wires its Chainlink feed); **stETH and ETHx are not** — both now carry a **Custom** primary feed (`stETHFundamental` / `ETHx` in `script/config/nav-config/assets-and-price-feeds/1.json`), and `register-assets.sh` registers only assets whose first price feed is `Chainlink`, so a request in either asset is dropped from positions until it is registered against its custom feed — but `getAdapterBalanceForAsset` / `getAdapterBalances` still return the raw owed value (they don't consult the registry). The fork test registers stETH + native ETH directly in its harness, so §7's legs are unaffected.

### Math — one leg per request, with a two-gate claimable/locked flag (ADR 0016)

The no-arg balance getters (`_owedForAsset`) return a straight sum of `expectedAssetAmount`
across an asset's open requests. `getAdapterPositions` instead emits **one leg per open request**,
all under the static `positionId = abi.encode(address(WITHDRAWAL_MANAGER))` (the payout asset is
carried in `balanceAsset.asset`) and distinguished by the request's `userNonce` in
`positionInstanceId`. Each leg's `isLocked` flag uses the two-gate claimability predicate (matching
`LRTWithdrawalManager.completeWithdrawal`):

```text
(begin, end) = WITHDRAWAL_MANAGER.userAssociatedNonces(asset, account)   # OZ DoubleEndedQueue cursors
count  = end - begin                                                     # no cap; claimed requests are popped off the front
cursor = WITHDRAWAL_MANAGER.nextLockedNonce(asset)
delay  = WITHDRAWAL_MANAGER.withdrawalDelayBlocks()
pid    = abi.encode(WITHDRAWAL_MANAGER)   # static; payout asset is in balanceAsset.asset
for i in 0 .. count-1:
    (_, owed, startBlock, userNonce) = getUserWithdrawalRequest(asset, account, i)
    if owed == 0: continue
    unlocked = (userNonce < cursor) && (block.number >= startBlock + delay)   # BOTH gates
    emit PositionBalance(asset, owed, Supplied, positionId=pid,
                         isLocked=!unlocked, positionInstanceId=bytes32(userNonce))
# per supported+registered asset
```

The previous app hook treated a request as claimable on the nonce cursor alone, omitting the
block-delay gate — a false-positive class matching a Sherlock-audited finding; the two-gate
predicate above corrects it (ADR 0016).

`userAssociatedNonces` is the public getter of an OZ `DoubleEndedQueue.Uint256Deque`; the open-request count is `end - begin`, and `getUserWithdrawalRequest(.., i)` resolves to the deque's `.at(i)` — claimed requests are popped off the front, so this only ever counts live claims (no out-of-bounds probing). There is no adapter-level cap — the full open-request set is summed, since a large count is self-inflicted (Kelp requests are keyed to the unstaking `msg.sender`, so a third party cannot inflate another account's queue) and truncating would silently under-report a real balance.

## 2. Existing fork test coverage

`test/balances/BalanceAdapters/fork/KelpWithdrawalQueueBalanceAdapter.fork.t.sol` already had `KelpWithdrawalQueueBalanceAdapterForkTest` covering the Slack-incident holder `0x99b9F5…` (one open **stETH** request, 160.44 stETH) @ block `25_094_940`, plus the position **vanishing after claim** @ `25_150_000`, and empty / unknown-holder / unsupported-asset / asset-filter-mismatch / interface / immutables.

The unit test (`test/balances/BalanceAdapters/KelpWithdrawalQueueBalanceAdapter.t.sol`) covers the mock-only edges: constructor reverts, single/multi-request summing, the **no-cap full summing** of a large request list, the **claimed-front skip** (deque pop), **multi-asset** balances + positions, the **registered-vs-unregistered drop**, and the asset filter.

All kept as regression nets.

## 3. What this case adds

The original fork suite only ever exercised a **single stETH request**. This case adds a **fresh single-holder pin at block `25_331_379`** (`KelpWithdrawalQueueBalanceAdapterForkTest_Fresh`) — augments, doesn't replace — that exercises, against the real contract, the features only mocks covered before:

- **Multi-asset, per-request emission** — `getAdapterPositions` returns **three legs** (two stETH requests + one native-ETH request) from one adapter.
- **Multiple open requests within an asset** — the holder has two open stETH requests, each its own leg, that reconstruct the per-asset aggregate when summed.
- **Native-ETH payout** — the native-ETH leg (sentinel-registered, like Lido).

Plus this evidence pack and a **per-request-id drill-down** in the dev dashboard (§9).

## 4. Adapter formula recap

See §1. One `Supplied` leg per open request, for every supported + NAV-registered asset; each leg's `amount = expectedAssetAmount` for that request, and the per-asset legs sum to `Σ expectedAssetAmount` over the account's live requests for that asset (no cap — the full open-request set is summed).

## 5. Cherry-picked accounts

| Holder | Address | Covers | Rationale |
|---|---|---|---|
| `MULTI_ASSET` | `0x13833b44341288dF27cc85e3eFDA8CD3830a4d35` | multi-asset + multi-request + native ETH | Two open stETH requests (nonces 7177 + 7203) **and** one open native-ETH request (nonce 5937) → three per-request legs from one adapter, the two stETH legs reconstructing the per-asset aggregate when summed. Fewest accounts, every gap. |

### Setup

| Field | Value |
|---|---|
| Chain | Ethereum mainnet (chainId 1) |
| Block | **25,331,379** |
| Block timestamp | 1781628491 (`0x6a317e4b`) — **2026-06-16 16:48:11 UTC** |
| LRTWithdrawalManager | `0x62De59c08eB5dAE4b7E6F7a8cAd3006d6965ec16` |
| LRTConfig | `0x947Cb49334e6571ccBFEF1f1f1178d8469D65ec7` |
| Supported assets | stETH, ETHx, native ETH |
| Lock cursors at block | `nextLockedNonce(stETH) = 7098`, `nextLockedNonce(ETH) = 5831` (holder's nonces 7177/7203/5937 all above → all **pending**) |
| Adapter under test | `KelpWithdrawalQueueBalanceAdapter` |
| Fork-test contract | `KelpWithdrawalQueueBalanceAdapterForkTest_Fresh` |

## 6. Case files in this folder

| File | Purpose |
|---|---|
| `case-real-holders-mainnet.json` | Machine-readable evidence pack: holder, per-asset legs, request nonces, owed amounts, identity, ground-truth method |
| `query-live-balances.s.sol` | Forge script that deploys the adapter against a dev NAV and prints the holder's per-asset legs |
| `script/development/deploy/deploy-kelp-withdrawal-queue.sh` | Dev-anvil deploy helper: `forge create` the adapter + `addBalanceAdapters([adapter])` on the local NAV |

## 7. Expected balances

### 7a. Per-leg detail (one leg per open request)

| Holder | Request nonce (`positionInstanceId`) | Kind | Token | Amount (raw) | Amount (humanised) |
|---|---|---|---|---|---|
| `0x13833b44…` | 7177 | Supplied | stETH | `322038966142406605154` | 322.038966142406605154 stETH |
| `0x13833b44…` | 7203 | Supplied | stETH | `332890371974143452160` | 332.890371974143452160 stETH |
| `0x13833b44…` | 5937 | Supplied | ETH | `10734990037748145` | 0.010734990037748145 ETH |

### 7b. Per-asset summary

| Holder | Token | Total (raw) | isDebt |
|---|---|---|---|
| `0x13833b44…` | stETH | `654929338116550057314` | false |
| `0x13833b44…` | ETH | `10734990037748145` | false |

`getAdapterPositions` emits these three legs (two stETH + one native ETH); `getAdapterBalanceForAsset(holder, asset)` returns the per-asset total, which equals the sum of that asset's legs. ETHx is not emitted (no request + unregistered on the dev NAV).

## 8. Ground-truth cross-check

Live reads of Kelp's own LRTWithdrawalManager (no closed-form re-derivation):

| Leg | Check |
|---|---|
| stETH | `userAssociatedNonces(stETH, holder) == (1, 3)`; `adapter == Σ getUserWithdrawalRequest(stETH, holder, i).expectedAssetAmount` for `i ∈ {0,1}`. |
| native ETH | `adapter == getUserWithdrawalRequest(ETH, holder, 0).expectedAssetAmount`. |

Multi-asset emission, summing, the claimed-front skip (deque pop), the no-cap full summing, and the registered-vs-unregistered drop are also exercised with mocks in `test/balances/BalanceAdapters/KelpWithdrawalQueueBalanceAdapter.t.sol`. The tests assert `protocolId == keccak256("kelp")` and `protocolSubId == keccak256("kelp-withdrawal")`, `positionId == abi.encode(address(WITHDRAWAL_MANAGER))` (payout asset in `balanceAsset.asset`), `PositionKind.Supplied`, the per-request `isLocked` flag (the two-gate claimable/locked predicate) with the `userNonce` in `positionInstanceId`, and `balanceAdapter == address(this)`.

## 9. Wiring the live dev-anvil dashboard

`script/development/deploy/deploy-kelp-withdrawal-queue.sh` deploys + registers the adapter on the local mainnet anvil. Native ETH is registered on the NAV at bootstrap, but **stETH and ETHx are not** — both are Custom-primary and `register-assets.sh` registers only Chainlink-first assets — so out of the box only the native-ETH leg renders; register stETH against its custom feed to see its legs too. To pin the dev anvil at the verification block (so the dashboard matches §7 exactly):

```bash
anvil --fork-url <MAINNET_URL> --fork-block-number 25331379 --chain-id 1 --port 8545 \
      --state script/development/state/1.json --state-interval 60 &
bash script/development/deploy/deploy.sh 1                       # NAV + Chainlink assets (native ETH; stETH is Custom-primary → skipped)
bash script/development/deploy/deploy-kelp-withdrawal-queue.sh 1
bash script/development/app/sync-app-env.sh 1
# then start the Next.js dev server in app/
```

The position renders under **Kelp DAO** (the adapter's `protocolName()`) as **Supplied legs** across two payout assets — stETH and native ETH (stETH only once it is registered, per the note above). The holder is an arbitrary on-chain staker (not a tracked NAV account), so its NAV *total* also includes unrelated wallet positions — cross-check the **Kelp legs** specifically.

**Per-request-id drill-down (display only).** Each Kelp asset renders per-request sub-rows — one per Kelp **request** (Kelp's identifier is the request's `userNonce` within its asset queue, not an ERC721 NFT), with its id, amount, price, USD value, %, and a Claimable / Pending badge (claimable once `userNonce < nextLockedNonce(asset)`). This is re-derived client-side from the LRTWithdrawalManager (app hook `app/src/hooks/use-kelp-withdrawals.ts`, rendered in `protocol-group.tsx`) and does **not** change NAV. It shares the same generic withdrawal-row rendering as Lido/Stader, but — because Kelp is multi-asset — the drill-down map is keyed by `chainId:oracle:asset` (the asset is required so the stETH and native-ETH requests don't cross-contaminate). For `0x13833b44…` the stETH rows are `↳ #7177` + `↳ #7203` (both Pending) and the native-ETH row is `↳ #5937` (Pending).

> ⚠ **Freshness:** these requests can be claimed by the owner at any time after `25_331_379`, which would zero the corresponding leg. Re-confirm the holder on-chain right before a live cross-check if material time has passed.

## 10. Test verdict

| Aspect | Status |
|---|---|
| Multi-asset, per-request emission — one `Supplied` leg per open request, across supported + registered assets | ✅ (two stETH legs + one native-ETH leg, real fork) |
| Multiple open requests within an asset (legs sum to the aggregate) | ✅ (stETH, two requests, real fork) |
| Native-ETH payout (sentinel-registered) | ✅ (real fork) |
| Asset filter narrows to one asset's legs | ✅ (native-ETH filter → one leg) |
| Claimed-front skip (deque pop); no-cap full summing; registered-vs-unregistered drop | ✅ (unit test, mocks) |
| Position vanishes after claim | ✅ (original fork suite) |
| Identity: `protocolId == kelp`, `protocolSubId == kelp-withdrawal`, `positionId == abi.encode(address(WITHDRAWAL_MANAGER))` (payout asset in `balanceAsset.asset`), `Supplied`, per-request `isLocked` flag with `userNonce` in `positionInstanceId` | ✅ |
| Mainnet-only scope | ✅ |

**Mainnet: Kelp WQ fork suites pass (original incident + fresh multi-asset pin).** Single mainnet deployment → no cross-chain surface. Kelp rsETH withdrawal queue is verified.

Run via:

```bash
FOUNDRY_PROFILE=slow forge test --match-path "test/balances/BalanceAdapters/fork/KelpWithdrawalQueueBalanceAdapter.fork.t.sol" -vv
```
