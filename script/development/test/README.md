# `script/development/test/` — balance-adapter verification evidence

One folder per protocol. Each folder holds the **evidence pack** behind the strict-equality fork test we add under `test/balances/protocols/fork/<Adapter>.fork.t.sol` for that protocol.

## Methodology (per protocol)

Mirrors the original V1-migration verification standard used for Balancer V3 / Aura / Curve / Convex. The full methodology is captured in this file plus per-protocol READMEs under `<protocol>/`; the same notes are also kept in the maintainer's persistent memory under the slug `balance-adapter-verification-methodology` (not a file in the repo).

### The five parallel steps

For each protocol, these five steps **must happen in parallel** so the verification turns around in one session rather than serialising on each piece. Sequential ordering wastes time — and worse, lets the user idle while the test is being written, or lets the test get written for a block the user can't visually cross-check.

| # | Step | Who | Output |
|---|---|---|---|
| 1 | **Find the account.** Cherry-pick one holder with the most complex realistic scenario for this protocol (supplied + staked + rewards, multi-leg debt, multi-pool LP, …). Goal: fewest accounts that exercise all paths. | Claude (with user sign-off on the candidate) | `holder.address` + scenario rationale |
| 2 | **Write the test folder.** Create `script/development/test/<protocol>/` with `README.md` (case narrative + verification table) + `case-<slug>.json` (machine-readable evidence pack). | Claude | Evidence pack scaffold, populated incrementally |
| 3 | **Run the app with the base deployments + the balance oracle under test, forked at the SELECTED block.** The dev anvil must pin at exactly the same block the fork test pins at, otherwise the side-channel cross-check vs Debank measures the wrong drift envelope. | Claude (refork helper + per-protocol adapter deploy on the fork) | User can see the holder's positions in the dashboard at the pinned block |
| 4 | **Add the strict-equality test** to `test/balances/protocols/fork/<Adapter>.fork.t.sol`. **Augment**, don't replace — existing fork tests stay. New test contract pinned at the same selected block. | Claude | New test contract with strict-equality assertions per leg |
| 5 | **Check everything is working as intended; fix drift.** User cross-checks the dev app vs Debank; Claude verifies test passes with zero drift vs the off-chain ground truth. If either surface diverges, root-cause it (block drift, derivation difference, real adapter bug). | Both, in parallel | Test ✅ + Debank-vs-app gap explained |

Drift envelope on the side channel = (now − pinned block timestamp). If you pinned at a fresh block (a few minutes back), the Debank-vs-app gap is bounded by minutes of natural pool activity, which is normally sub-bp at the dollar scale. Larger gaps need an explanation before the protocol can be marked verified.

### Hard constraints

- **The dev anvil fork block MUST equal the fork test's `FORK_BLOCK`.** If the refork hits the latest block, that block becomes the test's `FORK_BLOCK` — not the other way around. Don't pin the test at one block and the anvil at another.
- **Augment, don't replace.** Santi's existing fork tests are the regression net. The new test contract goes alongside them in the same file (or a sibling file when the file is already large).
- **Strict equality, not "within tolerance".** Drift is a bug to root-cause, not a tolerance to widen. The only acceptable "delta" in the evidence pack JSON is `0`.

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
| `protocol` | Display name matching `script/config/adapter-identities.json` |
| `chain.id`, `chain.name` | Chain the test runs against |
| `holder.address` | The cherry-picked account |
| `holder.type` | `EOA` / `Contract` / `EIP-7702 delegated EOA` / `Safe` / `Treasury` — for context |
| `block.number` | Pinned block height |
| `block.timestamp` | UNIX timestamp of that block (sanity) |
| `positions[]` | One entry per pool / leg the account holds |
| `positions[].id` | Pool address (Uni V2) or position id (other protocols) |
| `positions[].label` | Human-readable identifier (e.g. `USDC/WETH`) |
| `positions[].lp` | Raw LP balance (or shares) at the block |
| `positions[].expected.<token>` | Expected underlying amount per tracked token, derived from Tenderly |
| `positions[].observed.<token>` | What the adapter actually returns |
| `positions[].delta.<token>` | `observed - expected` (gross) and `(observed - expected) / expected * 100` (percent) |
| `verification.method` | `tenderly-burn-simulation` / `tenderly-vtn-bundle` / `direct-onchain-read` |
| `verification.notes` | Anything noteworthy (e.g. "feeTo unset at this block, so no dilution branch") |

The goal is for any future contributor to be able to (a) re-run the Tenderly simulation from the data here, (b) re-run the fork test, and (c) confirm the strict equality from scratch.

## Adapters in scope

Adapters from PRs #20, #25–#34, #35 (Aave V3 SM, Aave V2, Aave Umbrella, Merkl rewards, Compound V3, Stader withdrawal queue, Uniswap V2, Uniswap V3, Fluid f/Vaults T1, PancakeSwap V2/V3, plus the `PositionType` multi-leg gross-emissions capstone). Started 2026-05-21 with **Uniswap V2**. Adapters are processed one at a time; each PR appends its protocol folder under this directory and adds the protocol to `script/deploy/04_DeployBalanceAdapters.s.sol` (instances disabled by default until a KPK strategy opens a real position there).
