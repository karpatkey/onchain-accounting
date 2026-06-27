# Kelp DAO rsETH Withdrawal Queue — balance-adapter verification

## 1. Adapter under test

`src/balances/BalanceAdapters/KelpWithdrawalQueueBalanceAdapter.sol` — the immutable `KelpWithdrawalQueueBalanceAdapter`. Constructor: `(withdrawalManager, navCalculator)` where `withdrawalManager = Kelp LRTWithdrawalManager` (`0x62De59c08eB5dAE4b7E6F7a8cAd3006d6965ec16`). Identity is derived on-chain: `positionId = ""` (account-global), `protocolId = keccak256("kelp-withdrawal")`, `positionKind = Supplied`.

### Inheritance + per-chain scope (Phase 0)

- **Inheritance:** none — implements `IBalanceAdapter` + `IPositionDescribable` directly. No base contract, no overrides.
- **Per-chain scope:** Kelp's `LRTWithdrawalManager` is **mainnet-only**. So mainnet (chainId 1) is the only chain that enables `KelpWithdrawalQueue` — see `script/config/nav-config/balance-adapters/1.json` and `script/config/contracts-deployment-config/balance-adapters/1.json`. A single mainnet fork test suffices.
- **Multi-asset (the distinguishing feature):** when a user unstakes rsETH, the rsETH is burned and a per-`(asset, user)` request is recorded denominated in the LST the user chose to receive. Kelp's payout assets are **discovered at runtime** from `lrtConfig().getSupportedAssetList()` — at the fork block: **stETH** (`0xae7a…`), **ETHx** (`0xA35b…`), **native ETH** (`0xEeee…`, ERC-7528 sentinel). The adapter emits **one `Supplied` leg per asset** with non-zero owed that is also registered in NAV.
- **Registration gating (asymmetric, same as sGHO / Aave Umbrella / Lido / Stader):** `getAdapterPositions` drops any asset not registered on NAVCalculator (registered-asset intersection). On the dev NAV, stETH and native ETH are registered; **ETHx is not** (it uses a custom feed the dev `deploy.sh` skips), so an ETHx request is dropped from positions — but `getAdapterBalanceForAsset` / `getAdapterBalances` still return its raw owed value (they don't consult the registry).

### Math (`_owedForAsset`) — no value branches

Per asset, the owed value is a straight sum, so there is **no value-branch split** like Lido/Stader:

```
(begin, end) = WITHDRAWAL_MANAGER.userAssociatedNonces(asset, account)   # OZ DoubleEndedQueue cursors
count = min(end - begin, MAX_REQUESTS_PROBED)                            # claimed requests are popped off the front
for i in 0 .. count-1:
    total += getUserWithdrawalRequest(asset, account, i).expectedAssetAmount
emit one Supplied leg (asset, total) per supported+registered asset with total > 0
```

`userAssociatedNonces` is the public getter of an OZ `DoubleEndedQueue.Uint256Deque`; the open-request count is `end - begin`, and `getUserWithdrawalRequest(.., i)` resolves to the deque's `.at(i)` — claimed requests are popped off the front, so this only ever counts live claims (no out-of-bounds probing, unlike Stader). The cap bounds gas.

## 2. Existing fork test coverage

`test/balances/protocols/fork/KelpWithdrawalQueueBalanceAdapter.fork.t.sol` already had `KelpWithdrawalQueueBalanceAdapterForkTest` covering the Slack-incident holder `0x99b9F5…` (one open **stETH** request, 160.44 stETH) @ block `25_094_940`, plus the position **vanishing after claim** @ `25_150_000`, and empty / unknown-holder / unsupported-asset / asset-filter-mismatch / interface / immutables.

The unit test (`test/balances/protocols/KelpWithdrawalQueueBalanceAdapter.t.sol`) covers the mock-only edges: constructor reverts, single/multi-request summing, the **256 cap**, the **claimed-front skip** (deque pop), **multi-asset** balances + positions, the **registered-vs-unregistered drop**, and the asset filter.

All kept as regression nets.

## 3. What this case adds

The original fork suite only ever exercised a **single stETH request**. This case adds a **fresh single-holder pin at block `25_331_379`** (`KelpWithdrawalQueueBalanceAdapterForkTest_Fresh`) — augments, doesn't replace — that exercises, against the real contract, the features only mocks covered before:

- **Multi-asset emission** — `getAdapterPositions` returns **two legs** (stETH + native ETH) from one adapter.
- **Multi-request summing within an asset** — the stETH leg sums two open requests.
- **Native-ETH payout** — the native-ETH leg (sentinel-registered, like Lido).

Plus this evidence pack and a **per-request-id drill-down** in the dev dashboard (§9).

## 4. Adapter formula recap

See §1. One `Supplied` leg per supported + NAV-registered asset; `amount = Σ expectedAssetAmount` over the account's live requests for that asset (capped at 256).

## 5. Cherry-picked accounts

| Holder | Address | Covers | Rationale |
|---|---|---|---|
| `MULTI_ASSET` | `0x13833b44341288dF27cc85e3eFDA8CD3830a4d35` | multi-asset + multi-request + native ETH | Two open stETH requests (nonces 7177 + 7203) **and** one open native-ETH request (nonce 5937) → two legs from one adapter, the stETH leg summed across two requests. Fewest accounts, every gap. |

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

### 7a. Per-leg detail

| Holder | Asset leg | Open requests (nonce: owed) | Leg | Token | Total (raw) | Total (humanised) |
|---|---|---|---|---|---|---|
| `0x13833b44…` | stETH | 7177: `322038966142406605154` + 7203: `332890371974143452160` | Supplied | stETH | `654929338116550057314` | 654.929338116550057314 stETH |
| `0x13833b44…` | native ETH | 5937: `10734990037748145` | Supplied | ETH | `10734990037748145` | 0.010734990037748145 ETH |

### 7b. Per-asset summary

| Holder | Token | Total (raw) | isDebt |
|---|---|---|---|
| `0x13833b44…` | stETH | `654929338116550057314` | false |
| `0x13833b44…` | ETH | `10734990037748145` | false |

`getAdapterPositions` emits these two legs; `getAdapterBalanceForAsset(holder, asset)` returns the same per-asset total. ETHx is not emitted (no request + unregistered on the dev NAV).

## 8. Ground-truth cross-check

Live reads of Kelp's own LRTWithdrawalManager (no closed-form re-derivation):

| Leg | Check |
|---|---|
| stETH | `userAssociatedNonces(stETH, holder) == (1, 3)`; `adapter == Σ getUserWithdrawalRequest(stETH, holder, i).expectedAssetAmount` for `i ∈ {0,1}`. |
| native ETH | `adapter == getUserWithdrawalRequest(ETH, holder, 0).expectedAssetAmount`. |

Multi-asset emission, summing, the claimed-front skip (deque pop), the 256 cap, and the registered-vs-unregistered drop are also exercised with mocks in `test/balances/protocols/KelpWithdrawalQueueBalanceAdapter.t.sol`. The tests assert `protocolId == keccak256("kelp-withdrawal")`, `positionId == ""`, `PositionKind.Supplied`, and `balanceAdapter == address(this)`.

## 9. Wiring the live dev-anvil dashboard

`script/development/deploy/deploy-kelp-withdrawal-queue.sh` deploys + registers the adapter on the local mainnet anvil. stETH and native ETH are registered on the NAV at bootstrap, so both legs render; ETHx is skipped (custom feed). To pin the dev anvil at the verification block (so the dashboard matches §7 exactly):

```bash
anvil --fork-url <MAINNET_URL> --fork-block-number 25331379 --chain-id 1 --port 8545 \
      --state script/development/state/1.json --state-interval 60 &
bash script/development/deploy/deploy.sh 1                       # NAV + Chainlink assets (incl. stETH + native ETH)
bash script/development/deploy/deploy-kelp-withdrawal-queue.sh 1
bash script/development/app/sync-app-env.sh 1
# then start the Next.js dev server in app/
```

The position renders under **Kelp DAO** (the adapter's `protocolName()`) as **two Supplied legs** — one stETH, one ETH. The holder is an arbitrary on-chain staker (not a tracked NAV account), so its NAV *total* also includes unrelated wallet positions — cross-check the **Kelp legs** specifically.

**Per-request-id drill-down (display only).** Each Kelp leg renders sub-rows beneath it — one per Kelp **request** (Kelp's identifier is the request's `userNonce` within its asset queue, not an ERC721 NFT), with its id, amount, price, USD value, %, and a Claimable / Pending badge (claimable once `userNonce < nextLockedNonce(asset)`). This is re-derived client-side from the LRTWithdrawalManager (app hook `app/src/hooks/use-kelp-withdrawals.ts`, rendered in `protocol-group.tsx`) and does **not** change NAV. It shares the same generic withdrawal-row rendering as Lido/Stader, but — because Kelp is multi-asset — the drill-down map is keyed by `chainId:oracle:asset` (the asset is required so the stETH and native-ETH legs don't cross-contaminate). For `0x13833b44…` the stETH leg shows `↳ #7177` + `↳ #7203` (both Pending) and the native-ETH leg shows `↳ #5937` (Pending).

> ⚠ **Freshness:** these requests can be claimed by the owner at any time after `25_331_379`, which would zero the corresponding leg. Re-confirm the holder on-chain right before a live cross-check if material time has passed.

## 10. Test verdict

| Aspect | Status |
|---|---|
| Multi-asset emission — one `Supplied` leg per supported + registered asset | ✅ (stETH + native-ETH legs, real fork) |
| Multi-request summing within an asset | ✅ (stETH, two requests, real fork) |
| Native-ETH payout (sentinel-registered) | ✅ (real fork) |
| Asset filter narrows to one leg | ✅ |
| Claimed-front skip (deque pop); 256 cap; registered-vs-unregistered drop | ✅ (unit test, mocks) |
| Position vanishes after claim | ✅ (original fork suite) |
| Identity: `protocolId == kelp-withdrawal`, `positionId == ""`, `Supplied` | ✅ |
| Mainnet-only scope | ✅ |

**Mainnet: Kelp WQ fork suites pass (original incident + fresh multi-asset pin).** Single mainnet deployment → no cross-chain surface. Kelp rsETH withdrawal queue is verified.

Run via:

```bash
FOUNDRY_PROFILE=slow forge test --match-path "test/balances/protocols/fork/KelpWithdrawalQueueBalanceAdapter.fork.t.sol" -vv
```
