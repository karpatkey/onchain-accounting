# Stader ETHx Withdrawal Queue — balance-adapter verification

## 1. Adapter under test

`src/balances/protocols/StaderWithdrawalQueue.sol` — the immutable `StaderWithdrawalQueueBalanceAdapter`. Constructor: `(userWithdrawalManager, underlyingToken, navCalculator)` where `userWithdrawalManager = Stader UserWithdrawalManager` (`0x9F0491B32DBce587c50c4C43AB303b06478193A7`) and `underlyingToken = WETH` (`0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`). Identity is derived on-chain: `positionId = ""` (account-global — a holder has at most one aggregate queue position), `protocolId = keccak256("stader-withdrawal")`, `positionKind = Supplied`.

### Inheritance + per-chain scope (Phase 0)

- **Inheritance:** none — `StaderWithdrawalQueueBalanceAdapter` implements `IBalanceAdapter` + `IPositionDescribable` directly. No base contract, no overrides.
- **Per-chain scope:** Stader's `UserWithdrawalManager` is **mainnet-only**. So `chains/1.json` is the only chain config with `StaderWithdrawalQueue`. A single mainnet fork test is sufficient; no per-chain branches.
- **Denomination — WETH, not ETHx:** when a user requests an unstake, **ETHx is burned** and a sequential request id is recorded; the claim later pays out **native ETH**. The adapter denominates the queued position in WETH and NAV prices it via **ETH/USD**, so an ETHx exchange-rate move can't mis-value a claim whose ETH amount is already fixed. While queued, the value is invisible to wallet/receipt-token oracles — this adapter is the only thing that surfaces it.
- **Gas bound (anti-DoS):** the adapter probes `requestIdsByUserAddress(account, i)` from `i = 0` and **caps at `MAX_REQUESTS_PROBED = 256`**, so a crafted account with a huge request array can't OOG the NAV read (an OOG is **not** caught by NAVCalculator's try/catch). A real account never approaches the cap.
- **Enumeration end — two sentinels:** the auto-generated array getter signals "past the end" differently across compiler eras. The adapter treats **Panic(0x32)** (modern ≥0.8) *and* a **bare empty revert** (legacy Stader deployment) as the end-of-list sentinel; any other panic surfaces as `UnexpectedPanic(code)` and any other revert-with-data is re-thrown, so the adapter never silently undercounts NAV.

### Math branches (`_ethOwed`)

Summed across the account's open (un-claimed) requests:

- **finalized** request (`ethFinalized > 0`) → use `ethFinalized` (the exact ETH owed once the batch is finalized).
- **not yet finalized** (`ethFinalized == 0`) → fall back to `ethExpected` (the rate-converted estimate at request time; the redemption rate isn't fixed until finalization).
- `owner == address(0)` (already claimed; storage entry deleted but the id may still sit in the user's index array) is **skipped**.

Registration gating is asymmetric (same as sGHO / Aave Umbrella / Lido WQ): `getAdapterPositions` drops the leg if WETH isn't registered on NAVCalculator (registered-asset intersection — the "discard if no price" policy), whereas the balance methods (`getAdapterBalanceForAsset` / `getAdapterBalances`) do **not** consult the registry and still return the value.

## 2. Existing fork test coverage

`test/balances/protocols/fork/StaderWithdrawalQueue.fork.t.sol` already had `StaderWithdrawalQueueBalanceAdapterForkTest` covering the **pending** branch against the real contract:
- un-finalized holder `0x5066bc62…` (id 8056, `ethExpected = 37.440331321957283515 ETH`, `ethFinalized = 0`) @ block `25_015_000`.
- plus zero-address / unknown-holder / unsupported-asset / asset-filter-mismatch / interface / immutables.

The unit test (`test/balances/protocols/StaderWithdrawalQueue.t.sol`) covers the mock-only edges: constructor reverts, `ethExpected` vs `ethFinalized` preference, **multi-request summing**, **claimed-skip** (`owner == 0`), unregistered underlying, and **both enumeration-end sentinels** (non-OOB panic → `UnexpectedPanic`; non-empty revert re-thrown).

All kept as regression nets.

## 3. What this case adds

- A **fresh dual-holder pin at the verification block `25_330_819`** (`StaderWithdrawalQueueBalanceAdapterForkTest_Fresh`) — augments, doesn't replace. One holder per branch, at minutes-fresh state, so the dev-anvil dashboard (§9) shows live-relevant positions for a side-channel cross-check. The original suite only exercised `ethExpected`; the new finalized holder exercises `ethFinalized` **and proves it is preferred** (its `ethFinalized` is 9 wei below its `ethExpected`).
- This evidence pack: README + case JSON + query script + dev deploy helper, bringing Stader WQ up to the same 10-section structure as the other verified protocols.

## 4. Adapter formula recap

```
total = 0
for i in 0 .. 255:                                   # MAX_REQUESTS_PROBED cap
    try id = USER_WITHDRAWAL_MANAGER.requestIdsByUserAddress(account, i)
    catch Panic(0x32) | empty-revert:  break          # end of the user's request array
    (owner, _, ethExpected, ethFinalized, _) = userWithdrawRequests(id)
    if owner == 0:                     continue        # already claimed — skip
    total += ethFinalized > 0 ? ethFinalized : ethExpected
emit PositionBalance(WETH, total, isDebt=false, Supplied, positionId="")   if total > 0 and WETH registered
```

## 5. Cherry-picked accounts

| Holder | Address | Branch | Rationale |
|---|---|---|---|
| `PENDING` | `0x4D0B2dB7d38009884c3f2a15c1c212f4F4a356c9` | `ethExpected` | One PENDING (un-finalized) request 8218 (`ethFinalized == 0`) → exercises the request-time estimate branch. |
| `FINALIZED` | `0x404186e63CA9e1D0648a5AEc0b77cD398814C47D` | `ethFinalized` | One FINALIZED-unclaimed request 8214 where `ethFinalized` (…347) is **9 wei below** `ethExpected` (…356) → exercises the finalized branch **and** proves it wins over the estimate. |
| `MULTI` | `0xeB0CBBA408436997AfD29c50d6A9ffcCf9a2493f` | `ethFinalized` (×2) | Two open requests (8196 + 8197), both finalized → exercises the **enumeration loop summing multiple requests** into one aggregated leg on a real fork (previously only mock-tested). Not a distinct value branch — both legs are `ethFinalized`. Also the holder used to demo the per-request-id dashboard drill-down (§9). |

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
| Fork-test contract | `StaderWithdrawalQueueBalanceAdapterForkTest_Fresh` in `test/balances/protocols/fork/StaderWithdrawalQueue.fork.t.sol` |

## 6. Case files in this folder

| File | Purpose |
|---|---|
| `case-real-holders-mainnet.json` | Machine-readable evidence pack: both holders, request ids, ETH owed, identity, ground-truth method |
| `query-live-balances.s.sol` | Forge script that deploys the adapter against a dev NAV and prints both holders' WETH legs for ad-hoc cross-checks |
| `script/development/deploy/deploy-stader-withdrawal-queue.sh` | Dev-anvil deploy helper: `forge create` the adapter + `addBalanceAdapters([adapter])` on the local NAV |

## 7. Expected balances

Single leg per holder, denominated in WETH. Captured at the fork block in §5.

### 7a. Per-leg detail

| Holder | Requests (open, un-claimed) | Leg | Token | ETH owed (raw) | ETH (humanised) | branch |
|---|---|---|---|---|---|---|
| `0x4D0B2dB7…` | 8218 (`ethExpected`, not finalized) | Supplied | WETH | `179475428570970280827` | 179.475428570970280827 ETH | `ethExpected` |
| `0x404186e6…` | 8214 (`ethFinalized`, finalized) | Supplied | WETH | `10804926562492357347` | 10.804926562492357347 ETH | `ethFinalized` |
| `0xeB0CBBA4…` | 8196 (`109058136469367`) + 8197 (`218116272938735`), both finalized | Supplied | WETH | `327174409408102` | 0.000327174409408102 ETH | `ethFinalized` (×2, summed) |

### 7b. Per-asset summary

| Holder | Token | Total (raw) | Total (humanised) | isDebt |
|---|---|---|---|---|
| `0x4D0B2dB7…` | WETH | `179475428570970280827` | 179.475428570970280827 ETH | false |
| `0x404186e6…` | WETH | `10804926562492357347` | 10.804926562492357347 ETH | false |
| `0xeB0CBBA4…` | WETH | `327174409408102` | 0.000327174409408102 ETH (sum of 8196 + 8197) | false |

`getAdapterBalanceForAsset(holder, WETH)`, `getAdapterBalances(holder)`, and the single `getAdapterPositions` entry all return the same value per holder.

## 8. Ground-truth cross-check

The value is a live read of Stader's own UserWithdrawalManager — there is no closed-form re-derivation, so the strongest ground truth is the manager's own per-request settlement view:

| Holder | Check |
|---|---|
| `PENDING` (un-finalized) | `adapter == userWithdrawRequests(8218).ethExpected` and `ethFinalized == 0`. |
| `FINALIZED` (finalized) | `adapter == userWithdrawRequests(8214).ethFinalized`, which is **strictly less than** that request's `ethExpected` (…347 < …356) — proving the branch precedence. |
| `MULTI` (two requests) | `adapter == userWithdrawRequests(8196).ethFinalized + userWithdrawRequests(8197).ethFinalized` — one aggregated leg, summed on-chain. |

The claimed-skip (`owner == 0`) path is exercised with mocks in `test/balances/protocols/StaderWithdrawalQueue.t.sol` — a holder carrying a claimed-but-still-indexed id can't be relied on to exist at any given block. The tests also assert `protocolId == keccak256("stader-withdrawal")`, `positionId == ""`, `PositionKind.Supplied`, and `balanceAdapter == address(this)`.

## 9. Wiring the live dev-anvil dashboard

`script/development/deploy/deploy-stader-withdrawal-queue.sh` deploys + registers the adapter on the local mainnet anvil so the dashboard renders both holders' withdrawal-queue positions for a side-channel cross-check. WETH is registered on the NAV at bootstrap (`deploy.sh` registers the WETH/USD feed), so no extra asset registration is needed. To pin the dev anvil at the verification block (so the dashboard matches §7 exactly):

```bash
anvil --fork-url <MAINNET_URL> --fork-block-number 25330819 --chain-id 1 --port 8545 \
      --state script/development/state/1.json --state-interval 60 &
bash script/development/deploy/deploy.sh 1                       # NAV + Chainlink assets (incl. WETH)
bash script/development/deploy/deploy-stader-withdrawal-queue.sh 1
bash script/development/app/sync-app-env.sh 1
# then start the Next.js dev server in app/
```

The position renders under **Stader** as a single **Supplied** leg denominated in WETH. The featured holders are arbitrary on-chain stakers (not tracked NAV accounts) chosen to exercise the branches; their NAV *totals* also include unrelated wallet positions, so cross-check the **Stader leg** specifically, not the account total.

**Per-request-id drill-down (display only).** The adapter aggregates all open requests into the one WETH leg, but the dashboard renders sub-rows beneath it — one per Stader **request id** (Stader's identifier is a sequential `requestId`, not an ERC721 NFT like Lido), with its id, ETH amount, price, USD value, %, and a Claimable (finalized) / Pending badge. This is re-derived client-side directly from the UserWithdrawalManager (app hook `app/src/hooks/use-stader-withdrawals.ts`, rendered in `protocol-group.tsx`) and does **not** change NAV or the adapter's emitted identity — it's a reconciliation aid sharing the same generic withdrawal-row rendering as Lido. Each request is valued the **same way the adapter sums it** — `ethFinalized` for finalized requests, `ethExpected` for pending — so the rows are genuine ETH amounts and the USD values, split by ETH-owed share, sum exactly back to the aggregate leg. The hook mirrors the adapter's 256-request cap. For the **MULTI** holder `0xeB0CBBA4…` the leg shows `↳ #8196 (0.000109058136469367 ETH, Claimable)` + `↳ #8197 (0.000218116272938735 ETH, Claimable)`.

> ⚠ **Freshness:** `ethExpected` is fixed at request time, so the PENDING leg is stable. The FINALIZED / MULTI requests can be claimed by their owners at any time, which would zero those legs. Re-confirm the holders on-chain right before a live cross-check if material time has passed since `25_330_819`.

## 10. Test verdict

| Aspect | Status |
|---|---|
| Un-finalized requests valued via `ethExpected` | ✅ (PENDING, exact) |
| Finalized requests valued via `ethFinalized`, preferred over `ethExpected` | ✅ (FINALIZED, exact + 9-wei inequality) |
| Multi-request summing across the account | ✅ (MULTI holder, real on-chain fork + unit mocks) |
| Claimed requests skipped (`owner == 0`); above-cap accounts bounded (anti-DoS) | ✅ (unit test) |
| Both enumeration-end sentinels (Panic 0x32 / bare empty revert); other panics/reverts propagate | ✅ (unit test) |
| Identity: `protocolId == stader-withdrawal`, `positionId == ""`, `Supplied`, WETH-denominated | ✅ |
| Mainnet-only scope (manager not on other chains) | ✅ |

**Mainnet: Stader WQ fork suites pass (both branches, original + fresh pins).** Single mainnet deployment → no cross-chain surface. Stader ETHx withdrawal queue is verified.

Run via:

```
FOUNDRY_PROFILE=slow forge test --match-path "test/balances/protocols/fork/StaderWithdrawalQueue.fork.t.sol" -vv
```
