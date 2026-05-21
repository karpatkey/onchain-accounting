# `script/development/test/` — balance-adapter verification evidence

One folder per protocol. Each folder holds the **evidence pack** behind the strict-equality fork test we add under `test/balances/protocols/fork/<Adapter>.fork.t.sol` for that protocol.

## Methodology (per protocol)

Mirrors the original V1-migration verification standard used for Balancer V3 / Aura / Curve / Convex. Refer to [`balance-adapter-verification-methodology`](../../../memory) for the long-form description.

1. **Cherry-pick one account** with the most complex realistic scenario for the protocol (supplied + staked + rewards, multi-leg debt, multi-pool LP, etc.). Goal: fewest accounts that exercise all paths.
2. **Pin a specific block** on the target chain.
3. **Use Tenderly** (simulations / Virtual TestNets) to compute the **exact** expected balances of the underlying tokens we track. For Uni V2 this is a `pair.burn(holder)` simulation, which returns the same numbers the adapter's pro-rata formula will compute.
4. **Strengthen** the fork test under `test/balances/protocols/fork/<Adapter>.fork.t.sol` with a new method that asserts **exact equality** against the Tenderly numbers at the pinned block. Existing fork tests remain — we **augment**, never replace.

## Side channel

User runs the local-anvil dev app at the same pinned block + cross-checks against Debank. Debank has live-vs-fork drift, but is useful as a smell test. The contract-side strict-equality assertion is the audit-grade source of truth.

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

See [`balance-adapter-verification-methodology`](../../../memory) for the full list (PRs #20, #25–#34, #35). Started 2026-05-21 with **Uniswap V2**.
