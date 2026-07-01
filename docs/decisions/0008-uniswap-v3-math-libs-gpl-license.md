# 0008 — Uniswap V3 adapter: inline GPL-2.0 math libs alongside MIT adapter code

**Status:** accepted

## Context

The Uniswap V3 balance adapter (`src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolsMetaBalanceAdapter.sol`) needs three pieces of math from Uniswap to compute principal liquidity and unclaimed fees from a position's `(liquidity, tickLower, tickUpper)` plus the pool's `slot0` and `feeGrowth*` state:

- `TickMath.getSqrtRatioAtTick(int24)` — exponential-of-tick polynomial with ~20 magic constants.
- `LiquidityAmounts.getAmountsForLiquidity(...)` — concentrated-liquidity formula.
- `FixedPoint128.Q128` — a single fixed-point constant (`2^128`).

The upstream code in `Uniswap/v3-core` and `Uniswap/v3-periphery` is licensed `GPL-2.0-or-later` and pinned to `pragma solidity >=0.5.0 <0.8.0`, so we cannot just `forge install` it; it has to be ported to `^0.8` either way.

The rest of this repo, including every existing balance adapter, is `SPDX-License-Identifier: MIT`. Mixing GPL-2.0-or-later and MIT in the same compilation unit is the central question.

Three options were on the table:

1. **Inline minimal GPL libs alongside MIT adapter code, isolating them in a `lib/` subfolder with the original `GPL-2.0-or-later` SPDX header preserved.**
2. **Pull Aperture Finance's `uni-v3-lib` (`Aperture-Finance/uni-v3-lib`) as a `forge install` dependency.** Same `GPL-2.0-or-later` license footprint as option 1, plus a new external submodule and a remapping. Doesn't include `PositionValue` so we'd still inline the fee-computation logic ourselves.
3. **Re-implement `TickMath.getSqrtRatioAtTick` from scratch under MIT.** Requires re-deriving and re-testing the magic constants without referencing the Uniswap source. Most aggressive option, lowest legal risk, highest implementation risk (the polynomial constants are dense and adversarial to read; subtle errors in a port have shipped bugs in the past).

## Decision

Take **option 1**. Place `TickMath.sol`, `LiquidityAmounts.sol`, and `FixedPoint128.sol` under `src/balances/MetaBalanceAdapters/uniswap/lib/`, each carrying `// SPDX-License-Identifier: GPL-2.0-or-later` (verbatim from upstream) and a short header noting the port (replace `FullMath.mulDiv` with OpenZeppelin's `Math.mulDiv`, wrap `getSqrtRatioAtTick` in `unchecked` to preserve the 0.7 wrapping semantics, drop `getTickAtSqrtRatio` because the adapter doesn't need it). Because the adapter imports and links those libs, the adapter file itself also carries `// SPDX-License-Identifier: GPL-2.0-or-later` — there is no MIT file in this compilation unit.

Rationale:

- **Industry convention.** Every major MIT-licensed DeFi project that integrates Uniswap V3 — Gamma, Arrakis, ICHI, Maverick, Sommelier, Polynomial, etc. — ships GPL-licensed Uniswap math files alongside MIT contract code. Reviewers familiar with the ecosystem expect this exact layout, and it has not been litigated or contested in any of those projects.
- **Strict copyleft argument: the work is already a derivative.** Copyleft applies to combined works that are distributed. The compiled adapter calls into TickMath/LiquidityAmounts at runtime, so under a strict reading of GPL the binary is a combined work and the GPL terms govern distribution. We accept this: anyone redistributing the deployed bytecode or the source set is, as a practical matter, redistributing under GPL-2.0-or-later. That is a documented expectation of *all* downstream consumers of the adapter, not a hidden gotcha.
- **Math, not application code.** The files we're inlining are 100% pure math. There's no business logic, no protocol-specific reasoning, and no state. They exist because re-deriving the polynomial coefficients of `getSqrtRatioAtTick` is a meaningful undertaking with real risk of regression. The license cost of using them is small relative to the implementation cost of avoiding them.
- **Re-implementation is non-trivial.** A correct from-scratch `TickMath` has to reproduce 20+ magic constants and the rounding-up convention exactly; a one-bit error silently distorts every position calculation. Until the team has bandwidth for a clean-room port with equivalence fuzz testing, the GPL inline is the prudent path.

## Consequences

**Positive:**

- The adapter ships now, with math that is bit-exact equivalent to the upstream Uniswap reference, no novel correctness risk introduced.
- Files are isolated under `lib/` and clearly marked GPL — a reviewer or future contributor can see the license boundary at a glance.
- Same shape as the broader ecosystem; auditors recognize it.

**Negative / things to watch:**

- Anyone who consumes the deployed adapter's source (or uses it as a building block in another contract suite) inherits a GPL-2.0-or-later obligation on at least the math files, and arguably on the combined binary. Every adapter that does so should preserve the SPDX headers in the math files and link them.
- If the team later wants the adapter to be unambiguously MIT for a downstream consumer, the path is option 3 — clean-room re-implement `TickMath` and `LiquidityAmounts` with equivalence fuzz tests against the upstream reference. That's a discrete future project; this ADR doesn't preclude it.
- If a future Uniswap adapter (e.g. for a different pool type, V4 hooks, or direct-LP positions) needs the same math, it should reuse these `lib/` files rather than re-inlining. Keep the GPL surface to one folder.

## Convention going forward

For *any* future balance adapter that needs to inline upstream math from a non-permissively-licensed source:

- Place the files under `src/balances/{BalanceAdapters,MetaBalanceAdapters,AssistedBalanceAdapters}/lib/` (one folder per protocol).
- Preserve the upstream `SPDX-License-Identifier` verbatim — do not relicense them as MIT.
- Add a short `@dev` header to each file documenting the port (which functions were copied, which were dropped, what was substituted, and the upstream URL).
- Reference this ADR.
- Mark the adapter file that imports the libs `GPL-2.0-or-later` too: importing and linking GPL math makes the adapter a combined work, so its SPDX header should match (this is what the Uniswap V3 adapter does — `UniswapV3PoolsMetaBalanceAdapter.sol` is `GPL-2.0-or-later`, not MIT). A fork adapter that only consumes the GPL math *transitively* through an already-GPL parent is a combined work regardless of its own tag (`PancakeSwapV3PoolsMetaBalanceAdapter.sol` inherits the GPL Uniswap adapter and is therefore GPL-bound — its header is tagged `GPL-2.0-or-later` to match, see the addendum); the SPDX-matching guidance above is about the *direct* importer of the libs.

If a future situation calls for a different posture (clean-room MIT port, GPL-only adapter, dual-licensed lib, …), write a new ADR rather than amending this one.

## Addendum (2026-05-04): PancakeSwap V3 reuses these libs via inheritance

PancakeSwap V3 is a Uniswap V3 fork: same pool view surface, same NPM `positions` struct, same fee-growth math, same `LiquidityAmounts.getAmountsForLiquidity` mapping — so it reuses the Uniswap math libs via inheritance from `UniswapV3PoolsMetaBalanceAdapter`. (The two diverge on `slot0().feeProtocol` — `uint32` on PancakeSwap vs `uint8` on Uniswap V3 — so the fork overrides the narrow `_slot0()` hook to decode the matching ABI. An earlier audit recommendation to reconstruct the pool price from oracle feeds rather than reading `slot0` was superseded by ADR 0017's asynchronous-consumer model, which reinstated the live `slot0` read; the `_slot0()` override therefore still applies.)

Rather than ship a duplicate ~500-line `PancakeSwapV3PoolsMetaBalanceAdapter`, PancakeSwap V3 inherits `UniswapV3PoolsMetaBalanceAdapter` and reuses its Uniswap-math read path unchanged. The pattern mirrors the `SparkLend is AaveV3Instance` inheritance that this repo formerly used — note that `SparkLendBalanceAdapter.sol` has since been refactored into a standalone adapter and no longer inherits from an Aave V3 base, so PancakeSwap V3 is now the canonical example of this fork-via-inheritance pattern.

Implications for this ADR:

- The GPL-2.0-or-later combined-work obligation flows through inheritance the same way it flows through direct calls. `PancakeSwapV3PoolsMetaBalanceAdapter` consumes `TickMath`/`LiquidityAmounts`/`FixedPoint128` transitively via the parent and is therefore part of the same combined work. As of the 2026-06-26 license sweep its own header is `// SPDX-License-Identifier: GPL-2.0-or-later` (changed from `MIT`) so the per-file tag now matches the combined-work reality. (The tag was never what created the obligation: anyone redistributing the compiled fork adapter — or its source set, which pulls in the GPL parent and libs — is bound by GPL-2.0-or-later regardless of the header.)
- The convention "any future Uniswap-math consumer should reuse `lib/` rather than re-inlining" extends to fork adapters: they should reuse `src/balances/MetaBalanceAdapters/uniswap/lib/*` rather than copying the libs into `protocols/<fork>/lib/`. PancakeSwap V3 is the first such consumer.
- The `virtual` hook is intentionally narrow (single internal helper) so the GPL-bearing math stays in the parent. Future fork adapters that diverge in similar tightly-scoped ways (different pool ABI fields, different NPM, etc.) should follow the same pattern: virtualize the smallest hook that isolates the divergence.
- (2026-06-26, PR #120) The repo's first-party license has since moved from MIT to **BUSL-1.1** (see the root `LICENSE`). The MIT references in the original analysis above describe the repo state when this ADR was written; the move does not affect the GPL files — GPL-2.0-or-later still governs them and any combined work that incorporates them.
