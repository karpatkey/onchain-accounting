# `script/development/test/` — balance-adapter verification evidence

One folder per protocol. Each folder holds the **evidence pack** behind the strict-equality fork test we add under `test/balances/<family>/fork/<Adapter>.fork.t.sol` for that protocol (where `<family>` is `BalanceAdapters`, `MetaBalanceAdapters`, or `AssistedBalanceAdapters`).

## Methodology (per protocol)

Mirrors the original V1-migration verification standard used for Balancer V3 / Curve / Convex. The full methodology is captured in this file plus per-protocol READMEs under `<protocol>/`; the same notes are also kept in the maintainer's persistent memory under the slug `balance-adapter-verification-methodology` (not a file in the repo).

### Phase 0 — pre-test audit (do BEFORE the five steps below)

The verification quality depends on this. Skipping it lets bugs hide where the adapter has chain-specific or inheritance-specific surface area we didn't realise existed. Output of Phase 0 is a short note at the top of `script/development/test/<protocol>/README.md` documenting the inheritance shape, the math branches, the chains in scope, and the resulting test-case count.

**A. Read the adapter source thoroughly.**
- Class hierarchy: is it a direct `IBalanceAdapter` implementer or a subclass? If subclass, list every `override` — each override is a verification surface the parent's test does NOT cover. List every purely-inherited method — those are transitively covered.
  - `PancakeSwapV2PoolsMetaBalanceAdapter is UniswapV2PoolsMetaBalanceAdapter` → thin subclass: constructor + `_protocolBrand()` / `_protocolId()` / `_protocolSubId()` overrides returning the `pancakeswap` brand + `pancakeswap-v2` slug, **plus** a `_mintFeeConstants()` override returning `(8, 17, 8)` where Uniswap V2 returns `(1, 5, 1)` — PancakeSwap's protocol-fee fraction differs, so the `_mintFee` dilution math is NOT identical. Verification: the pro-rata balance logic is inherited from Uni V2, so test the slug overrides plus the dilution branch (only reachable with `feeTo` set).
  - `PancakeSwapV3PoolsMetaBalanceAdapter is UniswapV3PoolsMetaBalanceAdapter` → the adapter reads the pool's live `slot0()` (the in-range split is priced off `sqrtPriceX96`/`tick`; full unclaimed fees; ADR 0017), so the subclass overrides `_slot0()` to decode PancakeSwap V3's `uint32 feeProtocol` ABI (Uniswap's is `uint8`) **and** the identity hooks (`_protocolBrand()` / `_protocolId()` / `_protocolSubId()` — the `pancakeswap` brand and `pancakeswap-v3` slug). Verification: test the `_slot0()` override (feeProtocol decode) plus the slug overrides.
  - `SparkLendBalanceAdapter is BalanceAdapterBase` (the shared `IBalanceAdapter, IPositionDescribable` base) → a standalone implementer, not an Aave subclass; check the source for the leg-emission branches and treat accordingly.
- Math branches: enumerate every `if` that affects the returned amount. Each branch needs a test case OR a documented reason it can't be exercised on a real chain. Uni V2 example: `feeTo == 0`, `feeTo != 0 && kLast == 0`, `feeTo != 0 && kLast != 0 && rootK > rootKLast`.
- Immutable constructor args: pin in setUp + assert in a `test_immutables_*` smoke test (catches deployment-config drift).
- Multi-leg `getAdapterPositions`: enumerate the `positionKind` values the adapter can emit (`Wallet`, `Supplied`, `Borrowed`, `Collateral`, `Staking`, `Rewards`, `Fees` — the `PositionKind` enum in `src/utils/PositionKind.sol`). One leg = one assertion.

**B. Read the protocol's docs per chain (our 5 chains).**

Scope: Ethereum (1), Gnosis (100), Base (8453), Optimism (10), Arbitrum (42161). For each chain, before writing the test:
- Does the protocol exist on this chain? If no → no test instance needed.
- Does the bytecode / ABI match mainnet? Most do; some don't (PCS V3's `uint32 feeProtocol` is the canonical counter-example). Aave V3 + Compound V3 each have per-chain markets/Comets that are distinct instances even when the ABI is identical.
- Are there L2-specific dependencies (sequencer uptime feeds on Optimism/Arbitrum/Base; Gnosis has none)? Balance adapters rarely care directly, but flag any time-derived logic in the source.
- Does the protocol publish canonical per-chain addresses? Use it verbatim — don't infer from one mainnet example.

**C. Read sibling adapter tests + ADRs + the identity schema.**
- Open `test/balances/<family>/fork/<Adapter>.fork.t.sol` (and adjacent ones for related adapters). Existing fork-test patterns reveal cadence, fork-block conventions, and mock-vs-real-holder choices.
- Search `docs/decisions/` for ADRs naming this adapter — they often document design constraints (immutability, trust-minimisation, math licensing, etc.).
- Confirm the canonical typed identity each leg must carry: `protocolBrand` / `protocolId` / `protocolSubId` (the 3-level `keccak256` slug taxonomy in `src/utils/ProtocolIds.sol`), `positionId` (ABI-encoded per `protocolSubId`), `positionKind`, `isLocked`, and the optional ephemeral `positionInstanceId`. The full schema reference is `docs/howto/position-identity-schema.md`. Display labels come from `IPositionDescribable.positionLabels(bytes positionId) → string[]` — use the shipped labels verbatim, don't invent ad-hoc ones (we already shipped a `pool` instead of `product/name` drift on Uni V2 chain config and Copilot caught it).

**D. Decide verification scope.** Cases = (math branches) × (chains with divergence). Be parsimonious. Document the count + reasoning at the top of the protocol's evidence-pack README.

### The five parallel steps

Once Phase 0 has produced a scope decision, these five steps **must happen in parallel** so the verification turns around in one session rather than serialising on each piece. Sequential ordering wastes time — and worse, lets the user idle while the test is being written, or lets the test get written for a block the user can't visually cross-check.

| # | Step | Who | Output |
|---|---|---|---|
| 1 | **Find the account.** Cherry-pick one holder with the most complex realistic scenario for this protocol (supplied + staked + rewards, multi-leg debt, multi-pool LP, …). Goal: fewest accounts that exercise all paths. | Claude (with user sign-off on the candidate) | `holder.address` + scenario rationale |
| 2 | **Write the test folder.** Create `script/development/test/<protocol>/` with `README.md` (case narrative + verification table) + `case-<slug>.json` (machine-readable evidence pack). | Claude | Evidence pack scaffold, populated incrementally |
| 3 | **Deploy the base NAV + the balance adapter under test on the dev anvil, forked at the SELECTED block, and read the holder's positions** (`getAdapterPositions` / the NAV's verbose reads via `cast call`). The dev anvil must pin at exactly the same block the fork test pins at, otherwise the side-channel cross-check vs Debank measures the wrong drift envelope. | Claude (refork helper + per-protocol adapter deploy on the fork) | The holder's positions read from the local fork at the pinned block |
| 4 | **Add the strict-equality test** to `test/balances/<family>/fork/<Adapter>.fork.t.sol`. **Augment**, don't replace — existing fork tests stay. New test contract pinned at the same selected block. | Claude | New test contract with strict-equality assertions per leg |
| 5 | **Check everything is working as intended; fix drift.** User cross-checks the positions read in step 3 vs **both Debank and the protocol's own UI** (e.g. the PancakeSwap / Uniswap / Aave app for the same holder) — the protocol UI is the highest-fidelity reference and often surfaces positions Debank aggregates or omits. Claude verifies the test passes with zero drift vs the off-chain ground truth. If any surface diverges, root-cause it (block drift, derivation difference, a position the adapter doesn't cover, or a real adapter bug). | Both, in parallel | Test ✅ + local-vs-(Debank/protocol-UI) gap explained |

Drift envelope on the side channel = (now − pinned block timestamp). If you pinned at a fresh block (a few minutes back), the local-vs-(Debank/protocol-UI) gap is bounded by minutes of natural pool activity, which is normally sub-bp at the dollar scale. Larger gaps need an explanation before the protocol can be marked verified.

Use **two reference surfaces, not one**: Debank for a quick aggregate sanity check, and the **protocol's own UI** for the authoritative per-position numbers. They serve different purposes — Debank can silently omit or merge positions, while the protocol UI shows exactly what the protocol itself reports (e.g. PancakeSwap's UI distinguishes a *farmed* NFT from an in-wallet LP NFT — a distinction that directly exposed the MasterChefV3 coverage gap for `PancakeSwapV3PoolsMetaBalanceAdapter`). When the two references disagree, the protocol UI wins; if the adapter matches neither, that's a finding.

### Hard constraints

- **The dev anvil fork block MUST equal the fork test's `FORK_BLOCK`.** If the refork hits the latest block, that block becomes the test's `FORK_BLOCK` — not the other way around. Don't pin the test at one block and the anvil at another.
- **Augment, don't replace.** The existing fork tests are the regression net. The new test contract goes alongside them in the same file (or a sibling file when the file is already large).
- **Strict equality, not "within tolerance".** Drift is a bug to root-cause, not a tolerance to widen. The only acceptable "delta" in the evidence pack JSON is `0`.

> **Older evidence packs (before 2026-11)** include a "Wiring the live dev-anvil dashboard" section that ran this
> repo's former Next.js dashboard (`app/`, since removed; the NAV pages now live in the KPK App). Those sections are
> a record of how each adapter was checked at the time; for new checks, read positions as in step 3.

## Folder shape

```
script/development/test/
├── README.md                 (this file)
└── <protocol>/
    ├── README.md             (case narrative + methodology specifics for this protocol)
    └── case-<slug>.json      (machine-readable evidence: account, chain, block, pools, expected, observed, delta)
```

Multiple cases per protocol are allowed when one account doesn't cover all paths (e.g. Aave V3 supply-only + Aave V3 supply+borrow → two cases). Be parsimonious.

## What goes in `case-*.json`

| Field | Meaning |
|---|---|
| `protocol` | Display name matching what the adapter's `protocolName()` returns (e.g. `PancakeSwap V3`, `Uniswap V2`). This is a label for the case file only — it is **not** read from deploy config: the `protocol` key there has been removed, and the name now comes from `ProtocolNames.forProtocolId(_protocolId())` for meta adapters or a bytecode literal for plain/assisted ones |
| `chain.id`, `chain.name` | Chain the test runs against |
| `holder.address` | The cherry-picked account |
| `holder.type` | `EOA` / `Contract` / `EIP-7702 delegated EOA` / `Safe` / `Treasury` — for context |
| `block.number` | Pinned block height |
| `block.timestamp` | UNIX timestamp of that block (sanity) |
| `positions[]` | One entry per pool / leg the account holds |
| `positions[].id` | Pool address (Uni V2) or position id (other protocols) |
| `positions[].label` | Human-readable identifier (e.g. `USDC/WETH`) |
| `positions[].lp` | Raw LP balance (or shares) at the block |
| `positions[].expected.<token>` | Expected underlying amount per tracked token, derived from the recorded ground-truth source |
| `positions[].observed.<token>` | What the adapter actually returns |
| `positions[].delta.<token>` | `observed - expected` (gross) and `(observed - expected) / expected * 100` (percent) |
| `verification.method` | Free-form label for how ground truth was obtained, e.g. `direct-onchain-read`, a forked-EVM `decreaseLiquidity`/`collect` (or `burn`/`redeem`) settlement simulation, or an independent canonical `balanceOf` |
| `verification.notes` | Anything noteworthy (e.g. "feeTo unset at this block, so no dilution branch") |

The goal is for any future contributor to be able to (a) re-derive the ground truth from the data here, (b) re-run the fork test, and (c) confirm the strict equality from scratch.

## Adapters in scope

Adapters from PRs #20, #25–#34, #35 (Aave V3 SM, Aave V2, Aave Umbrella, Merkl rewards, Compound V3, Stader withdrawal queue, Uniswap V2, Uniswap V3, Fluid f/Vaults T1, PancakeSwap V2/V3, plus the `PositionKind` multi-leg gross-emissions capstone). Started 2026-05-21 with **Uniswap V2**. Adapters are processed one at a time; each PR appends its protocol folder under this directory and adds the protocol to `script/deploy/04_DeployBalanceAdapters.s.sol` (instances disabled by default until a KPK strategy opens a real position there).
