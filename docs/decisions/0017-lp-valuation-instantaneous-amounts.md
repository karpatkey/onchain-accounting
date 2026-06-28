# 0017 — LP-position valuation: report instantaneous underlying amounts; pool-liquidity manipulation is out of scope under an async / off-chain NAV consumer

- Status: Accepted

## Context

A security re-audit raised that the AMM-LP balance adapters value an LP position as the **pro-rata share of
the pool's _current_ reserves**, emitting one `PositionBalance` per underlying token; `NAVCalculator` then
prices each leg with that token's independent oracle and sums. For a constant-product pool an attacker can
flash-imbalance the reserves so the oracle-priced sum overshoots the true redemption value
(`2·√(k·pₓ·p_y)`) — the classic "fair LP pricing" problem — transiently **over-reporting NAV**. The
question raised: is this a real issue for *this* system, and what is the proper response?

This ADR records the conclusion and its boundary condition. It does **not** change any code.

Relevant facts established during the review:

1. **NAV is a read-only oracle with no atomic on-chain consumer.** `getAccountNav` /
   `getAccountNavVerbose` / `getAccountPositions*` are `external view` (`src/nav/NAVCalculator.sol`,
   `src/nav/INAVCalculator.sol`); no contract in `src/` consumes NAV. The tokenized-share /
   subscription-redemption layer is **explicitly out of scope** — "a separate layer above NAV"
   (`CLAUDE.md`, `README.md`). The reserve-imbalance attack is only *realisable* if a consumer reads NAV
   **synchronously, on-chain**, to price a share mint/redeem inside the same transaction.

2. **The intended consumer settles asynchronously.** Under an async / epoch / off-chain-settled share layer,
   the manipulate→mint/redeem→unwind sequence cannot be expressed atomically. To profit, an imbalance would
   have to *persist across the settlement window* against continuous arbitrage — which bleeds swap fees every
   block and is restored by arbitrageurs. The prior audit reached the same framing:
   *"NAV is an `eth_call` so no atomic exploit — off-chain-read concern only"*
   (`docs/audits/2026-06-vigilo-automated-audit.md`).

3. **Adapters report amounts, not values — by contract.** Per `CLAUDE.md` ("adapters only report balances;
   NAVCalculator adds prices and sums values"), the pro-rata share of *current* reserves is the **accurate
   instantaneous on-chain composition** — what the LP would redeem at that block. Manipulation-resistant
   "fair pricing" deliberately *deviates* from that truth (e.g. `virtual_price · min(price)` under-reports a
   balanced stable pool) and cannot be expressed as per-token `amount`s — it would fold pricing into the
   adapter and break the adapter ↔ `NAVCalculator` separation the whole design relies on.

4. **The unbounded (constant-product) case is not live.** `UniswapV2PoolsMeta` has **zero enabled
   instances** on any chain; `PancakeSwapV2PoolsMeta` is `enabled:false`; `BalancerV2*` is `enabled:false`.
   The live AMM-LP adapters are all **stable / correlated**: `CurvePoolsMeta` (StableSwap — crvUSD/USDC,
   crvUSD/USDT, weETH/WETH, ETH/stETH) + `CurveGaugesMeta` / `ConvexRewardsMeta` (same pools) +
   `BalancerV3PoolsMeta` / gauges (stable GHO pools). Amplification holds these near peg, so the imbalance
   deviation is small; the `√` over-report applies to the constant-product pools, which are not enabled.

5. **There is no single "fair price" formula.** `2·√(k·pₓ·p_y)` is constant-product only. Curve StableSwap
   needs `get_virtual_price() · min(oracle prices)`; Curve CryptoSwap / TriCrypto have no clean *external*
   formula (only the AMM-internal `lp_price()` / `price_oracle()`, which would violate the repo's "never
   trust an AMM price" rule). A pre-emptive fix is therefore a per-family redesign with an unsolved
   crypto-pool case — not justified against an out-of-scope threat.

## Decision

Balance adapters value LP positions as the **instantaneous pro-rata share of the pool's current reserves**,
emitted as per-token `amount`s and priced by `NAVCalculator` with the registered oracles. The system
**does not** adopt manipulation-resistant fair-LP pricing. Rationale:

- the only manipulation vector requires an **atomic, on-chain** NAV consumer, which is out of scope and (by
  the consumer's asynchronous design) economically infeasible;
- instantaneous underlying amounts are the adapter's correct, documented contract; fair-pricing would inject
  common-case error and break the adapter / NAV separation;
- the unbounded constant-product adapters are not enabled, and the live pools are stable / correlated (small
  deviation under amplification).

This applies uniformly to **all** AMM-LP adapters, including Uniswap V3 / PancakeSwap V3: those read the
pool's live `slot0` (`sqrtPriceX96` + `tick`) to derive the NFT's in-range token split and unclaimed fees —
the instantaneous on-chain composition, the V3 analogue of the V2/Curve/Balancer reserve share. (A Uniswap V3
NFT's split is not expressible as a simple reserve share — it depends on the current tick — so V3 reads
`slot0` rather than `balances()`, but the principle is identical: report the live on-chain amounts, do not
synthesise a manipulation-resistant price.) An earlier revision reconstructed the V3 `sqrtPriceX96` from
oracle prices to neutralise spot manipulation (audit `[2]`); that was reverted under this ADR because the
async-consumer model makes the manipulation non-monetisable and the oracle reconstruction sacrificed
common-case accuracy and the adapter/NAV separation. If the revisit trigger below ever fires, oracle-
reconstructed `sqrtPriceX96` is the V3-specific mitigation to reinstate.

## Consequences

### Negative / things to watch (the guardrail)

- **Revisit trigger.** If NAV is ever consumed **synchronously, on-chain** to price share mint/redeem with no
  async / TWAP / epoch buffer, this decision MUST be revisited. At that point either (a) the consumer samples
  NAV over time (TWAP / multi-block / epoch settlement), or (b) the LP adapters move to per-family
  manipulation-resistant valuation:
  - Uniswap V2 / PancakeSwap V2 (constant product): `(lp/ts)·2·√(k·pₓ·p_y)` with `k = reserve0·reserve1`,
    reserves reconstructed from oracle prices.
  - Curve StableSwap / metapool: `lp·get_virtual_price()·min_i(oraclePrice_i)` (the Chainlink Curve-LP-oracle
    method; conservative — under-reports a balanced pool, which is the safe direction).
  - Curve CryptoSwap / Tri/TwoCrypto: no clean external formula — bespoke design or exclude the pool.
  Whichever path, prefer the direction that can only **under**-report (per the repo's never-over-report rule).
- **Related deferred item.** The Balancer read-only-reentrancy finding (audit `M-A2`: pool reads not gated by
  the Vault reentrancy lock) shares the *same* guardrail — it too only bites an atomic on-chain consumer
  calling NAV from inside a Vault callback. It remains a separate, deferred hardening (a targeted
  `VaultReentrancyLib` guard), tracked independently of this ADR.

### Positive

- Adapters keep their single, simple contract (report on-chain amounts; NAV prices them) — no per-family
  pricing math, no `get_virtual_price` / AMM-internal-oracle dependencies, no unsolved crypto-pool case.
- Reported amounts match the true instantaneous on-chain composition in the common (un-manipulated) case,
  rather than a deliberately-skewed conservative estimate.

## References

- Threat-model framing: `docs/audits/2026-06-vigilo-adapter-audit.md` (read-only-reentrancy `M-A2`),
  `docs/audits/2026-06-vigilo-automated-audit.md` ("eth_call → no atomic exploit").
- Valuation code: `src/balances/MetaBalanceAdapters/curve/CurvePoolLib.sol` (`proRataAmount`),
  `src/balances/MetaBalanceAdapters/uniswap/UniswapV2PairLib.sol` (`pairAmounts`),
  `src/balances/MetaBalanceAdapters/balancer/BalancerV3PoolLib.sol` (`poolBalanceOfIndexed`).
- Oracle-reconstruction precedent (why V3 is different):
  `src/balances/AssistedBalanceAdapters/UniswapV3PoolsBalanceAdapter.sol`, [ADR 0008](0008-uniswap-v3-math-libs-gpl-license.md).
- Adapter/NAV separation + "report amounts, not values": `CLAUDE.md`, `src/balances/BALANCE_ADAPTERS.md`.
