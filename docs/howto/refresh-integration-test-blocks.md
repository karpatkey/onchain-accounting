# How to refresh integration-test fork blocks (and cross-check NAV against Debank)

The integration tests in `test/integration/` deploy `NAVCalculator` from scratch on a forked chain at a pinned block, register every asset and balance adapter from chain config, and assert exact `getAccountNav` values for a set of accounts. Over time those fork blocks rot and the expected NAVs drift from reality. This walkthrough covers the bump-and-snapshot workflow that keeps them current and (optionally) cross-checks each NAV against DeBank's USD total.

The single source of truth is [`test/integration/accounts.json`](../../test/integration/accounts.json). The workflow reads and writes it; the integration tests assert against it. **Do not edit the per-chain `NAV.<Chain>.integration.fork.t.sol` files** when adding accounts or refreshing values — only edit `accounts.json`.

---

## When to run it

- After adding a new balance adapter, price feed, or asset that meaningfully changes NAV for an existing account.
- After adding a **new test account** (also a JSON edit; see "Adding a new test account" below).
- On a routine cadence so the fixture doesn't drift more than ~tolerance off reality. The repo includes a weekly cron in [`.github/workflows/refresh-integration-snapshot.yml`](../../.github/workflows/refresh-integration-snapshot.yml).
- Before bumping a release branch.

---

## What the workflow does

```
┌──────────────────────────────────────────────────────────────────────┐
│ 1. cast block-number per chain (PARALLEL) → forkBlock bumped         │
├──────────────────────────────────────────────────────────────────────┤
│ 1.5. Merkl proof capture per (chain × account) — Merkl API → fixture │
│    test/integration/merkl-proofs.json. Captures Distributor          │
│    merkleRoot at the new fork block for diagnostics. Failed proof    │
│    submissions in step 2 are tolerated (NAV treats them as 0).       │
├──────────────────────────────────────────────────────────────────────┤
│ 2. forge build once (warm cache) → forge test per chain (PARALLEL)   │
│    → deploys NAV stack (incl. MerklRewards) at the new fork, replays │
│    fixture proofs into the cache, reads NAV per enabled account,     │
│    emits SNAPSHOT|... lines that are applied via jq                  │
├──────────────────────────────────────────────────────────────────────┤
│ 3. (optional) /v1/user/all_complex_protocol_list (1×/account) +      │
│    /v1/user/token_list (1× per chain×account), filtered to NAV's     │
│    supported protocols + registered assets → debankUsd into JSON     │
├──────────────────────────────────────────────────────────────────────┤
│ 4. tolerance check + diff report                                     │
└──────────────────────────────────────────────────────────────────────┘
```

> **Why a separate Merkl-proof step.** Merkl's API only serves proofs against the *currently published* root. Forge tests pinned at a historical block can only verify a proof if that block's `Distributor.getMerkleRoot()` matches the API's current root — true right after a bump (when `forkBlock = cast block-number`), false a few hours later (Merkl rotates roots ~every 8h). Capturing proofs at bump time is the only window where this alignment holds reliably. After step 1.5, `merkl-proofs.json` is the source of truth that the integration test consumes deterministically — **the Merkl API is not queried during test runs, and you do not need to re-fetch proofs when re-running tests against the same pinned fork block.** The proofs remain valid for a given fork block forever, because `Distributor.getMerkleRoot()` is frozen at that block.
>
> **Root-mismatch detection.** The fixture stores `expectedRoot` — the root captured from the Distributor at the fork block. `_seedMerklProofs` compares this against the live root at test time; if they differ, it logs a prominent warning and all `submitProof` calls will fail (Merkl rewards silently zero). The fix is always the same: re-run `refresh-integration-snapshot.sh` to re-capture proofs against the current root.

Step 2 is the bottleneck (deploying a full NAV stack on a fork takes ~1–3 min per chain). Running all five chains in parallel reduces wall time from `sum(chains)` to `max(chains)` — typically Mainnet, since it has the most adapters. A single `forge build` runs before the parallel forge invocations so they share a warm cache without racing on `out/`. Each chain's stdout is captured to a per-chain log file in a temp directory; SNAPSHOT lines are applied to `accounts.json` in chain-id order after all forks finish, so output is deterministic and there's no jq-write race.

Tests stay deterministic: they assert against the snapshotted exact NAV in `accounts.json`. The Debank cross-check happens **at bump time only**, so test runs do not depend on Debank availability.

### Why step 3 filters Debank's response

Most test accounts hold positions outside what NAV currently supports — sitting in protocols (Pendle, Yearn, Lido staked positions, random LRTs) for which we haven't shipped a balance adapter, or in tokens that aren't registered as assets. An *unfiltered* Debank total — what `/v1/user/chain_balance` returns — would always exceed NAV by the value of those out-of-scope positions, making the tolerance check meaningless.

The script instead reconstructs a Debank-side total that's restricted to NAV's coverage. Two buckets are summed:

1. **Allowlisted protocols (full value).** `chains.<chainId>.supportedDeBankProtocols` in `accounts.json` is the per-chain allowlist of Debank protocol ids that NAV has a dedicated balance adapter for (e.g. `aave3`, `morphoblue`, `balancer3`). NAV's adapter handles the position math (debt netting, projected interest, reward accrual, etc.), so for these protocols we trust Debank's pre-aggregated `portfolio_item_list[].stats.net_usd_value` and sum it in full. Debank uses the bare id on Mainnet (`aave3`) and a chain prefix elsewhere (`arb_aave3`); the script accepts both.
2. **Wallet tokens.** `/v1/user/token_list?is_all=false` entries whose `id` (lowercased token address) is in `script/config/nav-config/assets-and-price-feeds/<chainId>.json` (top-level keyed by symbol) *or* in `script/test/wallet-aggregating-adapters.json` (currently `Cap → cUsd, stcUsd`). The `is_all=false` flag tells Debank to suppress tokens it has already exposed under a `portfolio_item_list` entry, so LSTs (rETH/sUSDS/wstETH/ETHx/etc.) are counted exactly once via the protocol bucket above. Without this flag (the prior default `is_all=true`), the same dollar appears in both buckets — observed inflating ACCOUNT_10's anchor by ~$58M. Native is included when relevant — every chain we test against registers the ERC-7528 native sentinel (`0xEeeE…eEeE`) and `ERC20DefaultBalanceAdapter._getBalanceForAsset` returns `account.balance` for that address. Debank reports native via the chain id (`eth`, `arb`, `op`, `base`, `xdai`), so the filter accepts a token whose `id` either matches an allowlisted 0x address or equals the chain id when the sentinel is registered.

> **The `wallet-aggregating-adapters.json` registry.** Some balance adapters (Cap, today) read `balanceOf(token)` for one or more wallet tokens that aren't standalone NAV-registered priceable assets, then aggregate them into a single `PositionBalance` denominated in another asset (Cap reads cUsd + stcUsd → returns USDC). Those wallet tokens still need to count as "covered" in Bucket 2; otherwise the snapshot anchor under-counts vs the live filtered total. The registry maps `adapter_key → [constructor_param_names]`; both `refresh-integration-snapshot.sh` (jq) and `generate-comparison-report.py` (python) read it and union the constructor-arg addresses into the wallet allowlist. Adding a new wallet-aggregating adapter is one line in the JSON; both scripts pick it up.

> **Why we don't walk protocol `asset_token_list` for non-allowlisted protocols.** A natural-looking third bucket — "for any non-allowlisted protocol entry, sum its `asset_token_list[]` filtered to NAV-registered tokens" — *over-counts*. Empirically, the per-protocol `asset_token_list` is synthetic: Kelp DAO reports underlying ETH equivalent (id `eth`, ~$700 worth) of an rsETH position whose actual ERC20 balance shows up correctly in `token_list` (id `0xa129…`); Ethena reports an aggregated USDe count larger than `balanceOf(USDe)`; Lido reports pending rewards that never enter `balanceOf`. Walking these would either double-count Bucket 2 or count value NAV's default adapter never sees. The wallet `token_list` is the only reliable wallet-side source — if a NAV-registered token is on-chain, it's there with the right amount.

**When you add a new balance adapter**, ask whether Debank covers the same protocol. If yes, add the Debank short id to `supportedDeBankProtocols` for the relevant chains. If no, add nothing and accept that NAV will exceed filtered-Debank by exactly the value of that adapter's positions for the test accounts (which is usually fine — the drift will be visible in the report). To find a Debank protocol id, browse [debank.com/protocols](https://debank.com/protocols) or grep one of your test accounts' `/v1/user/all_complex_protocol_list` response.

> **When NAV deliberately doesn't track a protocol Debank reports**, leave the Debank id OUT of `supportedDeBankProtocols` AND list it in the chain's `$untracked_by_design` field (see `accounts.json.chains.1.$untracked_by_design`). This documents to reviewers that the ❌ entry in the comparison report is intentional, not an oversight. Concrete cases on chain 1 today: `balancer2` (no Bal V2 adapter), `sablier`, `acrocc_v2` (Across V2 LP), `multichain` (defunct bridge), `compound` (Compound V2 — only V3 covered). Wallet tokens with no Chainlink mainnet feed (COW, HEX, POL, CASHW, etc.) belong in the same field.

**When you add a new asset** to `script/config/nav-config/assets-and-price-feeds/<chainId>.json` (registered via `RegisterAssets.s.sol`), no script change is needed — the filter automatically picks up newly registered assets.

---

## Prerequisites

- `forge`, `cast` (Foundry).
- `jq`, `curl` (most systems already have these).
- Per-chain RPC access. The script picks RPC URLs in this order:
  1. Chain-specific env: `MAINNET_URL`, `ARBITRUM_URL`, `BASE_URL`, `OP_URL`, `GNOSIS_URL`.
  2. Falls back to `https://<alchemyNetwork>.g.alchemy.com/v2/$ALCHEMY_API_KEY` (where `alchemyNetwork` is read from `accounts.json`).
- Optional: `DEBANK_API_KEY` (Debank Pro). If unset, the cross-check is skipped — fork blocks and NAV snapshots still refresh.

---

## Run it locally

```bash
# Default (Debank cross-check on if DEBANK_API_KEY is set, MAX_PARALLEL=5):
script/test/refresh-integration-snapshot.sh

# Force-skip Debank even if the key is in the environment:
DEBANK_API_KEY= script/test/refresh-integration-snapshot.sh

# Override concurrency (default 5; lower to 2 on a runner with less RAM):
MAX_PARALLEL=2 script/test/refresh-integration-snapshot.sh
```

`MAX_PARALLEL` caps the number of concurrent `forge test` invocations in step 2. Each forge fork peaks at ~900MB RSS, so 5 concurrent forks need ~4.5GB free RAM minimum and can trigger OOM-kills on 8GB hosts. The default of 5 runs all chains in parallel on 16GB+ runners; lower it to 2 on an 8GB box.

Output:

- `refresh-report.md` (project root) — markdown table per chain and per (chain × account).
- `test/integration/accounts.json` — updated in place. Inspect with `git diff` before committing.

Exit codes:

| Code | Meaning |
|---|---|
| `0` | All chains refreshed, no tolerance violations. |
| `1` | At least one chain failed in step 2 (RPC down, OOM, `forge` revert, hung). The script still proceeds to step 3 (Debank) and step 4 (report) so partial data is preserved; surviving chains' snapshots are written to `accounts.json`. |
| `2` | Every chain succeeded but at least one (chain × account) drifted past `tolerance`. Inspect the report. |

After a clean run, verify the integration tests still pass against the new snapshots:

```bash
FOUNDRY_PROFILE=slow forge test --match-path "test/integration/**"
```

---

## Run it via CI

[`.github/workflows/refresh-integration-snapshot.yml`](../../.github/workflows/refresh-integration-snapshot.yml) exposes:

- A weekly cron (Mondays 06:00 UTC). Includes Debank.
- A `workflow_dispatch` trigger with an `include_debank` toggle.

The workflow runs the script, then opens (or updates) a PR titled `chore(integration): refresh fork blocks and Debank snapshots` with the updated `accounts.json` and the report as the PR body. **The workflow does not auto-merge** (matches the rest of this repo: humans merge).

Required secrets / repo vars:

| Name | Where | Notes |
|---|---|---|
| `KNODE_URL` (var) | repo variables | Used by this workflow to build the per-chain `*_URL` env (`foundry.yml` itself now uses Alchemy). |
| `KNODE_API_KEY` | repo secrets | Existing. |
| `ALCHEMY_API_KEY` | repo secrets | Fallback when a chain-specific `*_URL` is unset. |
| `DEBANK_API_KEY` | repo secrets | New. Used only when the workflow is triggered with `include_debank: true` (default for cron runs). |

---

## Adding a new test account

Edit `test/integration/accounts.json`:

```json
{
  "address": "0x…",
  "label": "ACCOUNT_4",
  "enabledChains": [1, 42161],
  "expected": {
    "1":     { "navUsd8dp": "", "debankUsd": "" },
    "42161": { "navUsd8dp": "", "debankUsd": "" }
  }
}
```

Then run the bump script. It will populate `navUsd8dp` (and, if Debank is configured, `debankUsd`) for the chains in `enabledChains`. No Solidity changes required.

To **remove** an account: delete the object. To **disable on a chain**: drop the chainId from `enabledChains`. The integration tests will skip whatever isn't enabled.

> Accounts that hold positions outside NAV's coverage are now valid test cases — the filtered Debank comparison only counts protocols + assets NAV supports. Picking an account with a Pendle / Yearn / Lido position alongside its NAV-covered positions just means those balances are excluded from the reference total; they don't poison the tolerance check.

> **Don't pick an account whose only relevant position is *ephemeral* — a withdraw/exit queue, an in-flight bridge transfer, or anything that settles/claims within days.** This snapshot tracks the latest block, so by the next refresh the position is gone, `navUsd8dp` just recomputes lower, and **the test still passes** — meaning the adapter silently stops being exercised with no failure signal, and you'd have to re-pick a fresh holder every refresh. Correctness for these adapters lives in their **per-adapter fork test**, which is pinned to a fixed historical block and never bumps (e.g. `test/balances/protocols/fork/KelpWithdrawalQueue.fork.t.sol`, `LidoWithdrawalQueue.fork.t.sol`). Reserve the integration snapshot for durable, slowly-changing positions (lending, vaults, LPs, staked balances).

---

## Tolerance failures — how to triage

The script's exit-code 2 means at least one (chain × account) had `|navUsd − debankUsd| / debankUsd > tolerance` (default 1%). Common causes, in order of frequency:

1. **Block-time drift between fork and Debank "now."** Debank's protocol/token endpoints return a current snapshot, while our forge run forks at the bumped block (which is a few minutes old). Spot prices for volatile assets (LSTs, LRTs, sometimes stables in stress) can move enough to exceed 1% over that window. Re-run the script; if it stabilises, this was the cause.
2. **Stale Debank cache for the protocol.** Debank's protocol valuations are refreshed asynchronously; their docs note up-to-12-hour worst case. If the affected position is in a freshly-onboarded protocol or one Debank has poor coverage of, expect drift here.
3. **Oracle vs market-rate disagreement.** Our NAV uses Chainlink + protocol on-chain rates; Debank uses Coingecko-ish market prices. For peg-deviating assets (USDe, sUSDe under stress) these can diverge meaningfully.
4. **Morpho projected vs stored balances** (a structural disagreement, *not* a bug). Our `MorphoMarketsMetaBalanceAdapter` reports projected balances via Morpho's `expectedMarketBalances` library — it folds in IRM-implied accrual since `lastUpdate`. Debank reads the stored `market(id)` values. For any Morpho position in a market that hasn't been touched in a while *and* is at high utilization, our NAV will exceed Debank by the projected delta. This is intentional and documented in [`../decisions/0004-morpho-projected-vs-stored-balances.md`](../decisions/0004-morpho-projected-vs-stored-balances.md). Concrete case: a small USDC supply in `wstUSR/USDC` (24 days stale, 100% util) inflated by ~53% from stored to projected — accounted for nearly all of ACCOUNT_1's intrinsic ~3% Mainnet drift seen on the first cron run. If you see persistent drift on an account that holds Morpho positions, check whether the affected market's `lastUpdate` is far from `block.timestamp` and whether `totalBorrowAssets` is close to `totalSupplyAssets` — that's the signature.
5. **A new protocol on Debank's side that we haven't allowlisted.** If you added a balance adapter but forgot to add the Debank protocol id to `chains.<chainId>.supportedDeBankProtocols`, NAV picks up the position and Debank doesn't — drift in NAV's favour. Inverse: if Debank has split or renamed a protocol id (e.g. an Aave Safety Module entry that used to live under `aave3` now appearing as `aavesm` or similar), the allowlist may need an addition even with no adapter change. Inspect the unfiltered `/v1/user/all_complex_protocol_list` response for the affected account to see what id Debank is now using.
6. **A real adapter bug.** If 1–5 don't apply and the drift is large or persistent, the adapter is computing the wrong amount or sign. Open the per-protocol fork test for that adapter and compare.

To raise tolerance, edit the top-level `"tolerance"` field in `accounts.json` (and document why in the PR description).

---

## Debank tier introspection

When the script starts, it calls `/v1/account/units` and logs the units balance. If the call fails or returns no balance, the run continues with Debank skipped — no abort. The intent is graceful degradation: a missing or out-of-units key is a *warning*, not a failure.

The script re-probes `/v1/account/units` at the end of the run so the report shows units consumed (not the starting balance). All Debank `curl` calls are bounded with `--max-time 30 --retry 2 --retry-delay 5 --retry-connrefused` so a slow Debank can never hang the workflow indefinitely.

If your tier is too low to cover a full run, use `DEBANK_API_KEY=` to skip Debank entirely and rely on the snapshotted NAVs alone. Snapshots are still valid for deterministic test asserts; they just lose their independent reference. Per-account unit cost: 1 × `/v1/user/all_complex_protocol_list` (covers every chain in one call, units vary with portfolio size — typically 5–15) plus 1 × `/v1/user/token_list` per enabled chain (~1 unit each), plus 2 for the start/end probes.

Reference: [Debank Cloud — User endpoints](https://docs.cloud.debank.com/en/readme/api-pro-reference/user). Pricing/units docs: [Units Usage](https://docs.cloud.debank.com/en/readme/auxiliary-feature/units).

---

## Known issues

### ~~`forge script` hangs on Mainnet~~ (resolved)

`forge script script/test/RefreshIntegrationSnapshot.s.sol` against Mainnet (chain 1) used to park at 0.9% CPU on a single open TCP socket and never produce SNAPSHOT lines. The exact same deploy pipeline ran cleanly via `forge test --match-contract MainnetIntegrationFromConfig` in ~1 second, confirming a `forge script`-specific bug.

**Fixed:** `refresh-integration-snapshot.sh` now uses `forge test --match-test test_emitSnapshots` for all chains. The `test_emitSnapshots()` function in `IntegrationFromConfigBase` emits SNAPSHOT lines in the same format that `harvest_chain` already parses, so the shell-script plumbing is unchanged. `RefreshIntegrationSnapshot.s.sol` is retained for reference but is no longer invoked by the refresh script.

### Drift profile observed in practice

When running with **fresh fork blocks** (i.e., the script just bumped them), drift against Debank typically lands like this:

| Chain shape | Expected drift |
|---|---|
| Pure stable holdings on L2/Gnosis (USDC, USDT, etc.) | < 0.1% |
| Mainnet portfolio of mixed volatile assets (ETH, BTC, LSTs, LRTs) | 0.1% – 0.3% |
| Specific wrapped/synthetic assets where Chainlink ≠ Debank pricing | 1% – 3% |

A persistent ~3% drift on a single Mainnet account with fresh blocks usually means the adapter holds an asset where our adapter stack and Debank's portfolio pricing disagree (most often ETH+, sUSDe under stress, or freshly-onboarded LRTs). Use `nav.getAccountPositions(account, address(0))` against the relevant fork to find the divergent line item before chasing it as a bug.

---

## How the deterministic asserts work

`test/integration/IntegrationFromConfigBase.fork.sol` reads `accounts.json` in `setUp` and `_assertNavsForCurrentChain`:

- `_chainId` is set by the per-chain test contract.
- `_forkBlock` is read from `accounts.json[".chains.<chainId>.forkBlock"]` (unless the child sets a literal — used only for one-off debugging).
- For each account whose `enabledChains` includes `_chainId`, the test reads the expected `navUsd8dp` from `accounts.json[".accounts[i].expected.<chainId>.navUsd8dp"]` and `assertEq`'s the live NAV against it. Failures cite the account label.

Per-chain test contracts are stubs:

```solidity
contract MainnetIntegrationFromConfig is IntegrationFromConfigBase {
    function setUp() public {
        _chainId = 1;
        _forkNetwork = "eth-mainnet";
        _setupAndDeploy();
    }
    function test_accountNavs() public view { _assertNavsForCurrentChain(); }
}
```

The bump script regenerates the JSON; the tests just consume it.

---

## Per-adapter detail and coverage-gap report (Sections 3 and 4)

`comparison-report.md` has six sections; beyond the account-level drift summary (Section 1) and protocol-level pairing (Section 2), the two most useful for triage are the per-adapter detail (Section 3) and coverage-gap detection (Section 4). (Sections 5 and 6 cover the untracked-by-design footer and stale-price/sequencer flags.)

### Section 3 — Per-adapter granular detail

Every NAV position that was successfully matched to a Debank item appears in a per-adapter table. The grouping key is `(chain, positionId, protocol)` — one sub-section per adapter deployment instance (e.g. "Compound V3 USDC — Mainnet"), then one row per leg (supply side, borrow side, each reward token, fee legs for LP positions, etc.).

| Column | Meaning |
|---|---|
| Leg | Leg kind: Wallet / Supplied / Borrowed / Collateral / Staking / Rewards / Fees — from `positionKind` (the `PositionKind` enum value) |
| Side | `+` credit, `−` debt |
| NAV amount | Token amount as reported by the balance adapter (8+ decimal precision) |
| DB amount | Token amount reported by Debank for the same leg |
| Δ amt % | `(nav − debank) / debank` — **balance-adapter signal**. Non-trivial here → adapter math error |
| NAV unit $ | Per-unit USD price used by NAVCalculator (Chainlink / custom feed) |
| DB unit $ | Per-unit USD price used by Debank |
| Δ price % | `(nav_price − debank_price) / debank_price` — **price-feed signal**. Non-trivial here → feed misconfigured or Debank uses a different source |
| NAV USD | `NAV amount × NAV unit $` — what NAV counted for this leg |
| DB USD | Debank's USD valuation for this leg |
| Δ USD % | Combined drift — should approximately equal `Δ amt % + Δ price %` |

Severity hint prefix on drift cells: `OK` (≤1%), `WARN` (1–5%), `FAIL` (>5%).

**Interpreting the drift decomposition:**

- `Δ amt %` large, `Δ price %` small → balance adapter is computing a wrong amount (e.g. missing an accrual step, wrong share-to-asset conversion, off-by-one in decimals).
- `Δ price %` large, `Δ amt %` small → price feed disagrees with Debank's market rate (e.g. a Chainlink feed with a price floor/cap, a stale custom feed, or Debank using a different peg source).
- Both small but `Δ USD %` non-trivial → rounding or precision loss in the NAV computation (rare).
- Both large → investigate adapter first (wrong amount usually explains the rest).

Legs with no Debank counterpart (adapter-only positions Debank doesn't expose) appear with `—` in the DB columns. Debank items with no NAV match appear in Section 4.2 instead.

### Section 4 — Coverage gap detection

Two sub-sections:

**4.1 — Debank protocols held but not in `supportedDeBankProtocols`**

Lists Debank protocol ids that carry non-zero `net_usd_value` for any account on a given chain but are absent from the chain's allowlist. Each row shows `Chain | Account | Protocol | DeBank ID | Value | NAV adapter?` — the `NAV adapter?` column reports whether a NAV protocol maps to that Debank id (via the script's `_DEBANK_ID_TO_NAV_PROTOCOLS` table). If an adapter exists and isn't wired, this row is the signal to add a config entry (see "Actioning a 4.1 row" below). If no adapter exists, the row is informational — open a backlog item in `docs/roadmap/balance-adapter-coverage.md`.

**4.2 — Debank items in supported protocols with no NAV match**

A protocol is allowlisted but one of its items produced no `LegMatch`. Diagnostic hints per row:
- *Unregistered token*: the token address isn't an asset in `script/config/nav-config/assets-and-price-feeds/<chainId>.json`.
- *Missing price feed*: the asset is registered but has no `priceFeeds[]` entry in `script/config/nav-config/assets-and-price-feeds/<chainId>.json` (custom-feed deploy config lives in `script/config/contracts-deployment-config/custom-price-feeds/<chainId>.json`).
- *Adapter not wired*: `balanceAdapters` in the chain config doesn't include an entry for this market/vault.

**To action a 4.1 row:**

1. Confirm the canonical contract address on the target chain (protocol's docs, Etherscan, or a Debank item's `asset_token_list[].id`).
2. Add the adapter to `script/config/contracts-deployment-config/balance-adapters/<chainId>.json` (plain) or `script/config/contracts-deployment-config/meta-balance-adapters/<chainId>.json` (meta) for the deploy config, and `script/config/nav-config/balance-adapters/<chainId>.json` or `script/config/nav-config/meta-balance-adapters/<chainId>.json` (NAV registration), following the same shape as the existing mainnet entry for that adapter.
3. If any token the adapter introduces needs a price feed, check `src/prices/protocols/` for an existing feed contract (L2 LST feeds — `wstETH_L2_Price`, `weETH_L2_Price`, etc. — are already shipped). If none exists, flag as a follow-up (no new Solidity in this workflow).
4. Re-run `refresh-integration-snapshot.sh`. Confirm the gap row clears in Section 4.1.

### Debank response cache

The refresh script persists Debank API responses to `test/integration/debank-cache/` immediately after each fetch:

- `<addr_lower>-protocols.json` — `/v1/user/all_complex_protocol_list` response (all chains in one call)
- `<addr_lower>-tokens-<chainId>.json` — `/v1/user/token_list?chain_id=<chain>&is_all=false` response

These files are committed alongside `accounts.json` and the `nav-positions-*.json` snapshots. They serve two purposes:

1. **Report reruns without an API key.** `generate-comparison-report.py` reads the cache automatically when `DEBANK_API_KEY` is unset and the cache directory is present. Pass `--from-cache` to force cache-only mode even when an API key is set.
2. **Stable diff surface.** The cache makes Debank data a proper snapshot fixture — `git diff` on the cache files shows exactly what changed between refreshes.

To regenerate only the report from cached data (no RPC, no Debank call, no forge run):

```bash
python3 script/test/generate-comparison-report.py --from-cache
```

To force a fresh Debank fetch even when the cache is populated:

```bash
DEBANK_API_KEY=<key> python3 script/test/generate-comparison-report.py --refresh-debank
```

### Adding a placeholder account

The `accounts.json` file includes two pre-wired placeholder slots (`ACCOUNT_PLACEHOLDER_POLYGON` and `ACCOUNT_PLACEHOLDER_FUTURE`). To activate one:

1. Set `"address"` to a real on-chain address that holds positions you want to cover.
2. Set `"enabledChains"` to the chain ids you want NAV to evaluate (and that the chain config exists for in `script/config/chains/`).
3. Run `refresh-integration-snapshot.sh`. The script skips any account whose `address` is empty or starts with `<`; once you fill it in, it participates in the full fork + Debank flow.
4. After the run, accept the populated `expected` values with `git add test/integration/accounts.json`.
5. Open `comparison-report.md` Section 4 to see what adapters and feeds are needed for the new account's positions.

---

## Files

- `test/integration/accounts.json` — source of truth.
- `test/integration/IntegrationFromConfigBase.fork.sol` — reads JSON; deploys NAV; asserts.
- `test/integration/NAV.<Chain>.integration.fork.t.sol` — chain stubs.
- `test/integration/debank-cache/` — persisted Debank API responses (one file per account/chain, committed).
- `script/test/RefreshIntegrationSnapshot.s.sol` — legacy forge script that emits `SNAPSHOT|…` lines; retained for reference but no longer invoked by the refresh script (which now uses `forge test --match-test test_emitSnapshots` — see "Known issues" above).
- `script/test/refresh-integration-snapshot.sh` — orchestrator (cast + forge + curl + jq).
- `script/test/generate-comparison-report.py` — renders `comparison-report.md` (NAV ↔ Debank cross-check, per-adapter detail, coverage gaps). Pass `--from-cache` to regenerate from cached Debank responses without an API key.
- `script/test/wallet-aggregating-adapters.json` — single-source-of-truth registry of balance adapters that consume wallet tokens via `balanceOf` (e.g. Cap reads cUsd + stcUsd). Both the snapshot script and the comparison report read it; one entry per adapter is enough to keep their allowlists in sync.
- `.github/workflows/refresh-integration-snapshot.yml` — CI workflow (manual + weekly).
- `docs/decisions/0003-integration-test-snapshot-workflow.md` — design rationale.
