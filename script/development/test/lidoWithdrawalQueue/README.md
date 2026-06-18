# Lido stETH Withdrawal Queue — balance-adapter verification

## 1. Adapter under test

`src/balances/protocols/LidoWithdrawalQueue.sol` — the immutable `LidoWithdrawalQueueBalanceAdapter`. Constructor: `(withdrawalQueue, underlyingToken, navCalculator)` where `withdrawalQueue = Lido WithdrawalQueueERC721` (`0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1`) and `underlyingToken =` the **native-ETH sentinel** (`0xEeee…eEEeE`). Identity is derived on-chain: `positionId = ""` (account-global — a holder has at most one aggregate queue position), `protocolId = keccak256("lido-withdrawal")`, `positionKind = Supplied`.

### Inheritance + per-chain scope (Phase 0)

- **Inheritance:** none — `LidoWithdrawalQueueBalanceAdapter` implements `IBalanceAdapter` + `IPositionDescribable` directly. No base contract, no overrides.
- **Per-chain scope:** Lido's `WithdrawalQueueERC721` is **mainnet-only**. So `chains/1.json` is the only chain config with `LidoWithdrawalQueue`. A single mainnet fork test is sufficient; no per-chain branches.
- **Denomination — native ETH, not stETH:** when a user requests an unstake, stETH is locked and an ERC721 request id is minted; the claim pays out **native ETH** (the stETH is burned). The adapter denominates the position in ETH and NAV prices it via **ETH/USD**, so a stETH depeg can't mis-value a claim that settles in full ETH. While queued, the value is invisible to wallet/receipt-token oracles — this adapter is the only thing that surfaces it.
- **Gas bound (anti-DoS):** Lido's queue is **not** `ERC721Enumerable` (no `tokenOfOwnerByIndex`), and `getWithdrawalRequests` returns the *entire* id set. The adapter reads `balanceOf` (O(1)) first and **skips** (returns 0) any account with more than `MAX_REQUESTS_PROBED = 256` open requests, so an attacker can't inflate the id list (by transferring withdrawal NFTs in) to OOG the NAV read — an OOG is **not** caught by NAVCalculator's try/catch. A real account never approaches the cap.

### Math branches (`_ethOwed`)

Two branches, summed across the account's open (un-claimed) requests:

- **finalized** request → `getClaimableEther` (exact). Finalization can lock in *less* than `amountOfStETH` after a negative rebase, so `amountOfStETH` would overstate NAV. Resolved per-request (single-element arrays) because `findCheckpointHints` reverts (`RequestIdsNotSorted`) on an unsorted batch, and `getWithdrawalRequests` returns the owner's `EnumerableSet` order (not guaranteed sorted — a claim does swap-and-pop).
- **not yet finalized** → `amountOfStETH` (the redemption rate isn't fixed until finalization; never invent one). Equals the ETH paid in the normal case.
- `isClaimed` requests are skipped.

Registration gating is asymmetric (same as sGHO / Aave Umbrella): `getAdapterPositions` drops the leg if native ETH isn't registered on NAVCalculator (registered-asset intersection — the "discard if no price" policy), whereas the balance methods (`getAdapterBalanceForAsset` / `getAdapterBalances`) do **not** consult the registry and still return the value.

## 2. Existing fork test coverage

`test/balances/protocols/fork/LidoWithdrawalQueue.fork.t.sol` already had `LidoWithdrawalQueueBalanceAdapterForkTest` covering **both branches** against the real contract:
- un-finalized holder `0x7170b89D…` (id 125680, `amountOfStETH = 2.67 ETH`) @ block `25_203_500`.
- finalized-unclaimed holder `0xF74B44b0…` (`getClaimableEther = 4.871995… ETH`) @ block `25_200_000`.
- plus empty / unknown-holder / unsupported-asset / asset-filter-mismatch / interface / immutables.

The unit test (`test/balances/protocols/LidoWithdrawalQueue.t.sol`) covers the mock-only edges: constructor reverts, multi-request summing, the **negative-rebase divergence** (finalized claimable < amountOfStETH), unsorted finalized batch, skips-claimed, the cap boundary (exactly-at-cap sums / above-cap → 0), and unregistered underlying.

All kept as regression nets.

## 3. What this case adds

- A **fresh dual-holder pin at the verification block `25_294_574`** (`LidoWithdrawalQueueBalanceAdapterForkTest_Fresh`) — augments, doesn't replace. One holder per branch, at minutes-fresh state, so the dev-anvil dashboard (§9) shows live-relevant positions for a side-channel cross-check.
- This evidence pack: README + case JSON + query script + dev deploy helper, bringing Lido WQ up to the same 10-section structure as the other verified protocols.

## 4. Adapter formula recap

```
count = WITHDRAWAL_QUEUE.balanceOf(account)          # O(1); skip (return 0) if count == 0 or count > 256
ids   = WITHDRAWAL_QUEUE.getWithdrawalRequests(account)
for each request:
    if isClaimed:                 skip
    elif isFinalized:             total += getClaimableEther([id], findCheckpointHints([id],1,lastCheckpoint))
    else (not finalized):         total += amountOfStETH
emit PositionBalance(ETH, total, isDebt=false, Supplied, positionId="")   if total > 0
```

## 5. Cherry-picked accounts

| Holder | Address | Branch | Rationale |
|---|---|---|---|
| `PRIMARY` | `0x9074212F22F75789cA3fa21A4B46d3A1489CC0a9` | `amountOfStETH` | Two PENDING (un-finalized) requests → exercises the not-finalized branch **and** multi-request summing across one account. |
| `SECONDARY` | `0x2DE923BEE124514939ACa4f8f057e11Ff8d44F2b` | `getClaimableEther` | One FINALIZED-unclaimed request → exercises the finalized branch (checkpoint-hint resolution + claimable read). |

### Setup

| Field | Value |
|---|---|
| Chain | Ethereum mainnet (chainId 1) |
| Block | **25,294,574** |
| Block timestamp | 1781185211 (`0x6a2ababb`) — **2026-06-11 13:40:11 UTC** |
| WithdrawalQueue | `0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1` |
| Underlying (native ETH) | `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` |
| Queue state at block | lastRequestId 127194, lastFinalizedRequestId 127171, lastCheckpointIndex 1123 |
| Adapter under test | `LidoWithdrawalQueueBalanceAdapter` |
| Fork-test contract | `LidoWithdrawalQueueBalanceAdapterForkTest_Fresh` in `test/balances/protocols/fork/LidoWithdrawalQueue.fork.t.sol` |

## 6. Case files in this folder

| File | Purpose |
|---|---|
| `case-real-holders-mainnet.json` | Machine-readable evidence pack: both holders, request ids, ETH owed, identity, ground-truth method |
| `query-live-balances.s.sol` | Forge script that deploys the adapter against a dev NAV and prints both holders' ETH legs for ad-hoc cross-checks |
| `script/development/deploy/deploy-lido-withdrawal-queue.sh` | Dev-anvil deploy helper: `forge create` the adapter + `addBalanceAdapters([adapter])` on the local NAV |

## 7. Expected balances

Single leg per holder, denominated in native ETH. Captured at the fork block in §5.

### 7a. Per-leg detail

| Holder | Requests (open, un-claimed) | Leg | Token | ETH owed (raw) | ETH (humanised) | branch |
|---|---|---|---|---|---|---|
| `0x9074212F…` | 127178 (1000 stETH) + 127179 (995.928786744414475126 stETH) | Supplied | ETH | `1995928786744414475126` | 1995.928786744414475126 ETH | `amountOfStETH` |
| `0x2DE923BE…` | 127164 (finalized) | Supplied | ETH | `54619912948304940018` | 54.619912948304940018 ETH | `getClaimableEther` |

### 7b. Per-asset summary

| Holder | Token | Total (raw) | Total (humanised) | isDebt |
|---|---|---|---|---|
| `0x9074212F…` | ETH | `1995928786744414475126` | 1995.928786744414475126 ETH | false |
| `0x2DE923BE…` | ETH | `54619912948304940018` | 54.619912948304940018 ETH | false |

`getAdapterBalanceForAsset(holder, ETH)`, `getAdapterBalances(holder)`, and the single `getAdapterPositions` entry all return the same ETH value per holder.

## 8. Ground-truth cross-check

The value is a live read of Lido's own WithdrawalQueue — there is no closed-form re-derivation, so the strongest ground truth is the queue's own settlement view:

| Holder | Check |
|---|---|
| `PRIMARY` (un-finalized) | `adapter == Σ amountOfStETH` over the account's open un-claimed un-finalized requests (`getWithdrawalStatus`). |
| `SECONDARY` (finalized) | `adapter == getClaimableEther([127164], findCheckpointHints([127164],1,1123))` — the exact ETH Lido would pay on claim. Here it equals `amountOfStETH` (no negative rebase), which is the normal case. |

The **divergent** case (finalized `getClaimableEther < amountOfStETH` after a negative rebase) is exercised with mocks in `test/balances/protocols/LidoWithdrawalQueue.t.sol::test_getAdapterBalanceForAsset_finalizedUsesClaimableEth` — a real holder with a haircut can't be relied on to exist at any given block. The tests also assert `protocolId == keccak256("lido-withdrawal")`, `positionId == ""`, `PositionKind.Supplied`, and `balanceAdapter == address(this)`.

## 9. Wiring the live dev-anvil dashboard

`script/development/deploy/deploy-lido-withdrawal-queue.sh` deploys + registers the adapter on the local mainnet anvil so the dashboard renders both holders' withdrawal-queue positions for a side-channel cross-check. Native ETH is registered on the NAV at bootstrap (`01_DeployNAV` registers the native ETH/USD feed), so no extra asset registration is needed. To pin the dev anvil at the verification block (so the dashboard matches §7 exactly):

```bash
anvil --fork-url <MAINNET_URL> --fork-block-number 25294574 --chain-id 1 --port 8545 \
      --state script/development/state/1.json --state-interval 60 &
bash script/development/deploy/deploy.sh 1                       # NAV + Chainlink assets (incl. ETH)
bash script/development/deploy/deploy-lido-withdrawal-queue.sh 1
bash script/development/app/sync-app-env.sh 1
# then start the Next.js dev server in app/
```

The position renders under **Lido** as a single **Supplied** leg denominated in ETH. Both holders are arbitrary on-chain stakers (not tracked NAV accounts) chosen to exercise the two branches; their NAV *totals* also include unrelated wallet positions (e.g. wallet stETH/USDC), so cross-check the **Lido leg** specifically, not the account total.

**Per-NFT-id drill-down (display only).** The adapter aggregates all open requests into the one ETH leg, but the dashboard renders **always-shown sub-rows** beneath it — one per withdrawal-request NFT, with its id, ETH amount, price, USD value, %, and a Pending/Claimable badge. This is re-derived client-side directly from the WithdrawalQueue (app hook `app/src/hooks/use-lido-withdrawals.ts`, rendered in `protocol-group.tsx`) and does **not** change NAV or the adapter's emitted identity — it's a reconciliation aid. Each request's ETH amount is valued the **same way the adapter sums it** — `getClaimableEther` for finalized requests, `amountOfStETH` for pending — so the rows are genuine ETH amounts (correct even on a negative-rebase haircut) and the USD values, split by ETH-owed share, sum exactly back to the aggregate leg. The hook mirrors the adapter's 256-request cap. For `0x9074212F…` the leg shows `↳ #127178 (1000 ETH, Pending)` + `↳ #127179 (995.928786744414475126 ETH, Pending)`.

> ⚠ **Freshness:** `amountOfStETH` is fixed at request time, so the PRIMARY (pending) leg is stable. The SECONDARY (finalized) request can be claimed by its owner at any time, which would zero its leg. Re-confirm both holders on-chain right before a live cross-check if material time has passed since `25_294_574`.

## 10. Test verdict

| Aspect | Status |
|---|---|
| Un-finalized requests valued via `amountOfStETH` + summed across the account | ✅ (PRIMARY, exact) |
| Finalized requests valued via `getClaimableEther` (per-request checkpoint hint) | ✅ (SECONDARY, exact) |
| Negative-rebase divergence (`getClaimableEther < amountOfStETH`) | ✅ (unit test, mocks) |
| Claimed requests skipped; above-cap accounts skipped (anti-DoS) | ✅ (unit test) |
| Identity: `protocolId == lido-withdrawal`, `positionId == ""`, `Supplied`, ETH-denominated | ✅ |
| Mainnet-only scope (queue not on other chains) | ✅ |

**Mainnet: Lido WQ fork suites pass (both branches, original + fresh pins).** Single mainnet deployment → no cross-chain surface. Lido stETH withdrawal queue is verified.

Run via:

```
FOUNDRY_PROFILE=slow forge test --match-path "test/balances/protocols/fork/LidoWithdrawalQueue.fork.t.sol" -vv
```
