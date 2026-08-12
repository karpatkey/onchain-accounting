#!/usr/bin/env python3
"""Deployer-EOA balance and gas-price check across every chain in the redeploy scope.

Produces a top-up list. It does NOT move funds and has no key material.

Per-chain cost is estimated as:

    need = (gasUnits x gasPrice) x FEE_VOLATILITY_HEADROOM

`gasUnits` comes from `--gas-units` (the rehearsal's measured numbers) or, absent that, from the
built-in per-step estimates below, which are deliberately generous — running out of gas midway through
a 24-chain deploy is far more expensive than over-funding.

`gasPrice` is the node's `eth_gasPrice` for most chains, but NOT for all: chains in
GAS_PRICE_OVERRIDE_WEI are priced from a pinned measured constant because their quote is not a usable
sizing input, and those rows say so in the output. The estimate does NOT include the L1
data-availability fee that rollups charge on top. Where that fee dominates, the chain fails closed
rather than being priced: scroll (~99.9% of total cost) and hemi (the omitted fee is 1.96x the entire
`need`, measured 2026-08-12). See L1_FEE_UNMODELLED and issue #287. Read `priceSource` on each row —
`need` is not in general "the live quote times gas".

Chain-specific workarounds are recorded in WORKAROUNDS below because they are easy to forget and
several have already cost a deploy. Two concern block/fee limits:
  * hyperevm (999): the NAV impl deploy is ~12.5M gas but HyperEVM's small blocks cap at ~3M. The
    deployer must switch the account to "big blocks" (~30M) via the Hyperliquid `evmUserModify` L1
    action before deploying, and switch back after.
  * hemi (43111): the chain enforces a fee floor; a tx priced off a naive `eth_gasPrice` is rejected,
    so `--with-gas-price` must be raised.

Three more concern the gas-price QUOTE itself, and they are three different mechanisms that present
identically as "the quote is too low to size from". They are why a single threshold is not enough —
see GAS_PRICE_IMPLAUSIBLE_WEI for the measurements: gnosis (100) quotes an honest but near-zero BASE
fee while inclusion is tip-driven; scroll (534352) quotes correctly at a hard 120,008 wei floor but
charges an L1 data-availability fee on top that this estimate does NOT model, so it fails closed
(#287); plasma (9745) pads its quote
with a large suggested tip nobody pays, so a threshold verdict on it flips between runs.

usage:
  python3 deployer_balances.py
  python3 deployer_balances.py --gas-units rehearsal-gas.json --json topup.json
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from concurrent.futures import ThreadPoolExecutor

import chainlib as c

# Gas units per chain role, from the deploy scripts' work. Refine with --gas-units once the fork
# rehearsal has measured the real numbers.
GAS_SHELL = 14_000_000        # 01 + 01_2 (2 libs + impl) + 02_2 (proxy + initialize + ERC20Default)
GAS_PER_FEED = 1_200_000      # one custom price feed deploy
GAS_PER_ADAPTER = 3_500_000   # one balance/meta adapter deploy (meta adapters are large)
GAS_PER_ASSET = 350_000       # registerAsset / addPriceFeed
GAS_PER_META_INSTANCE = 120_000
GAS_CONFIG_BASE = 800_000

# A quoted `eth_gasPrice` below this is not a usable price: the estimate collapses toward zero and
# `balance >= need` holds for any balance at all, so the test becomes a tautology.
#
# 50_000 wei (0.00005 gwei) is a MEASURED boundary, not a guess. It was chosen to separate three
# distinct mechanisms that all present as "quote too low" but need different handling:
#
#   * gnosis (100)  — baseFee measured 43-64 wei over 20 blocks, blocks 6.7-98.1% full, so EIP-1559
#     legitimately decays to its floor. The quote is arithmetically honest (baseFee + a ~31 wei
#     suggested tip) but it is the MINIMUM price, not the INCLUSION price: the median landed tx in
#     block 47671616 paid 1_000_000_048 wei = baseFee + exactly a 1 gwei tip, and the 20-block tip
#     p90 reached 9.8 gwei. Inclusion here is tip-driven and the tip is ~7 orders of magnitude above
#     the base fee. Unpriceable from the node; handled by GAS_PRICE_OVERRIDE_WEI below.
#   * scroll (534352) — baseFee measured EXACTLY 120_008 wei at -0/-5k/-50k/-200k/-1_000_000 blocks
#     with blocks 0.10-1.12% full. That is a hard enforced floor, not a decayed value; tip p10/p50/p90
#     are all exactly 100 wei and the landed tx paid exactly 120_108. The quote is CORRECT and is what
#     transactions actually pay, so the old 1_000_000 floor sat ~8x above scroll's genuine price and
#     mislabelled a correct quote as unusable. NOTE scroll still does NOT pass: its quote is usable now,
#     but its cost is dominated by an unmodelled L1 fee, so L1_FEE_UNMODELLED fails it closed (#287).
#   * plasma (9745)  — the opposite failure, and the reason a bare threshold is not enough. baseFee is
#     8 wei (constant at -0/-5k/-50k/-200k) but the node PADS eth_gasPrice with a large suggested tip:
#     measured quote 8_000_318 wei against a MEDIAN LANDED price of 9 wei. Its classification is
#     therefore unstable — it lands above this threshold when the node includes the tip and far below
#     when it does not, which is what "intermittently" in the runbook was describing. Neither value
#     reflects what txs pay, so plasma is pinned in GAS_PRICE_OVERRIDE_WEI rather than left to the
#     threshold to decide.
#
# The floor is deliberately NOT raised to cover gnosis: a 1 gwei floor was measured reporting TOP UP
# on 11 of 24 amply-funded chains, and a false alarm on 11 chains is its own failure. Chains that are
# genuinely cheap (scroll at 0.00012 gwei) must stay priceable; only a quote that cannot be sized from
# is UNPRICEABLE, and a chain whose real price is known is pinned instead.
#
# NOTE THE JUSTIFICATION HAS SHIFTED SINCE THIS VALUE WAS CHOSEN. The 20x lowering (1_000_000 -> 50_000)
# was argued from scroll, whose 120_008 wei quote is correct and was being mislabelled unusable — but
# scroll is now failed closed by L1_FEE_UNMODELLED regardless, so it no longer benefits. What still
# holds the floor here is the 11-of-24 false-alarm measurement, which is about the OTHER chains, not
# scroll. Raising it back would re-break nothing for scroll and re-break those 11, so the value stands;
# the reasoning for it does not rest where it originally did.
GAS_PRICE_IMPLAUSIBLE_WEI = 50_000  # 0.00005 gwei

# Per-chain gas price, in wei, used INSTEAD of the node's `eth_gasPrice`. For chains where the node's
# quote is not a usable sizing input in either direction. Each entry must carry its measurement.
#
# These make the chain priceable from a pinned constant rather than from the node, so `priceSource` is
# reported as "override" and a pass here is never evidence the node was trusted. Over-estimating is
# the safe direction for a funding check; under-estimating is not.
GAS_PRICE_OVERRIDE_WEI = {
    # gnosis: observed median landed price 1 gwei (baseFee ~48 + a 1 gwei client-default tip),
    # 20-block tip p90 9.8 gwei. 2 gwei = median + 100% margin. NOT derived from a test send.
    #
    # THIS PIN SITS BELOW THE p90 IT WAS MEASURED AGAINST, which qualifies the "over-estimating is the
    # safe direction" rule two paragraphs up: 2 gwei is 4.9x under the 9.8 gwei p90, and even with
    # FEE_VOLATILITY_HEADROOM the effective 4 gwei is 2.45x under it. A deploy landing in a p90 window
    # would cost more than `need` says. Left as-is because the margin absorbs it — gnosis holds 7.90
    # xDAI against a `need` of 0.147, ~53x — so no verdict flips; but that is a fact about today's
    # balance, not a property of the pin, and it is the same shape as the L1 headroom argument. Sizing
    # from a tip percentile rather than the median is the real fix and needs tip sampling this script
    # does not do. Re-derive by hand before a deploy if gnosis fees are elevated.
    100: 2_000_000_000,
    # plasma: node quote 8_000_318 wei vs median landed 9 wei; pinned above BOTH observed values so
    # the verdict cannot flip with whichever the node happens to return. Absolute cost is trivial
    # (14M gas x 0.01 gwei = 0.00014 XPL, and 0.00028 after FEE_VOLATILITY_HEADROOM — which is the
    # figure the script reports), so pinning high costs nothing.
    9745: 10_000_000,
}

# An override BELOW the implausibility floor would re-create the exact tautology the UNPRICEABLE third
# state exists to prevent — `need` collapses toward zero, `balance >= need` holds for any balance, and
# the row prints OK. Making that structural rather than documentary: a bad pin fails at import, not in
# a deploy-day reading. (Both current pins are orders of magnitude above the floor, so this asserts an
# invariant rather than fixing a live bug.)
_bad_overrides = {k: v for k, v in GAS_PRICE_OVERRIDE_WEI.items() if v < GAS_PRICE_IMPLAUSIBLE_WEI}
if _bad_overrides:
    # NOT an `assert`: asserts are stripped under `python -O` / PYTHONOPTIMIZE, which would silently
    # remove the one guard standing between a mistyped pin and the tautological pass this whole third
    # state exists to prevent. A deploy gate must enforce its invariants in every interpreter mode.
    raise ValueError(
        "GAS_PRICE_OVERRIDE_WEI entries must be >= GAS_PRICE_IMPLAUSIBLE_WEI "
        f"({GAS_PRICE_IMPLAUSIBLE_WEI}); a lower pin would produce a tautological pass: {_bad_overrides}")

# The two collections below and L1_FEE_OMITTED_PRICED define a deploy-gate invariant between them, and all
# three are hand-maintained. Divergence is checked at IMPORT so a bad edit fails immediately with a named
# cause, rather than only being caught at runtime by the fail-closed paths. Not an `assert`: `python -O`
# strips those, and this guards a deploy gate. (See the same reasoning on GAS_PRICE_OVERRIDE_WEI.)
#
# Chains whose cost includes an additive L1 data-availability fee that this script does NOT model.
#
# On a rollup the L1 fee is charged on top of (gas x gasPrice) and is not a rounding error: on scroll it
# measured ~99.9% of the total cost. So an execution-only figure on these chains is a LOWER BOUND, not
# an estimate. Modelling it is tracked in issue #287, which carries everything already measured.
#
# scroll FAILS CLOSED here rather than printing OK. It is the one chain where this matters immediately:
# lowering GAS_PRICE_IMPLAUSIBLE_WEI (above) makes its quote usable, so without this it would newly
# report a confident OK that omits ~99.9% of its cost — a preflight that looks fixed while lying about
# one chain, which is worse than the UNPRICEABLE it replaced.
#
# The eight OP-stack chains are deliberately NOT listed, and that decision was MEASURED rather than
# assumed. Each chain's own getL1Fee (OP-stack GasPriceOracle predeploy 0x420...0F, present on all eight)
# was summed per transaction over the shell payload. That measurement was originally recorded as at most
# 4.5e-7 ETH; it used a compressible payload, so the figure is understated ~59x and the corrected worst
# case is ~2.7e-5 ETH (mantle). THAT NUMBER IS SCALED FROM THE MEASURED RATIO, NOT RE-MEASURED PER
# TRANSACTION — the per-transaction split is still #287's, and an aggregate call is known to misprice
# against a sum of parts, so treat it as an order of magnitude and not a figure to quote.
#
# The robustness is what decides it, not the point estimate, and it survives the correction with room:
# for any of the eight to flip, the L1 term would have to exceed the entire current `need` by between one
# and three ORDERS OF MAGNITUDE, depending on the row. Deliberately stated that way and not as the precise
# ratio it was computed from: those ratios come from the same getL1Fee readings the paragraph above says
# to treat as an order of magnitude "and not a figure to quote", so quoting them here would break that
# rule two paragraphs later. On the tightest row (celo, `need` 5.60 native — and celo measures 0 for every
# payload at both probe sizes) the threshold is ~10^1 native against ~10^-5. The correction consumed 1.8
# orders of magnitude of an argument built to tolerate three, so no chain's verdict flips and none of the
# eight needs to fail closed. THE CONCLUSION IS WHAT IS CERTIFIED, NOT THE MARGIN — it holds across three
# orders of magnitude of error in the readings, which is why the imprecision does not weaken it.
#
# Scroll is categorically different — there the omitted term is ~99.9% of the cost — which is exactly why
# it alone fails closed, and why failing these eight closed would block a deploy over a margin that does
# not bite. Full table and the measured-vs-modelled split: REDEPLOY_RUNBOOK.md 0.6.
#
# EXPIRY: the robustness bound covers error in the FEE, not a falling BALANCE. Balance, l1BaseFee and
# blobBaseFee move independently, so the table establishes no flip AT THE BALANCES MEASURED, not that none
# can occur. THE TRIGGER IS ENFORCED, NOT ADVISORY: see L1_OMITTED_MIN_HEADROOM_WEI below — a row whose
# headroom (balance - need) falls under that absolute floor goes UNPRICEABLE by itself. An earlier draft of
# this comment said "re-measure below roughly 10x need"; that ratio was rejected (celo sits at 9.95x with
# ~50 CELO of headroom), so do not reintroduce it — the absolute floor is the rule.
#
# LIMIT, stated: the magnitude of those getL1Fee figures could not be independently certified (base returns
# 8.35e-9 ETH for the payload scroll charges ~1e-3 for, and a hand-check from its scalars did not reproduce
# it). Only the flip conclusion is certified, because it holds across three orders of magnitude of error.
# Modelling all TEN properly is #287 — the eight priced-with-omission chains plus scroll and hemi.
# (This said "nine" while L1_FEE_UNMODELLED held scroll alone; adding hemi moved the count, and
# #287's own issue text still says nine and should be widened.)
#
# HEMI (43111) WAS MISSING FROM BOTH COLLECTIONS AND PRINTED A CLEAN `OK` WHILE ~3x UNDER-FUNDED.
# Measured live 2026-08-12 against the same OP-stack GasPriceOracle predeploy every other rollup here
# uses (0x420...0F is present, 2,059 bytes of code):
#
#     getL1Fee(64,887-byte incompressible payload) = 54,845,469,617,243 wei = 5.485e-5 ETH
#     need (14e6 gas x 1,000,252 wei quote x 2)    = 28,007,056,000,000 wei = 2.801e-5 ETH
#     omitted L1 fee / entire need                 = 1.96x
#
# So the term this script does not model is TWICE the whole estimate, and roughly two thirds of hemi's
# real cost — categorically scroll's situation (dominant), not the eight OP chains' (immaterial, where
# the fee would have to exceed `need` by one to three orders of magnitude to flip). It reaches the fail-open scroll
# would have: fund the deployer to `need` and the gate says funded while the deploy costs ~3x that.
#
# Being in NEITHER collection meant hemi got none of the three guards — no regime probe, no
# L1_OMITTED_MIN_HEADROOM_WEI floor, and `shortfallExcludesL1=False`, so even its TOP UP figure would
# have been printed as if complete. It is failed closed here, like scroll, rather than added to the
# priced set: an execution-only figure for it is a LOWER BOUND, not an estimate, and no baseline
# measured under a regime this far from the others would make it one.
#
# NOTE this is not a defect this branch introduced — hemi's fee-floor quote (1,000,252 wei) cleared the
# OLD 1_000_000 floor too, so it was already priceable. What this branch did was build the L1-fee
# machinery and enumerate which chains charge one, and that enumeration missed a chain. hemi has its own
# WORKAROUNDS entry for the same fee floor, which is how it was hiding in plain sight.
L1_FEE_UNMODELLED = {534352, 43111}

# The eight chains that ALSO omit an L1 fee but are allowed to price, and the STRUCTURAL guard that keeps
# that safe. Naming them explicitly rather than leaving them as "everything not in L1_FEE_UNMODELLED",
# because the guard below has to iterate them.
#
# SCOPE OF THIS GUARD — IT IS BALANCE-ONLY, AND THAT IS NOT THE WHOLE STORY. It watches `balance - need`,
# and `need` EXCLUDES the L1 fee, so THIS guard reads neither l1BaseFee nor blobBaseFee. The fee axis is
# covered separately by the regime probe below (L1_REGIME_BASELINE_WEI), which does read each chain's
# oracle and fails closed on a large rise — so both axes are enforced, by two different checks.
#
# What #287 still owns is FULL FEE PRICING: adding the L1 term to `need`. The probe below only asks whether
# fee conditions still match the regime the margin table was measured under; it never prices the deploy.
#
# Sizing the residual that the probe tolerates rather than waving at it: the largest addition is ~2.7e-5
# native (mantle) against a 1e-3 floor, so fee conditions would have to worsen ~38x to breach it on a chain
# sitting right at the floor, and all eight sit far above. That factor was ~2,000x while this file measured
# the term with a compressible probe payload; see the payload note at _probe_payload.
#
# WHY A GUARD AT ALL. The measurement (see below) shows the omitted term does not flip any verdict — but
# that bounds error in the FEE, not a falling BALANCE. An earlier revision handled this with a runbook
# sentence ("re-measure below ~10x need"), which is a DOCUMENTARY guard: nothing enforced it, so a chain
# could drift into the range the document itself calls untrustworthy and still print OK. This branch has
# already replaced two documentary guards with structural ones; this is the third.
#
# WHY ABSOLUTE HEADROOM AND NOT A RATIO. The "10x need" rule was wrong on its own terms: celo sits at
# 9.95x (55.70020691 / 5.60002800) and would have been failed closed the moment the rule was enforced,
# despite ~50 CELO of headroom against a measured L1 addition of ~0. A ratio ignores the measured SIZE of
# the omitted term. So the guard is an absolute floor instead, derived from that size: 1e-3 native is ~38x
# the largest addition across the eight (mantle, ~2.7e-5 — corrected up from 4.5e-7, which was measured
# with a compressible probe payload). The floor VALUE is unchanged and still covers the term; only its
# stated margin shrinks, from ~2,200x to ~38x. If a balance falls so headroom drops under it, the row goes
# UNPRICEABLE by itself.
# THE UNDER-COMPUTED TOP-UP GAP, and why the guard is not the whole answer. `shortfallEth` is
# `need - bal`, and `need` OMITS the L1 fee on any chain that charges one — so a shortfall printed for
# such a chain tells the operator to send TOO LITTLE. That is wrong under either policy (fail all ten
# closed, or pass eight with an expiring omission), so it is fixed here rather than deferred to #287.
#
# The headroom guard below makes it unreachable for these eight today: if `bal < need` then headroom is
# negative, under the floor, so the row is UNPRICEABLE before any TOP UP verdict. But UNREACHABLE IS NOT
# CORRECT — it holds only while that guard exists and only for chains listed in one of these two sets. A
# chain that charges an L1 fee and is in NEITHER set is short-reportable today with an understated figure.
# So the row now carries `shortfallExcludesL1`, and the top-up line says LOWER BOUND / SEND MORE rather
# than relying on a guard elsewhere to keep the wrong number off the screen.
L1_FEE_OMITTED_PRICED = {10, 130, 204, 480, 5000, 8453, 42220, 57073}

# THE PARTITION IS NOW TOTAL, AND THAT IS THE POINT. The two sets above answer "does this chain charge
# an unmodelled L1 fee?" for the chains someone remembered to classify, and SILENCE meant "no" — which
# is how hemi printed a clean OK at ~1/3 of its real cost while sitting in neither. Silence is not an
# answer, so the remaining chains are classified explicitly into one of the two sets below and a test
# asserts the four sets cover the deploy scope exactly, with no overlaps.
#
# The distinction between these two is the whole value: one records a MEASUREMENT, the other records
# the ABSENCE of one. Collapsing them back into "not listed anywhere" is what this replaces.
#
# Measured to charge no such fee — each verified on-chain 2026-08-12, not inferred from the chain's
# marketing or its rollup family:
#   42161 arbitrum — no GasPriceOracle predeploy at all (codesize 0). Nitro charges its L1 component by
#                    INFLATING GAS UNITS, so `gas x price` already contains it; there is no additive
#                    term to omit. This is a different fee model, not an absent fee.
#   196   xlayer   — HAS the predeploy (codesize 2,059) and returns 0 for the 64,887-byte payload,
#                    exactly like celo. Present-but-zero is a real answer, and a different one from
#                    absent-oracle; both belong here, for different reasons.
#   1     mainnet  — no predeploy (codesize 0). It IS the L1; there is no DA fee to post.
#   100   gnosis   — no predeploy (codesize 0). Standalone L1, not a rollup.
#   143   monad    — no predeploy (codesize 0).
#   16661 0g       — no predeploy (codesize 0).
L1_FEE_NONE_VERIFIED = {42161, 196, 1, 100, 143, 16661}

# NOT VERIFIED, AND NOT THE SAME AS VERIFIED-ZERO. These endpoints were unreachable from the
# environment this classification was made in, so nothing was read from them. They are recorded as
# UNVERIFIED rather than quietly defaulted into "no fee", because defaulting is precisely the failure
# that produced hemi. They still PRICE today — this set is a documented gap, not a fail-closed — and
# the runtime discovery probe in `one()` covers them the moment their RPC answers.
#   9745  plasma     999   hyperevm    59144 linea
#   56    bsc        137   polygon     146   sonic
#   43114 avalanche  80094 berachain
# Several of these are obviously not rollups (bsc, polygon, avalanche), and it would be easy to write
# them into the verified set on that reasoning. That is exactly the inference that produced hemi — a
# chain classified by what it looked like rather than by what it returned — so they stay here until
# something reads them.
L1_FEE_UNVERIFIED = {9745, 999, 59144, 56, 137, 146, 43114, 80094}
L1_OMITTED_MIN_HEADROOM_WEI = 10**15  # 1e-3 native

# FEE-SIDE CHECK. The headroom guard above covers a falling BALANCE. This covers a rising FEE — the other
# axis, which an earlier revision claimed was enforced when it was not.
#
# It is a REGIME PROBE, NOT A FEE MODEL: `getL1Fee` calls on fixed reference payloads per chain, compared
# against baselines measured 2026-08-12 — the date matters, because the 2026-08-11 baselines were taken with
# the compressible payload described above and every one of the 16 was replaced when the payload changed.
# It does not price the deploy and does not need the payload split —
# it only answers "are fee conditions still the ones the margin table was measured under?" Modelling the
# fee properly is still #287.
#
# TWO PROBE SIZES. An earlier version probed at 4,096 bytes only, and was measured to have ZERO
# sensitivity to payload size: on base, getL1Fee(0) and getL1Fee(4096) returned an identical 971,132,088
# wei. THE ORIGINAL EXPLANATION FOR THAT WAS WRONG. This comment used to say 4 KB "sits entirely below the
# size-dependent region"; the actual cause was the compressible `"ff"` payload described above — 4 KB of a
# single repeated byte compresses to almost nothing, so both readings landed in the flat region. With the
# incompressible payload the size signal is present at both sizes, and the big/small ratio is 15.7787x
# rather than the 6.44x measured before (that 6.44x reproduces exactly on `"ff"`, which is how the artefact
# was identified). The consequence for the design is unchanged — one size alone cannot separate a base-fee
# move from a curve move — but the reason is compression, not a threshold in the fee schedule.
#
# Now both:
#   BIG (64,887 bytes)   — the region the real deploy payload occupies. Primary signal.
#   SMALL (4,096 bytes)  — the second point on the curve, so a base-fee move can be told apart from a
#                          curve move. NOT a "size-independent term": that framing was the artefact.
# Either exceeding L1_REGIME_MAX_RISE trips the fail-closed. Measured big/small ratio is 15.7787x on every
# chain that charges — identical to four decimals across all seven, which is itself the evidence that the
# fee is linear in compressed size with a per-chain scalar (celo returns 0 for both, i.e. no such fee). A
# change in that ratio is a curve change even if both readings stay under the limit individually.
#
# One probe pair captures both fee inputs and both scalars at once, which is why this is used instead of
# reading l1BaseFee/blobBaseFee separately. (It also avoids a selector trap: OP-stack exposes
# `blobBaseFee()` 0xf8206140 while scroll exposes `l1BlobBaseFee()` 0x84189161 — reusing scroll's selector
# on an OP chain reverts.)
#
# THRESHOLD — THE ADEQUACY CLAIM FOR 100x IS RETRACTED. NO REPLACEMENT NUMBER IS OFFERED HERE.
#
# THE GAP, stated for whoever deploys this: headroom is ~38x the largest addition (mantle ~2.7e-5 native
# against a 1e-3 floor), and this probe does not trip until a 100x rise. So there is a window — roughly 38x
# to 100x — in which a row sitting near the floor can have its headroom consumed by the omitted L1 fee
# while the probe stays quiet and the row still prints OK. On that row, OK does not mean funded. Every
# chain sits far above the floor today, so the window is not currently occupied, but that is a fact about
# today's balances and not a property of this guard.
#
# WHY NO NEW NUMBER. Two previous revisions of this comment asserted the threshold was comfortably covered:
# one claimed ~2,000x headroom with ~20x slack after a 100x rise, the next claimed 100x was "conservative"
# and "retained deliberately". Both were written confidently and both were wrong about the margin — the
# first because it was computed from a compressible-payload measurement understated ~59x, the second
# because it restated adequacy after that correction rather than re-deriving it. The defect is not in the
# arithmetic but in a method that keeps producing confident numbers from an argument that cannot see its
# own gap, so a third number derived under the same method would carry the same defect. 100x is left in
# place as a documented tripwire of UNJUSTIFIED width, not as a bound anyone should rely on.
#
# WHAT IS STILL TRUE, and is the only thing this guard should be credited with: it only ever TRIPS a
# fail-closed and never prices, so it cannot make a row pass that would otherwise fail. Sizing the term
# — so this can be a computed bound rather than a judgement — is #287.
#
# FEE MODE IS NOT VALIDATED, and the reason is measured rather than assumed. The other half of the review
# remedy was "validate the active mode". The OP mode getters are NOT uniform across these chains, measured
# 2026-08-11 against 0x420...0F:
#   10, 130, 480, 8453, 42220, 57073 -> isEcotone=1 isFjord=1 isIsthmus=1
#   204 opbnb                        -> isEcotone=1 isFjord=1 isIsthmus REVERTS (older oracle)
#   5000 mantle                      -> ALL THREE REVERT, yet getL1Fee works — so mantle is not a standard
#                                       OP-stack oracle at all, which also qualifies the "membership is by
#                                       rollup family, not measured" caveat above.
# A naive mode check would therefore have to treat a revert as "mode unknown" and fail mantle and opbnb
# closed on interface discovery done in a single pass. Not done here; #287 owns it, with this table so it
# does not have to be rediscovered. The two-point probe above already covers the concrete risk: a mode
# change that alters the fee shows up in the readings at one or both sizes.
#
# celo's baselines are 0: its oracle returns 0 for both probes, so it appears not to charge this fee at all.
# A baseline of 0 is handled as "any non-zero reading is a regime change", which is the strict reading.
L1_REGIME_PROBE_BYTES_SMALL = 4_096
L1_REGIME_PROBE_BYTES_BIG = 64_887
L1_REGIME_BASELINE_SMALL_WEI = {
    10: 29_154_587_307, 130: 16_807_919_621, 204: 222_625_229_120, 480: 37_886_158_749,
    5000: 561_191_527_000, 8453: 19_604_525_626, 42220: 0, 57073: 23_987_529_457,
}
L1_REGIME_BASELINE_WEI = {
    10: 460_022_809_041, 130: 265_207_883_646, 204: 3_512_746_799_722, 480: 597_796_051_356,
    5000: 8_854_898_199_511, 8453: 309_334_817_654, 42220: 0, 57073: 378_493_118_983,
}
L1_REGIME_MAX_RISE = 100
OP_GAS_ORACLE = "0x420000000000000000000000000000000000000F"
OP_GET_L1_FEE = "0x49948e0e"

# THE PROBE PAYLOAD MUST BE INCOMPRESSIBLE, and the reason is measured, not stylistic. Post-Fjord
# `getL1Fee` prices the FASTLZ-COMPRESSED size of the payload, not its raw length — and `isFjord()` is 1
# on seven of these eight chains (only mantle reverts every mode getter, yet behaves identically here).
# An earlier version of this probe sent `"ff" * n`, which is near-maximally compressible, and the
# baselines were measured with it. Measured 2026-08-12 at one pinned block per chain, the ratio to this
# incompressible payload is IDENTICAL to four significant figures on every chain that charges:
#
#     size          zero/ff    incompressible/ff    real-creation-bytecode/ff
#     4,096 bytes    1.0000              35.4684                      25.6562
#    64,887 bytes    1.0000              86.9003                      59.1957
#
# So the old probe understated real deploy calldata by ~59x, and the chain-independence of the ratio
# says the fee is linear in compressed size with a per-chain scalar. That also retires the reasoning
# behind an earlier note in this file: "1000 zero bytes == 1000 0xff bytes, so the fee is not
# byte-value sensitive". Both operands were maximally compressible, so equal prices were the expected
# result either way and the experiment could not distinguish the hypotheses.
_PROBE_SEED = b"onchain-accounting/deployer_balances/regime-probe/v1"


def _probe_payload(n: int) -> str:
    """Hex for an `n`-byte regime probe, ABI-padded to a 32-byte boundary.

    An iterated-sha256 keystream: incompressible in practice, and DETERMINISTIC FOREVER, which is what
    baseline comparability requires — a baseline is only meaningful against the exact bytes it was
    measured with. Real artifact bytecode was rejected as the probe payload for that reason: it is more
    representative, but it changes whenever a contract changes, which would silently invalidate every
    baseline below. Representativeness is #287's problem (real per-transaction `input` bytes from the
    fork rehearsal); this function's only job is to be a stable, hard-to-compress yardstick.

    DO NOT change the seed or this construction without re-measuring all 16 baselines in the same pass.
    """
    buf = bytearray()
    h = hashlib.sha256(_PROBE_SEED).digest()
    while len(buf) < n:
        buf += h
        h = hashlib.sha256(h).digest()
    return bytes(buf[:n]).hex() + "00" * (-n % 32)

_missing_baseline = (L1_FEE_OMITTED_PRICED - set(L1_REGIME_BASELINE_WEI)) | (
    L1_FEE_OMITTED_PRICED - set(L1_REGIME_BASELINE_SMALL_WEI))
_dead_baseline = (set(L1_REGIME_BASELINE_WEI) | set(L1_REGIME_BASELINE_SMALL_WEI)) - L1_FEE_OMITTED_PRICED
# DISJOINTNESS ACROSS ALL FOUR SETS, not just the original two. A chain in two of them is a
# contradiction wherever it appears, and pairwise-checking only the first pair is how a third set
# silently becomes a place to hide a second classification.
_L1_SETS = (("priced-with-omission", L1_FEE_OMITTED_PRICED), ("failed-closed", L1_FEE_UNMODELLED),
            ("verified-no-fee", L1_FEE_NONE_VERIFIED), ("unverified", L1_FEE_UNVERIFIED))
_overlaps = {f"{a} & {b}": sorted(sa & sb)
             for i, (a, sa) in enumerate(_L1_SETS) for b, sb in _L1_SETS[i + 1:] if sa & sb}
if _missing_baseline or _dead_baseline or _overlaps:
    raise ValueError(
        "L1 fee collections are inconsistent — fix before running a deploy gate. "
        f"priced-with-omission but no regime baseline (probe would fail closed): {sorted(_missing_baseline)}; "
        f"baseline with no chain to apply it to (dead entry): {sorted(_dead_baseline)}; "
        f"a chain classified two ways at once (contradictory): {_overlaps}")

# Multiplier applied to `gas x gasPrice`, which is the WHOLE of what this script estimates — a deploy
# spans many blocks and the execution price moves under it.
#
# IT DOES NOT COVER THE L1 DATA-AVAILABILITY FEE, and an earlier version of this comment claimed it did
# ("the FULL cost estimate (execution + any L1 data fee)"). That was false in a load-bearing way: `need`
# is `gas * price * FEE_VOLATILITY_HEADROOM` and the L1 term is not one of its inputs, so there is no
# such term here to multiply. Reading it as covered would corrupt two arguments that depend on the
# opposite: the ~38x residual sizing at L1_OMITTED_MIN_HEADROOM_WEI and the 38x-to-100x window in the
# retraction at L1_REGIME_MAX_RISE both weigh the omitted fee (~2.7e-5 native) against the absolute
# headroom floor (1e-3 native), and NEITHER of those two operands passes through this multiplier. It
# would also mislead #287, which has to ADD the term rather than assume it is already padded.
FEE_VOLATILITY_HEADROOM = 2

# THE FILE'S OWN RULE, APPLIED TO THE FILE'S OWN CONSTANTS. Every guard here is structural rather than
# documentary — except that the constants the guards are built from were themselves unguarded. Each of
# the three below is a multiplicand or a floor in the verdict path, and setting any of them to 0 (a
# plausible mis-edit, and exactly the kind of change that looks harmless in a diff) re-creates the
# tautological pass this whole third state exists to prevent, with NOTHING firing:
#   * FEE_VOLATILITY_HEADROOM = 0 -> `need` is 0 -> `bal >= need` for every balance including zero
#   * GAS_UNITS_IMPLAUSIBLE  = 0 -> the gas floor stops rejecting a zero-gas estimate
#   * GAS_PRICE_IMPLAUSIBLE_WEI = 0 -> the price floor stops rejecting a zero quote, AND the
#     _bad_overrides check above silently becomes vacuous, since every pin is then >= 0
# The third is the sharpest: it would disarm an existing invariant without touching it.
#
# Found by an extractor rather than by reading, which is the point — three review passes read past it.
# `raise`, not `assert`, for the same reason as every other invariant here: `python -O` strips asserts
# and CI runs this suite under -O precisely to keep that honest.
# The check itself lives below GAS_UNITS_IMPLAUSIBLE (defined later, at the gas-estimate section)
# so all three are asserted in ONE place rather than split across the file — search `_dead_floors`.

WORKAROUNDS = {
    100: "near-zero base fee: the node quote is the BASE fee, not the inclusion price (median landed "
         "tx pays ~1 gwei in TIP). Deploy with BOTH --with-gas-price 2000000000 AND "
         "--priority-gas-price 2000000000: forge's --with-gas-price sets only maxFeePerGas on an "
         "EIP-1559 tx, so on its own it leaves maxPriorityFeePerGas at the node's ~31 wei suggestion — "
         "the exact value this workaround exists to override. The check prices this chain from "
         "GAS_PRICE_OVERRIDE_WEI, not from the node",
    999: "big blocks: enable via Hyperliquid evmUserModify (usingBigBlocks=true) before 01_2/02_2, "
         "disable after — the ~12.5M-gas impl deploy does not fit HyperEVM's ~3M small blocks",
    9745: "unstable quote: node pads eth_gasPrice with a large suggested tip (measured 8000318 wei "
          "against a 9 wei median landed price), so a threshold verdict flips run to run. Priced "
          "from GAS_PRICE_OVERRIDE_WEI instead",
    43111: "fee floor: raise --with-gas-price; a naive eth_gasPrice quote is rejected. BUT NO GAS-PRICE "
           "FLAG MAKES THIS ROW AUTHORITATIVE — hemi's omitted L1 data-availability fee measured "
           "5.485e-5 ETH against a whole `need` of 2.801e-5 ETH (1.96x the entire estimate, ~2/3 of its "
           "real cost) on 2026-08-12, so it fails closed like scroll. Fund it out of band or top it up "
           "generously until #287 models the fee",
    # Deliberately carries NO figure. There is nothing to quote: scroll is not priced here at all, so a
    # number in this string could only be a stale copy of something the script does not compute.
    534352: "its quote is correct and now usable, but ~99.9% of its cost is an L1 data-availability "
            "fee this script does not model, so it fails closed rather than reporting a number that "
            "omits almost all of its cost. THE GATE IS NOT AUTHORITATIVE FOR SCROLL until issue #287 "
            "lands; fund it out of band or top it up generously",
}


def scope(chain_id: int) -> dict:
    """What actually gets deployed on this chain."""
    nav_meta = json.loads((c.NAV_CONFIG_DIR / "meta-balance-adapters" / f"{chain_id}.json").read_text()) \
        if (c.NAV_CONFIG_DIR / "meta-balance-adapters" / f"{chain_id}.json").exists() else {}
    nav_plain = json.loads((c.NAV_CONFIG_DIR / "balance-adapters" / f"{chain_id}.json").read_text()) \
        if (c.NAV_CONFIG_DIR / "balance-adapters" / f"{chain_id}.json").exists() else {}
    feeds = json.loads((c.CONTRACTS_CONFIG_DIR / "custom-price-feeds" / f"{chain_id}.json").read_text()) \
        if (c.CONTRACTS_CONFIG_DIR / "custom-price-feeds" / f"{chain_id}.json").exists() else {}
    assets = json.loads((c.NAV_CONFIG_DIR / "assets-and-price-feeds" / f"{chain_id}.json").read_text()) \
        if (c.NAV_CONFIG_DIR / "assets-and-price-feeds" / f"{chain_id}.json").exists() else {}

    def on(d):
        return [k for k, v in d.items() if isinstance(v, dict) and v.get("enabled") is True]

    metas = on(nav_meta)
    assistants = len([k for k in c.deployment(chain_id) if k.endswith("Assistant")])
    return {
        "metaAdapters": len(metas),
        "plainAdapters": len(on(nav_plain)),
        "assistants": assistants,
        "feeds": len(on(feeds)),
        "assets": len([k for k in assets if not k.startswith("$")]),
        "metaInstances": sum(len(nav_meta[m].get("instances", []) or [])
                             + len(nav_meta[m].get("instancesRaw", []) or []) for m in metas),
    }


# The OTHER multiplicand, and it was the one input axis left without a floor. `need` is
# `gas x price x headroom`; every degenerate value of `price` was given a structural fail-closed on this
# branch, while `gas` could still silently reach 0 and collapse `need` to 0 — after which `bal >= need`
# holds for ANY balance including zero and the row prints an authoritative OK. That is the identical
# tautology GAS_PRICE_IMPLAUSIBLE_WEI exists to prevent, reached from the other side.
#
# It is not hypothetical. `--gas-units` takes the rehearsal's measured numbers as
# `{chainId: {"total": <gas>}}`, and `gas_estimate` read `override.get("total", 0)` — so ANY override
# dict without a `total` key silently became 0. The rehearsal writes `$WORK/steps.tsv` whose per-step
# column is literally named `gas` (rehearse_fork.sh:86), so `{"100": {"gas": 36730000}}` is the natural
# mis-transcription, and it produced `0 short, 0 unpriceable — all 24 chain(s) priced and funded` on an
# empty deployer.
#
# 1_000_000 is chosen against the built-in estimates rather than picked: every chain in scope deploys at
# least the shell (GAS_SHELL = 14_000_000), and the smallest single contract deploy here is ~200k, so a
# TOTAL under 1M cannot be a real deploy on any chain. Deliberately far below 14M so a legitimately
# reduced scope is not failed closed — this catches nonsense, not thrift.
GAS_UNITS_IMPLAUSIBLE = 1_000_000

# See the note at FEE_VOLATILITY_HEADROOM. All three verdict-path floors/multiplicands asserted here,
# in one place, because a 0 in any of them re-creates the tautological pass with nothing else firing.
_dead_floors = {n: v for n, v in (("FEE_VOLATILITY_HEADROOM", FEE_VOLATILITY_HEADROOM),
                                  ("GAS_PRICE_IMPLAUSIBLE_WEI", GAS_PRICE_IMPLAUSIBLE_WEI),
                                  ("GAS_UNITS_IMPLAUSIBLE", GAS_UNITS_IMPLAUSIBLE))
                if v < 1}
if _dead_floors:
    raise ValueError(
        "these constants are multiplicands or floors in the verdict path and must be >= 1; at 0 they "
        f"collapse `need` and make `balance >= need` a tautology: {_dead_floors}")


def gas_estimate(s: dict, override: dict | None) -> int:
    if override:
        # `.get("total", 0)` kept, but 0 is no longer a silent pass — `one()` fails the row closed on
        # anything under GAS_UNITS_IMPLAUSIBLE. Returning a value rather than raising, so the row can
        # report WHICH chain and WHAT value instead of killing the whole 24-chain run.
        #
        # THAT PROMISE WAS FALSE UNTIL THIS CATCH EXISTED, and the comment made it anyway. `gas_estimate`
        # is called from `one()` OUTSIDE every try block, so a `total` that is not int-convertible — the
        # string "36730000" is fine, but `null`, a list, or "36,730,000" is not — raised ValueError or
        # TypeError straight out of `main()` and aborted the run on chain N, discarding the verdicts for
        # every chain after it. A malformed --gas-units file is exactly the input this branch already
        # showed an operator producing by hand.
        #
        # A bad value is now 0, which the GAS_UNITS_IMPLAUSIBLE floor turns into a per-row UNPRICEABLE
        # naming the chain — the behaviour the comment claimed all along.
        # CATCH-ALL, AND DELIBERATELY SO. An earlier version caught only (TypeError, ValueError), which
        # covers a bad `total` but NOT a bad shape: `{"100": 36730000}` — the flat form, at least as
        # natural a mis-transcription as the wrong key — makes `override` an int, and `override.get`
        # raises AttributeError, which escaped and aborted the whole 24-chain run. That is the outcome
        # the paragraph above claims this prevents.
        #
        # Enumerating exception types here has the same defect as enumerating probe outcomes did: the
        # next unexpected shape is unhandled. The contract is total — return a gas number, or 0, which
        # the GAS_UNITS_IMPLAUSIBLE floor turns into a per-row UNPRICEABLE naming the chain. There is no
        # failure mode where continuing with 0 is worse than aborting, because 0 cannot certify anything.
        try:
            return int(override.get("total", 0))
        except Exception:  # noqa: BLE001
            return 0
    return (GAS_SHELL
            + s["feeds"] * GAS_PER_FEED
            + (s["metaAdapters"] + s["plainAdapters"] + s["assistants"]) * GAS_PER_ADAPTER
            + s["assets"] * GAS_PER_ASSET
            + s["metaInstances"] * GAS_PER_META_INSTANCE
            + (GAS_CONFIG_BASE if (s["metaAdapters"] or s["plainAdapters"]) else 0))



def one(chain_id: int, gas_units: dict) -> dict:
    name = c.chain_config(chain_id).get("name", "?")
    deployer = (c.chain_config(chain_id).get("addresses") or {}).get("admin")
    s = scope(chain_id)
    gas = gas_estimate(s, gas_units.get(str(chain_id)))
    row = {"chainId": chain_id, "name": name, "deployer": deployer, "scope": s,
           "gasUnits": gas, "workaround": WORKAROUNDS.get(chain_id)}
    url, note, rejected = c.probe_rpc(chain_id)
    row["rpc"] = note
    if not url:
        row["error"] = "; ".join(rejected) or note
        return row
    try:
        bal = int(c.rpc(url, "eth_getBalance", [deployer.lower(), "latest"]), 16)
        quoted = int(c.rpc(url, "eth_gasPrice", []), 16)
    except Exception as e:  # noqa: BLE001
        row["error"] = str(e)
        return row
    override = GAS_PRICE_OVERRIDE_WEI.get(chain_id)
    price_note = None
    gas_note = None
    if override is not None:
        price, price_source, priceable = override, "override", True
        # A PIN CAN GO STALE, AND STALE IN THE UNSAFE DIRECTION IS SILENT. The override replaces the
        # quote unconditionally, so if the real price rises past the pin this row keeps sizing at the pin
        # and prints an authoritative OK from an under-estimate. That is the same fail-open shape as
        # pricing from an implausibly low quote — which is the defect the UNPRICEABLE third state exists
        # to prevent — except nothing in the output would show it.
        #
        # The trigger is A PLAUSIBLE QUOTE ABOVE THE PIN, and it fails the row closed rather than
        # adopting either number. Taking the higher of the two (`max(pin, quoted)`) was REJECTED: plasma's
        # quote is node-side PADDING, measured at 8_000_318 wei against a median landed price of 9 wei, so
        # max() would size a deploy from a number this file has already measured as meaningless and would
        # reintroduce precisely the node-dependence the pin was created to remove. A pin that no longer
        # bounds the price has one correct response — remeasure it — so the row demands that.
        #
        # WHAT THIS DOES NOT COVER, STATED PLAINLY, BECAUSE THE TWO PINS FAIL DIFFERENTLY:
        #   plasma (9745) — quote 8_000_318 wei against a 10_000_000 wei pin: only 1.25x. The node's
        #     padding is what this guard watches, and it is the thing that moves, so the guard is
        #     meaningful here. A trip is a FALSE alarm about plasma's real cost (trivial, ~0.00028 XPL)
        #     but a fail-CLOSED one: it asks for a remeasurement rather than sizing from a stale pin.
        #   gnosis (100)  — THE GUARD IS STRUCTURALLY BLIND TO THE WAY THIS PIN ACTUALLY GOES STALE, and
        #     saying otherwise would overstate the coverage. The 2 gwei pin was derived from the observed
        #     TIP (median landed 1 gwei + 100%), but `eth_gasPrice` here returns baseFee + a ~31 wei
        #     suggestion and does NOT track that tip — measured 95 wei against a 2e9 pin, ~2e7x apart.
        #     So the inclusion price can rise past 2 gwei with the quote barely moving, and this guard
        #     will not fire. It only ever catches the case where the QUOTE overtakes the pin. Detecting
        #     gnosis's real staleness mode needs tip sampling (a percentile over recent blocks), which
        #     this script does not do; re-derive the pin by hand when gnosis fees are in question.
        #
        # NO PLAUSIBILITY TERM HERE, AND THAT IS A COUPLING WORTH NAMING. An earlier version read
        # `quoted >= GAS_PRICE_IMPLAUSIBLE_WEI and quoted > override`, whose first conjunct is DEAD:
        # the import-time `_bad_overrides` check (:131-138) forces every pin >= that floor, so
        # `quoted > override` already implies `quoted >= GAS_PRICE_IMPLAUSIBLE_WEI`. Worse, the comment
        # justified it as mattering "for gnosis specifically" — false, since gnosis fails `quoted >
        # override` first and never reaches it — and the test covering it had to patch in a pin BELOW
        # the floor, a configuration the module raises on at import, so it certified a state that
        # cannot exist. If that import invariant is ever relaxed, restore a plausibility term here.
        if quoted > override:
            priceable = False
            price_note = (f"the pinned gas price ({override} wei) is BELOW the node's plausible quote "
                          f"({quoted} wei), so the pin no longer bounds the price and sizing from it "
                          f"would UNDER-estimate — remeasure and re-pin GAS_PRICE_OVERRIDE_WEI[{chain_id}] "
                          f"rather than adopting either number")
    else:
        price, price_source = quoted, "node"
        priceable = quoted >= GAS_PRICE_IMPLAUSIBLE_WEI
    # THE GAS AXIS FAILS CLOSED TOO. `need` has two multiplicands and only one of them was guarded; a
    # zero or nonsense `gas` collapses `need` exactly as an implausible price does. See
    # GAS_UNITS_IMPLAUSIBLE for why a mis-keyed `--gas-units` file is the realistic way in.
    if gas < GAS_UNITS_IMPLAUSIBLE:
        priceable = False
        gas_note = (f"gas units for this chain are {gas}, below the {GAS_UNITS_IMPLAUSIBLE} floor and far "
                    f"under the {GAS_SHELL} the shell deploy alone costs — `need` computed from it is "
                    f"meaningless and `balance >= need` would hold for any balance. Check the "
                    f"--gas-units file uses {{\"<chainId>\": {{\"total\": <gas>}}}}; a missing `total` key "
                    f"reads as 0")
    # Volatility headroom on the whole estimate. A deploy spans many blocks and fees move under it.
    need = gas * price * FEE_VOLATILITY_HEADROOM

    # Chains whose cost is dominated by an unmodelled L1 data-availability fee FAIL CLOSED rather than
    # reporting an execution-only figure. That figure is a lower bound, not an estimate, and printing it
    # as OK is the same defect as a checker returning success without checking — precisely what the
    # UNPRICEABLE third state exists to prevent. See L1_FEE_UNMODELLED and issue #287.
    l1_note = None
    if priceable and chain_id in L1_FEE_OMITTED_PRICED:
        # Fee-side regime check. Deliberately NOT gated on `chain_id in L1_REGIME_BASELINE_WEI`: gating on
        # it meant a chain added to L1_FEE_OMITTED_PRICED without a baseline SILENTLY SKIPPED this probe and
        # passed on the balance guard alone — a fail-open in the check added to close a fail-open. A missing
        # baseline is now an unverifiable regime, which fails closed like any other. Both collections are
        # hand-maintained, so the divergence is a realistic edit rather than a hypothetical.
        try:
            # KeyError on either baseline is caught below and fails closed.
            # THE LABELS NAME WHICH PROBE TRIPPED, NOT WHAT CAUSED IT, and the previous pair
            # ("payload-size" / "base-fee") asserted causes this reading cannot establish — the small
            # one close to backwards. BIG is checked first and the loop BREAKS on the first trip, so the
            # small label is only ever reached when big did NOT trip and small did: the two readings
            # moved apart, i.e. the RATIO changed, which is a curve move — the opposite of the base-fee
            # move the old label named. (A pure base-fee move scales both readings together and trips
            # big first.) Diagnosing the cause needs both readings and the 15.7787x ratio; the guard
            # only establishes that the regime no longer matches, so the message now says that and
            # leaves the diagnosis to #287.
            pairs = ((L1_REGIME_PROBE_BYTES_BIG, L1_REGIME_BASELINE_WEI[chain_id], "big-payload"),
                     (L1_REGIME_PROBE_BYTES_SMALL, L1_REGIME_BASELINE_SMALL_WEI[chain_id], "small-payload"))
            # BOTH PROBES PIN TO ONE BLOCK. Passing `latest` per call let the two readings land on
            # different blocks, so an upgrade or fee change between them could produce a hybrid snapshot
            # and hide the size-dependent move this guard exists to catch. That requirement was already
            # established for the scroll helper and recorded in #287 and the runbook — the OP probe was
            # written fresh and did not inherit it, which is the same fix-creates-its-sibling shape this
            # branch keeps hitting: a rule attached to one call site does not travel to the next.
            probe_block = c.rpc(url, "eth_blockNumber", [])
            tripped = None
            for n, base, axis in pairs:
                payload = _probe_payload(n)
                now = int(c.rpc(url, "eth_call", [{"to": OP_GAS_ORACLE,
                                                   "data": OP_GET_L1_FEE + f"{32:064x}" + f"{n:064x}"
                                                   + payload}, probe_block]), 16)
                if (now > 0) if base == 0 else (now > base * L1_REGIME_MAX_RISE):
                    tripped = (now, base, axis, n)
                    break
            if tripped:
                now, base, axis, n = tripped
                priceable = False
                # The zero-baseline rule is "ANY non-zero reading", not a multiple, so quoting the 100x
                # limit on that path named a threshold that was never applied (celo is the live case).
                rule = (f"baseline {base} wei, so any non-zero reading is a regime change"
                        if base == 0 else
                        f"baseline {base} wei, limit {L1_REGIME_MAX_RISE}x")
                l1_note = (f"L1 fee conditions have moved outside the regime the margin table was measured "
                           f"under, seen on the {axis} probe ({n}-byte probe {now} wei vs {rule}, "
                           f"at block {probe_block}), so the omitted L1 fee can no longer be assumed "
                           f"immaterial here — see #287")
        except KeyError:
            # CONFIG error, not a network one, and it must not read as a retryable blip. Widening the
            # predicate above (so a missing baseline could no longer skip the probe) routed this case into
            # the same handler as an RPC failure, which would have told an operator to retry a bad edit
            # forever. The import-time check should catch it first; this is the backstop that names it.
            priceable = False
            l1_note = (f"CONFIG ERROR, not a transient one: chain {chain_id} is in L1_FEE_OMITTED_PRICED "
                       f"but is missing a L1_REGIME_BASELINE_WEI / L1_REGIME_BASELINE_SMALL_WEI entry, so its fee "
                       f"regime cannot be verified. "
                       f"Retrying will not help — add a baseline or remove the chain. See #287")
        except ValueError as e:
            # NOT retryable, and it used to be reported as if it were. `int(x, 16)` raises ValueError
            # when the oracle returns something that is not a hex number — most importantly EMPTY `0x`
            # returndata, which is what a `staticcall` to a chain WITHOUT the OP GasPriceOracle
            # predeploy yields (no revert, no data). That is a permanent property of the chain, so
            # "this may be transient, so retry" sent an operator into a loop that can never clear. It
            # is the same shape as the KeyError case above: a config error wearing a network error's
            # clothes. Distinguished here rather than by inspecting the returndata, because every
            # decode failure of this reading is permanent for the same reason.
            priceable = False
            l1_note = (f"the L1 fee oracle at {OP_GAS_ORACLE} did not return a readable number "
                       f"({type(e).__name__}: {e}); empty `0x` returndata means the OP GasPriceOracle "
                       f"predeploy is absent. RETRYING WILL NOT HELP. Do NOT simply drop the chain from "
                       f"L1_FEE_OMITTED_PRICED — that leaves it in NEITHER collection, which is the "
                       f"unguarded state hemi was in (no regime probe, no headroom floor, and a "
                       f"shortfall printed as if complete). Either move it to L1_FEE_UNMODELLED, or "
                       f"establish that it charges no such fee and record that. See #287")
        except Exception as e:  # noqa: BLE001
            priceable = False
            l1_note = (f"could not verify L1 fee conditions against the measured baseline "
                       f"({type(e).__name__}), and an unverifiable regime is not a pass — this may be "
                       f"transient, so retry before treating it as a config problem — see #287")
    # THE ENUMERATION CHECKS ITSELF NOW, because hand-maintaining it kept losing chains. Both L1
    # collections are hand-built, and every review round of this branch found another chain that should
    # have been in one of them — hemi most seriously (omitted fee 1.96x its whole `need`, printing a
    # clean OK), and hemi was only ever noticed because it happened to have a WORKAROUNDS entry. A list
    # that is correct only when someone remembers to edit it is a documentary guard, and this file's
    # rule is that guards are structural.
    #
    # So: any chain in NEITHER collection is asked, on-chain, whether it actually charges the fee this
    # script does not model. A non-zero `getL1Fee` over the real payload size means the enumeration
    # missed it, and the row fails closed naming itself rather than waiting for the next reviewer.
    #
    # SCOPED TO WHAT IT CAN ACTUALLY DETECT, and the limits are measured, not assumed:
    #   * A missing predeploy makes the node answer with empty `0x`, read as "no OP-stack fee". Correct
    #     for arbitrum (42161, verified codesize 0): Nitro charges its L1 component by INFLATING GAS
    #     UNITS rather than adding a separate term, so `gas x price` already contains it.
    #   * A present-but-zero oracle is a genuine "no fee" — xlayer (196) has the predeploy (2,059 bytes)
    #     and returns 0 for the 64,887-byte payload, exactly like celo. Neither is failed closed.
    #   * It CANNOT see a non-OP-stack DA surcharge on a chain with no such predeploy.
    #
    # ABSENCE OF EVIDENCE IS NOT EVIDENCE OF ABSENCE. The first version wrapped the whole probe in
    # `except Exception: pass`, so "the node answered and there is no predeploy" and "the node did not
    # answer" both left the row priced. For a chain in L1_FEE_UNVERIFIED — which by definition has NO
    # prior measurement — that is a fail-open on the deploy path: no reading, no prior evidence, and a
    # green row anyway. It does not fail loudly in a rehearsal; it prints OK and an operator funds a
    # deployer that is not sized.
    #
    # The three outcomes ARE distinguishable here, which is what makes this a fix rather than a
    # recorded limitation:
    #   * `c.rpc` RETURNS "0x"    -> the node answered; no predeploy; no OP-stack fee. EVIDENCE.
    #   * `c.rpc` raises RpcError -> transport or JSON-RPC failure after retries (chainlib retries 4x
    #                                and then raises). The node did not answer. NOT evidence.
    #   * a parseable non-zero    -> the chain charges a fee this script does not model.
    # Decided on the RETURNDATA rather than by narrowing the exception, because `int(x, 16)` also
    # raises ValueError on a GARBAGE answer, and garbage is a node answering badly — ambiguous, not an
    # absent predeploy. Only the literal empty word is read as absence.
    if priceable and chain_id not in L1_FEE_OMITTED_PRICED and chain_id not in L1_FEE_UNMODELLED:
        n = L1_REGIME_PROBE_BYTES_BIG
        raw, probe_failed = None, None
        try:
            raw = c.rpc(url, "eth_call", [{"to": OP_GAS_ORACLE,
                                           "data": OP_GET_L1_FEE + f"{32:064x}" + f"{n:064x}"
                                           + _probe_payload(n)}, "latest"])
        except Exception as e:  # noqa: BLE001
            probe_failed = f"{type(e).__name__}: {str(e)[:120]}"
        # FAIL CLOSED BY CONSTRUCTION, NOT BY ENUMERATION. The previous version listed the outcomes it
        # expected — `0x`, an RpcError, a parseable word — and anything else fell through BOTH branches
        # leaving the row priced. There was a fourth outcome: `c.rpc` returns `body["result"]` verbatim,
        # so a node answering `{"result": null}` (no `error` key, so no RpcError) makes `raw` None, and
        # a chain in L1_FEE_UNVERIFIED then printed a clean OK backed by nothing. Reproduced on chain 56.
        #
        # So the question is no longer "which known failure is this?" but "did I positively obtain a
        # reading?". Anything that is not a recognised answer becomes `probe_failed`, which the branch
        # below turns into UNPRICEABLE for an unverified chain. A new unexpected shape now fails closed
        # on its own, without anyone having predicted it.
        found = None
        if probe_failed is None:
            if not isinstance(raw, str):
                # `None` (result: null), or any non-string JSON value. Not an answer.
                probe_failed = f"oracle returned a non-string result ({type(raw).__name__}: {raw!r:.40})"
            elif raw.strip().lower() in ("0x", ""):
                # The node ANSWERED with an empty word: no predeploy, no OP-stack fee. Evidence.
                pass
            else:
                try:
                    found = int(raw, 16)
                except ValueError:
                    probe_failed = f"oracle returned unparseable data ({raw[:32]!r})"
        if found:
            priceable = False
            l1_note = (f"UNCLASSIFIED L1 FEE: this chain is in neither L1_FEE_OMITTED_PRICED nor "
                       f"L1_FEE_UNMODELLED, but its OP GasPriceOracle charges {found} wei "
                       f"({found / 1e18:.3e} native) for a {n}-byte payload — a term this script "
                       f"does not model, so its estimate is a LOWER BOUND. Classify it: priced with "
                       f"a measured baseline, or failed closed like scroll and hemi. See #287")
        elif probe_failed and chain_id in L1_FEE_UNVERIFIED:
            # No prior measurement (that is what UNVERIFIED means) and no reading now. Zero evidence.
            # An unreachable chain is UNKNOWN, and unknown must not render as a pass.
            priceable = False
            l1_note = (f"L1 fee status UNKNOWN and unverifiable right now: chain {chain_id} is in "
                       f"L1_FEE_UNVERIFIED (no prior measurement) and the discovery probe could not "
                       f"complete ({probe_failed}). An unreachable chain is not a fee-free chain — "
                       f"retry with a working endpoint, then record the reading in "
                       f"L1_FEE_NONE_VERIFIED or classify it. See #287")
        # A probe failure on an L1_FEE_NONE_VERIFIED chain is deliberately NOT fatal: those chains were
        # already MEASURED fee-free, so this probe is drift-detection there rather than the only
        # evidence, and a blip must not stall a 24-chain deploy. That asymmetry is the whole reason the
        # two sets are separate.
    if priceable and chain_id in L1_FEE_OMITTED_PRICED and bal - need < L1_OMITTED_MIN_HEADROOM_WEI:
        priceable = False
        l1_note = (f"headroom (balance - need) has fallen below {L1_OMITTED_MIN_HEADROOM_WEI / 1e18:g} "
                   f"native, so the L1 data-availability fee this script omits can no longer be assumed "
                   f"immaterial here — the 2026-08-12 measurement no longer covers this row; see #287")
    # NOT gated on `priceable`, deliberately. This fail-closed is unconditional, so gating it meant a
    # scroll/hemi row whose QUOTE also fell below the implausibility floor lost `priceable` earlier,
    # skipped this branch, left `l1_note` unset, and printed the generic "node quotes N wei" message —
    # attributing the failure to the gas price. That points the operator at raising `--with-gas-price`,
    # which is precisely the remedy the runbook forbids for these chains: their problem is a fee this
    # script does not model at all, and no price flag touches it. The reason a row is unpriceable has to
    # survive a second, unrelated reason appearing first.
    if chain_id in L1_FEE_UNMODELLED:
        priceable = False
        l1_note = ("its cost is dominated by an L1 data-availability fee this script does not model, so "
                   "an execution-only figure is a LOWER BOUND, not an estimate — see issue #287")

    row.update(quotedGasPriceWei=quoted, priceSource=price_source, l1Note=l1_note, priceNote=price_note,
               gasNote=gas_note,
               balanceWei=bal, gasPriceWei=price, needWei=need,
               balanceEth=bal / 1e18, needEth=need / 1e18,
               shortfallEth=max(0.0, (need - bal) / 1e18),
               priceable=priceable,
               # `sufficient` is a THIRD state, not a boolean. On an unpriceable chain `need`
               # computes to ~0 from an unusable quote, so `bal >= need` is true for every possible
               # balance — the test is a tautology and its `True` carries no information. Reporting
               # that as OK is the same defect as a checker that returns 0 without checking, so it
               # reports None and the chain is listed separately. Nobody should later read a green
               # row here as evidence the chain was funded.
               # `need` omits the L1 data-availability fee on any chain that charges one, so a
               # shortfall derived from it is a LOWER BOUND, not the amount to send. Carried as a flag
               # rather than inferred at print time, so the JSON consumers see it too.
               #
               # THE TOP-UP WARNING IS UNREACHABLE FOR THE TWO ORIGINAL SETS AND LIVE FOR THE THIRD.
               # Stated per-set, because an earlier version of this comment said flatly that the warning
               # "never renders" and "is dead" — and the very next clause below made it reachable. A
               # blanket claim about a flag whose key had just been widened, twelve lines above the
               # widening.
               #
               # Unreachable for L1_FEE_OMITTED_PRICED and L1_FEE_UNMODELLED: a row reaches TOP UP only
               # when `sufficient is False`, which needs `priceable`, and every member of those two
               # loses `priceable` first — L1_FEE_UNMODELLED unconditionally, L1_FEE_OMITTED_PRICED via
               # the L1_OMITTED_MIN_HEADROOM_WEI floor, which fires whenever `bal - need` drops under
               # 1e-3 native, and a row that is actually short has `bal - need < 0`.
               #
               # LIVE for L1_FEE_UNVERIFIED: those chains price normally, get no headroom floor, and can
               # therefore reach TOP UP while their fee status is unknown — which is exactly when a
               # shortfall figure is a LOWER BOUND and the operator must be told so. That is the hemi
               # shape, minus the reclassification that removed hemi from it.
               # KEYED ON EVERY SET WHERE THE TERM MAY BE PRESENT, not just the two original ones.
               # L1_FEE_UNVERIFIED means nobody has established this chain charges no fee, so a
               # shortfall for it is a LOWER BOUND on exactly the same grounds — and it is reachable
               # there, unlike the two old sets, because an UNVERIFIED chain that prices and comes up
               # short does reach TOP UP. Omitting it printed a bare `send >= X` with no warning for
               # precisely the chains the module itself records as unmeasured.
               # L1_FEE_NONE_VERIFIED is excluded deliberately: those were MEASURED fee-free, so
               # their shortfall is complete and labelling it would cry wolf.
               shortfallExcludesL1=(chain_id in L1_FEE_OMITTED_PRICED
                                    or chain_id in L1_FEE_UNMODELLED
                                    or chain_id in L1_FEE_UNVERIFIED),
               sufficient=(bal >= need) if priceable else None)
    return row


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("chains", nargs="*", type=int)
    ap.add_argument("--gas-units", help="JSON {chainId: {total: <gas>}} from the fork rehearsal")
    ap.add_argument("--json", help="write the full report here")
    args = ap.parse_args()
    c.load_env()

    gas_units = json.load(open(args.gas_units)) if args.gas_units else {}
    chains, scope_src = c.resolve_chains(args.chains)
    print(f"scope: {len(chains)} chain(s) from {scope_src}")
    with ThreadPoolExecutor(max_workers=6) as pool:
        rows = list(pool.map(lambda cid: one(cid, gas_units), chains))
    rows.sort(key=lambda r: r["chainId"])

    print(f"{'chain':>8} {'name':16} {'native':>12} {'need':>12} {'shortfall':>11}  status")
    topup, unpriceable, errored = [], [], []
    for r in rows:
        if r.get("error"):
            errored.append(r)
            print(f"{r['chainId']:>8} {r['name']:16} {'—':>12} {'—':>12} {'—':>11}  "
                  f"RPC ERROR: {r['error'][:70]}")
            continue
        sym = c.chain_config(r["chainId"]).get("nativeTokenSymbol", "")
        if r["sufficient"] is None:
            if r.get("l1Note"):
                status = f"UNPRICEABLE — {r['l1Note']}, so this is NOT a pass"
            elif r.get("priceNote"):
                # A stale PIN, not an unusable quote — the generic message below would name the wrong
                # cause and send the reader to the node instead of to GAS_PRICE_OVERRIDE_WEI.
                status = f"UNPRICEABLE — {r['priceNote']}, so this is NOT a pass"
            elif r.get("gasNote"):
                # The gas multiplicand, not the price one — the generic message below talks about the
                # node's quote, which is not what went wrong here.
                status = f"UNPRICEABLE — {r['gasNote']}, so this is NOT a pass"
            else:
                status = (f"UNPRICEABLE — node quotes {r['quotedGasPriceWei']} wei "
                          f"({r['quotedGasPriceWei'] / 1e9:.7f} gwei); the estimate is meaningless "
                          f"here, so this is NOT a pass")
        else:
            status = "OK" if r["sufficient"] else "TOP UP"
            if r["priceSource"] == "override":
                status += (f" [priced from PINNED {r['gasPriceWei']} wei, not the node's "
                           f"{r['quotedGasPriceWei']} — see workarounds]")
            # NO `l1Note` BRANCH HERE. One used to sit in this arm and was unreachable: every assignment
            # of `l1_note` also sets `priceable = False`, which makes `sufficient` None and routes the row
            # to the branch above. Dead code in a gate's output path is worse than absent code — it reads
            # as coverage. If an l1Note is ever wanted on a PRICED row, it needs a note that does not
            # also fail the row closed.
        print(f"{r['chainId']:>8} {r['name']:16} {r['balanceEth']:>12.5f} {r['needEth']:>12.5f} "
              f"{r['shortfallEth']:>11.5f}  {status} ({sym})")
        if r["sufficient"] is None:
            unpriceable.append({"chainId": r["chainId"], "name": r["name"], "nativeSymbol": sym,
                                "gasPriceWei": r["gasPriceWei"],
                                # `priceNote` must be consulted here too, not just in the status line
                                # above: the default tail says the quote was too LOW, which is the exact
                                # opposite of the stale-pin cause (a quote too HIGH for the pin), and
                                # this string is what the `--json` consumers read.
                                # The node quote belongs in the entry too. On an override chain
                                # `gasPriceWei` is the PIN, so without this the one number that
                                # condemned the pin — the quote that overtook it — is absent from the
                                # JSON, and a consumer sees a pin with no evidence against it.
                                "quotedGasPriceWei": r["quotedGasPriceWei"],
                                "priceSource": r["priceSource"],
                                "reason": (r.get("l1Note") or r.get("priceNote") or r.get("gasNote")
                                           or "gas-price quote too low to size from"),
                                "haveEth": round(r["balanceEth"], 6)})
        elif not r["sufficient"]:
            topup.append({"chainId": r["chainId"], "name": r["name"],
                          "shortfallExcludesL1": r["shortfallExcludesL1"],
                          "nativeSymbol": sym, "deployer": r["deployer"],
                          "shortfallEth": round(r["shortfallEth"], 6),
                          "haveEth": round(r["balanceEth"], 6),
                          "needEth": round(r["needEth"], 6)})

    print("\n--- top-up list (NO funds moved by this script) ---")
    if topup:
        for t in topup:
            note = ("  <- LOWER BOUND: excludes this chain's L1 data-availability fee, which `need` "
                    "does not model. SEND MORE. See #287") if t.get("shortfallExcludesL1") else ""
            print(f"  {t['name']:16} send >= {t['shortfallEth']:.5f} {t['nativeSymbol']} "
                  f"to {t['deployer']}{note}")
    else:
        print("  none — every priced chain is funded for the estimated gas")

    if unpriceable:
        print("\n--- NOT PRICED (these chains were not checked, and are not OK) ---")
        for u in unpriceable:
            print(f"  {u['name']:16} holds {u['haveEth']:.5f} {u['nativeSymbol']}; {u['reason']}")

    print("\n--- chain-specific workarounds ---")
    for cid, note in WORKAROUNDS.items():
        print(f"  {cid} {c.chain_config(cid).get('name','?')}: {note}")

    if args.json:
        json.dump({"rows": rows, "topup": topup, "unpriceable": unpriceable},
                  open(args.json, "w"), indent=1)
        print(f"\nwrote {args.json}")

    # Exit non-zero on anything unresolved. An unpriceable or unreachable chain counts: this script
    # exists to answer "is the deployer funded everywhere", and it cannot answer that for a chain it
    # could not price or could not reach.
    if topup or unpriceable or errored:
        print(f"\n{len(topup)} chain(s) short, {len(unpriceable)} unpriceable, "
              f"{len(errored)} unreachable — not clear to deploy.")
        return 1
    print(f"\nAll {len(rows)} chain(s) priced and funded.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
