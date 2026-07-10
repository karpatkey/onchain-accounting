# Stader ETHx Withdrawal Queue — balance-adapter verification

## 1. Adapter under test

`src/balances/BalanceAdapters/StaderWithdrawalQueueBalanceAdapter.sol` — the immutable `StaderWithdrawalQueueBalanceAdapter`. Constructor: `(userWithdrawalManager, underlyingToken, navCalculator)` where `userWithdrawalManager = Stader UserWithdrawalManager` (`0x9F0491B32DBce587c50c4C43AB303b06478193A7`) and `underlyingToken = WETH` (`0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`). Identity is derived on-chain: `positionId = abi.encode(address userWithdrawalManager)` (static; **one leg per open request**, all sharing it, distinguished by the typed `positionInstanceId = bytes32(requestId)` and with each leg's `isLocked` reflecting that request's state — finalized → `false`, pending → `true` ([ADR 0016](../../../../docs/decisions/0016-islocked-position-status.md))), `protocolBrand = keccak256("stader")`, `protocolId = keccak256("stader")`, `protocolSubId = keccak256("stader-withdrawal")`, `positionKind = Supplied`.

### Inheritance + per-chain scope (Phase 0)

- **Inheritance:** `StaderWithdrawalQueueBalanceAdapter` extends `SingleAssetBalanceAdapterBase` (→ `BalanceAdapterBase`) and implements `IPositionDescribable`. The base pins `UNDERLYING_TOKEN` and provides the no-position getter triad (`underlyingAssetsSupported` / `getAdapterBalanceForAsset` / `getAdapterBalances`) off the `_owedAmount(account)` hook; the adapter implements `_owedAmount`, `getAdapterPositions`, and the `IPositionDescribable` hooks (`protocolName` / `positionLabels`).
- **Per-chain scope:** Stader's `UserWithdrawalManager` is **mainnet-only**. So mainnet (chainId 1) is the only chain that enables `StaderWithdrawalQueue` — see `script/config/nav-config/balance-adapters/1.json` and `script/config/contracts-deployment-config/balance-adapters/1.json`. A single mainnet fork test is sufficient; no per-chain branches.
- **Denomination — WETH, not ETHx:** when a user requests an unstake, **ETHx is burned** and a sequential request id is recorded; the claim later pays out **native ETH**. The adapter denominates the queued position in WETH and NAV prices it via **ETH/USD**, so an ETHx exchange-rate move can't mis-value a claim whose ETH amount is already fixed (finalized) or is capped down to the live rate (pending, see below). While queued, the value is invisible to wallet/receipt-token oracles — this adapter is the only thing that surfaces it.
- **On-chain enumeration — no adapter-level cap:** the adapter reads the account's live request ids in one call, `getRequestIdsByUser(account)`. Stader prunes an id from that array on claim (swap-and-pop in `deleteRequestId`) and caps it at `maxNonRedeemedUserRequestCount` (**1000** on mainnet), so the array holds only open (un-claimed) requests and is protocol-bounded — the adapter applies no cap of its own and reads every entry. Anyone can plant a request owned by this account by burning their own ETHx, but they donate that ETH and cannot recover it, so the injected value is real, claimable, and self-funded; reporting it fully is the honest, over-report-safe answer. The only residual is gas: a queue griefed toward the 1000 ceiling makes **that account's** NAV read expensive (liveness-only, never a mis-valuation) — see the contract NatSpec and `docs/operations/stader-withdrawal-queue-griefing.md`.
- **Per-request owner re-check:** every id read back from the enumeration is re-verified against its on-chain `owner` in `userWithdrawRequests(id)`; a request whose recorded owner is not `account` contributes 0, so a stale/foreign id in the array can never inflate the balance.

### Math branches (`_owedForRequest`)

`_owedAmount` sums `_owedForRequest` across the account's open (un-claimed) requests:

- **finalized** request (`ethFinalized > 0`) → use `ethFinalized` (the exact ETH owed once the batch is finalized).
- **not yet finalized** (`ethFinalized == 0`) → the **conservative** `min(ethExpected, previewWithdraw(ethXAmount))`: `ethExpected` is frozen at request time, so a later ETHx/ETH rate drop (slashing / exit penalty) would leave it overstating the true owed amount until finalization — the live `StaderStakePoolsManager.previewWithdraw(ethXAmount)` re-conversion caps it down (mirrors the Lido adapter's `_cappedOwed`). Fail-open: if the live read reverts, it falls back to `ethExpected`.
- a request whose recorded `owner != account` (a claimed/unknown id, or a foreign id sitting in the array) contributes **0** — the defensive per-request owner re-check.

Registration gating is asymmetric (same as sGHO / Aave Umbrella / Lido WQ): `getAdapterPositions` drops the leg if WETH isn't registered on NAVCalculator (registered-asset intersection — the "discard if no price" policy), whereas the balance methods (`getAdapterBalanceForAsset` / `getAdapterBalances`) do **not** consult the registry and still return the value.

## 2. Existing fork test coverage

`test/balances/BalanceAdapters/fork/StaderWithdrawalQueueBalanceAdapter.fork.t.sol` already had `StaderWithdrawalQueueBalanceAdapterForkTest` covering the **pending** branch against the real contract:
- un-finalized holder `0x5066bc62…` (id 8056, `ethExpected = 37.440331321957283515 ETH`, `ethFinalized = 0`) @ block `25_015_000`.
- plus zero-address / unknown-holder / unsupported-asset / asset-filter-mismatch / interface / immutables.

The unit test (`test/balances/BalanceAdapters/StaderWithdrawalQueueBalanceAdapter.t.sol`) covers the mock-only edges: constructor reverts, `ethExpected` vs `ethFinalized` preference, the **live-rate pending cap** (`min(ethExpected, previewWithdraw)`) and its **fail-open** fallback when the live read reverts, **multi-request summing**, the **per-request owner re-check** (a foreign-owned id in the enumeration contributes 0), the **no-cap full read** of a large (600-request) queue, wrong-asset / asset-filter-mismatch, and the `IPositionDescribable` / ERC165 surface.

All kept as regression nets.

## 3. What this case adds

- A **fresh three-holder pin at the verification block `25_330_819`** (`StaderWithdrawalQueueBalanceAdapterForkTest_Fresh`) — augments, doesn't replace. One holder per case (PENDING, FINALIZED, MULTI — see §5), at minutes-fresh state, so the dev-anvil dashboard (§9) shows live-relevant positions for a side-channel cross-check. The original suite only exercised `ethExpected`; the new finalized holder exercises `ethFinalized` **and proves it is preferred** (its `ethFinalized` is 9 wei below its `ethExpected`), and the MULTI holder exercises real on-chain multi-request summing.
- This evidence pack: README + case JSON + query script + dev deploy helper, bringing Stader WQ up to the same 10-section structure as the other verified protocols.

## 4. Adapter formula recap

```text
# static positionId shared by every leg:
pid = abi.encode(address(USER_WITHDRAWAL_MANAGER))
ids = USER_WITHDRAWAL_MANAGER.getRequestIdsByUser(account)   # live, claim-pruned, protocol-capped at 1000
for id in ids:                                        # no adapter-level cap
    (owner, ethXAmount, ethExpected, ethFinalized, _) = userWithdrawRequests(id)
    if owner != account:               continue       # foreign / claimed id — contributes 0
    if ethFinalized > 0: amount = ethFinalized;                          locked = false  # finalized → claimable
    else:                amount = min(ethExpected, previewWithdraw(ethXAmount)); locked = true   # pending → locked
    if amount == 0:                    continue        # skip zero-amount legs
    # one PositionBalance per open request, sharing pid, keyed by positionInstanceId:
    emit PositionBalance(WETH, amount, isDebt=false, Supplied,
                         positionId=pid, isLocked=locked, positionInstanceId=bytes32(id))
# (positions emitted only when WETH is registered; the balance methods sum every request's amount)
```

## 5. Cherry-picked accounts

| Holder | Address | Branch | Rationale |
|---|---|---|---|
| `PENDING` | `0x4D0B2dB7d38009884c3f2a15c1c212f4F4a356c9` | `ethExpected` | One PENDING (un-finalized) request 8218 (`ethFinalized == 0`) → exercises the request-time estimate branch. |
| `FINALIZED` | `0x404186e63CA9e1D0648a5AEc0b77cD398814C47D` | `ethFinalized` | One FINALIZED-unclaimed request 8214 where `ethFinalized` (…347) is **9 wei below** `ethExpected` (…356) → exercises the finalized branch **and** proves it wins over the estimate. |
| `MULTI` | `0xeB0CBBA408436997AfD29c50d6A9ffcCf9a2493f` | `ethFinalized` (×2) | Two open requests (8196 + 8197), both finalized → exercises the **enumeration loop emitting one claimable (`isLocked=false`) leg per request** on a real fork (previously only mock-tested); the legs sum to the holder's aggregate balance. Not a distinct value branch — both requests are `ethFinalized`. Also the holder used to demo the per-request-id dashboard drill-down (§9). |

### Setup

| Field | Value |
|---|---|
| Chain | Ethereum mainnet (chainId 1) |
| Block | **25,330,819** |
| Block timestamp | 1781621771 (`0x6a31640b`) — **2026-06-16 14:56:11 UTC** |
| UserWithdrawalManager | `0x9F0491B32DBce587c50c4C43AB303b06478193A7` |
| Underlying (WETH) | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| Queue state at block | nextRequestId 8219, nextRequestIdToFinalize 8215 (ids ≤ 8214 finalized, 8215–8218 pending) |
| Adapter under test | `StaderWithdrawalQueueBalanceAdapter` |
| Fork-test contract | `StaderWithdrawalQueueBalanceAdapterForkTest_Fresh` in `test/balances/BalanceAdapters/fork/StaderWithdrawalQueueBalanceAdapter.fork.t.sol` |

## 6. Case files in this folder

| File | Purpose |
|---|---|
| `case-real-holders-mainnet.json` | Machine-readable evidence pack: all three holders, request ids, ETH owed, identity, ground-truth method |
| `query-live-balances.s.sol` | Forge script that deploys the adapter against a dev NAV and prints all three holders' WETH legs for ad-hoc cross-checks |
| `script/development/deploy/deploy-stader-withdrawal-queue.sh` | Dev-anvil deploy helper: `forge create` the adapter + `addBalanceAdapters([adapter])` on the local NAV |

## 7. Expected balances

One leg per open request, all denominated in WETH (so PENDING and FINALIZED show a single leg, MULTI shows two). Captured at the fork block in §5.

### 7a. Per-leg detail

| Holder | Request (open, un-claimed) | Leg | Token | ETH owed (raw) | ETH (humanised) | branch |
|---|---|---|---|---|---|---|
| `0x4D0B2dB7…` | 8218 (`ethExpected`, not finalized) | Supplied (`isLocked=true`) | WETH | `179475428570970280827` | 179.475428570970280827 ETH | `ethExpected` |
| `0x404186e6…` | 8214 (`ethFinalized`, finalized) | Supplied (`isLocked=false`) | WETH | `10804926562492357347` | 10.804926562492357347 ETH | `ethFinalized` |
| `0xeB0CBBA4…` | 8196 (finalized) | Supplied (`isLocked=false`) | WETH | `109058136469367` | 0.000109058136469367 ETH | `ethFinalized` |
| `0xeB0CBBA4…` | 8197 (finalized) | Supplied (`isLocked=false`) | WETH | `218116272938735` | 0.000218116272938735 ETH | `ethFinalized` |

### 7b. Per-asset summary

| Holder | Token | Total (raw) | Total (humanised) | isDebt |
|---|---|---|---|---|
| `0x4D0B2dB7…` | WETH | `179475428570970280827` | 179.475428570970280827 ETH | false |
| `0x404186e6…` | WETH | `10804926562492357347` | 10.804926562492357347 ETH | false |
| `0xeB0CBBA4…` | WETH | `327174409408102` | 0.000327174409408102 ETH (sum of 8196 + 8197) | false |

`getAdapterBalanceForAsset(holder, WETH)` and `getAdapterBalances(holder)` return this per-holder total; the per-request `getAdapterPositions` legs sum back to it.

## 8. Ground-truth cross-check

The value is a live read of Stader's own UserWithdrawalManager — there is no closed-form re-derivation, so the strongest ground truth is the manager's own per-request settlement view:

| Holder | Check |
|---|---|
| `PENDING` (un-finalized) | `adapter == userWithdrawRequests(8218).ethExpected` and `ethFinalized == 0` — the live-rate cap doesn't bite here (`previewWithdraw(ethXAmount) ≥ ethExpected` at this block), so the pending value equals `ethExpected`. |
| `FINALIZED` (finalized) | `adapter == userWithdrawRequests(8214).ethFinalized`, which is **strictly less than** that request's `ethExpected` (…347 < …356) — proving the branch precedence. |
| `MULTI` (two requests) | `aggregate balance == userWithdrawRequests(8196).ethFinalized + userWithdrawRequests(8197).ethFinalized` — both finalized, so two claimable (`isLocked=false`) legs (one per request) that sum on-chain to that total. |

The per-request owner re-check (`owner != account` → contributes 0) is exercised with mocks in `test/balances/BalanceAdapters/StaderWithdrawalQueueBalanceAdapter.t.sol` (`test_foreignOwnedRequest_contributesZero` plants a foreign-owned id in the account's enumeration), alongside the live-rate pending cap (`test_pendingRequest_cappedByLiveRate`), its fail-open fallback (`test_pendingRequest_liveRevert_failsOpenToEstimate`), and the no-cap full read of a large queue (`test_largeList_readInFull`). The tests also assert `protocolId == keccak256("stader")` and `protocolSubId == keccak256("stader-withdrawal")`, `positionId == abi.encode(userWithdrawalManager)`, `PositionKind.Supplied`, per-request legs each carrying their own `positionInstanceId` with the appropriate `isLocked`, and `balanceAdapter == address(this)`.

## 9. Wiring the live dev-anvil dashboard

`script/development/deploy/deploy-stader-withdrawal-queue.sh` deploys + registers the adapter on the local mainnet anvil so the dashboard renders all three holders' withdrawal-queue positions for a side-channel cross-check. WETH is registered on the NAV at bootstrap (`deploy.sh` registers the WETH/USD feed), so no extra asset registration is needed. To pin the dev anvil at the verification block (so the dashboard matches §7 exactly):

```bash
anvil --fork-url <MAINNET_URL> --fork-block-number 25330819 --chain-id 1 --port 8545 \
      --state script/development/state/1.json --state-interval 60 &
bash script/development/deploy/deploy.sh 1                       # NAV + Chainlink assets (incl. WETH)
bash script/development/deploy/deploy-stader-withdrawal-queue.sh 1
bash script/development/app/sync-app-env.sh 1
# then start the Next.js dev server in app/
```

The position renders under **Stader** as one **Supplied** leg per open request, denominated in WETH (PENDING and FINALIZED show one leg, MULTI shows two). The featured holders are arbitrary on-chain stakers (not tracked NAV accounts) chosen to exercise the branches; their NAV *totals* also include unrelated wallet positions, so cross-check the **Stader legs** specifically, not the account total.

**Per-request-id drill-down (display only).** The adapter emits one WETH leg per open request (all sharing one static positionId, keyed by `positionInstanceId = bytes32(requestId)`), and the dashboard renders a sub-row per Stader **request id** (Stader's identifier is a sequential `requestId`, not an ERC721 NFT like Lido), with its id, ETH amount, price, USD value, %, and a Claimable (finalized) / Pending badge. This is re-derived client-side directly from the UserWithdrawalManager (app hook `app/src/hooks/use-stader-withdrawals.ts`, rendered in `protocol-group.tsx`) and does **not** change NAV or the adapter's emitted identity — it's a reconciliation aid sharing the same generic withdrawal-row rendering as Lido. Each request is valued the **same way the adapter values it** — `ethFinalized` for finalized requests, `ethExpected` for pending — so the rows are genuine ETH amounts and the USD values, split by ETH-owed share, sum exactly back to the per-request legs. The hook caps its own probe at 256 requests (a display-only bound in `use-stader-withdrawals.ts`; the adapter itself no longer caps — it reads Stader's full, protocol-bounded (1000) request list). For the **MULTI** holder `0xeB0CBBA4…` the two legs render as `↳ #8196 (0.000109058136469367 ETH, Claimable)` + `↳ #8197 (0.000218116272938735 ETH, Claimable)`.

> ⚠ **Freshness:** `ethExpected` is fixed at request time, so the PENDING leg is stable. The FINALIZED / MULTI requests can be claimed by their owners at any time, which would zero those legs. Re-confirm the holders on-chain right before a live cross-check if material time has passed since `25_330_819`.

## 10. Test verdict

| Aspect | Status |
|---|---|
| Un-finalized requests valued via `min(ethExpected, previewWithdraw)` (live-rate cap) | ✅ (PENDING exact @ block; cap + fail-open in unit mocks) |
| Finalized requests valued via `ethFinalized`, preferred over `ethExpected` | ✅ (FINALIZED, exact + 9-wei inequality) |
| Multi-request summing across the account | ✅ (MULTI holder, real on-chain fork + unit mocks) |
| Per-request owner re-check (foreign/claimed id contributes 0); full queue read, no adapter cap | ✅ (unit test) |
| On-chain enumeration via `getRequestIdsByUser` (live, claim-pruned, protocol-bounded to 1000) | ✅ (fork + unit) |
| Identity: `protocolId == stader`, `protocolSubId == stader-withdrawal`, `positionId == abi.encode(userWithdrawalManager)`, `Supplied`, one leg per request keyed by `positionInstanceId` with per-request `isLocked`, WETH-denominated | ✅ |
| Mainnet-only scope (manager not on other chains) | ✅ |

**Mainnet: Stader WQ fork suites pass (both branches, original + fresh pins).** Single mainnet deployment → no cross-chain surface. Stader ETHx withdrawal queue is verified.

Run via:

```bash
FOUNDRY_PROFILE=slow forge test --match-path "test/balances/BalanceAdapters/fork/StaderWithdrawalQueueBalanceAdapter.fork.t.sol" -vv
```
