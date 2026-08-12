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
sizing input, and those rows say so in the output. The estimate does NOT include the L1 data-availability fee that rollups charge on top; on scroll that
fee measured ~99.9% of the total cost, so scroll fails closed rather than being priced. See
L1_FEE_UNMODELLED and issue #287. Read `priceSource` on each row — `need` is not in general "the live
quote times gas".

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
# for any of the eight to flip, the L1 term would have to be 10x-996x the entire current `need`. On the
# tightest row (celo, `need` 5.60 native — and celo measures 0 for every payload at both probe sizes) that
# threshold is ~56 native against ~2.7e-5. The correction consumed 1.8 orders of magnitude of an argument
# built to tolerate three, so no chain's verdict flips and none of the eight needs to fail closed.
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
# Modelling all nine properly is #287.
L1_FEE_UNMODELLED = {534352}

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
# such a chain tells the operator to send TOO LITTLE. That is wrong under either policy (fail all nine
# closed, or pass eight with an expiring omission), so it is fixed here rather than deferred to #287.
#
# The headroom guard below makes it unreachable for these eight today: if `bal < need` then headroom is
# negative, under the floor, so the row is UNPRICEABLE before any TOP UP verdict. But UNREACHABLE IS NOT
# CORRECT — it holds only while that guard exists and only for chains listed in one of these two sets. A
# chain that charges an L1 fee and is in NEITHER set is short-reportable today with an understated figure.
# So the row now carries `shortfallExcludesL1`, and the top-up line says LOWER BOUND / SEND MORE rather
# than relying on a guard elsewhere to keep the wrong number off the screen.
L1_FEE_OMITTED_PRICED = {10, 130, 204, 480, 5000, 8453, 42220, 57073}
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
_both = L1_FEE_OMITTED_PRICED & L1_FEE_UNMODELLED
if _missing_baseline or _dead_baseline or _both:
    raise ValueError(
        "L1 fee collections are inconsistent — fix before running a deploy gate. "
        f"priced-with-omission but no regime baseline (probe would fail closed): {sorted(_missing_baseline)}; "
        f"baseline with no chain to apply it to (dead entry): {sorted(_dead_baseline)}; "
        f"both priced-with-omission AND failed-closed (contradictory): {sorted(_both)}")

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
    43111: "fee floor: raise --with-gas-price; a naive eth_gasPrice quote is rejected",
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


def gas_estimate(s: dict, override: dict | None) -> int:
    if override:
        return int(override.get("total", 0))
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
        # THE TWO MARGINS ARE ASYMMETRIC, and only one of them is comfortable:
        #   gnosis (100)  — quote 95 wei against a 2 gwei pin (measured 2026-08-12), i.e. the pin is ~2e7x
        #     the quote. This cannot trip without a genuine regime change, and if it trips the pin IS
        #     stale, because gnosis's quote is an honest lower bound (baseFee + suggested tip).
        #   plasma (9745) — quote 8_000_318 wei against a 10_000_000 wei pin: only 1.25x. A modest change
        #     in the node's padding trips this. Such a trip is a FALSE alarm about plasma's real cost
        #     (trivial, ~0.00028 XPL) but it is a fail-CLOSED one: it asks for a remeasurement instead of
        #     quietly sizing from a constant that no longer covers the quote.
        # The plausibility gate matters for gnosis specifically: its quote sits far BELOW
        # GAS_PRICE_IMPLAUSIBLE_WEI, and an unusable quote is not evidence about the pin either way.
        if quoted >= GAS_PRICE_IMPLAUSIBLE_WEI and quoted > override:
            priceable = False
            price_note = (f"the pinned gas price ({override} wei) is BELOW the node's plausible quote "
                          f"({quoted} wei), so the pin no longer bounds the price and sizing from it "
                          f"would UNDER-estimate — remeasure and re-pin GAS_PRICE_OVERRIDE_WEI[{chain_id}] "
                          f"rather than adopting either number")
    else:
        price, price_source = quoted, "node"
        priceable = quoted >= GAS_PRICE_IMPLAUSIBLE_WEI
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
                l1_note = (f"L1 fee conditions have moved outside the regime the margin table was measured "
                           f"under, seen on the {axis} probe ({n}-byte probe {now} wei vs baseline {base} wei, "
                           f"limit {L1_REGIME_MAX_RISE}x at block {probe_block}), so the omitted L1 fee can no longer be assumed "
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
        except Exception as e:  # noqa: BLE001
            priceable = False
            l1_note = (f"could not verify L1 fee conditions against the measured baseline "
                       f"({type(e).__name__}), and an unverifiable regime is not a pass — this may be "
                       f"transient, so retry before treating it as a config problem — see #287")
    if priceable and chain_id in L1_FEE_OMITTED_PRICED and bal - need < L1_OMITTED_MIN_HEADROOM_WEI:
        priceable = False
        l1_note = (f"headroom (balance - need) has fallen below {L1_OMITTED_MIN_HEADROOM_WEI / 1e18:g} "
                   f"native, so the L1 data-availability fee this script omits can no longer be assumed "
                   f"immaterial here — the 2026-08-12 measurement no longer covers this row; see #287")
    if priceable and chain_id in L1_FEE_UNMODELLED:
        priceable = False
        l1_note = ("its cost is dominated by an L1 data-availability fee this script does not model, so "
                   "an execution-only figure is a LOWER BOUND, not an estimate — see issue #287")

    row.update(quotedGasPriceWei=quoted, priceSource=price_source, l1Note=l1_note, priceNote=price_note,
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
               shortfallExcludesL1=chain_id in L1_FEE_OMITTED_PRICED or chain_id in L1_FEE_UNMODELLED,
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
            else:
                status = (f"UNPRICEABLE — node quotes {r['quotedGasPriceWei']} wei "
                          f"({r['quotedGasPriceWei'] / 1e9:.7f} gwei); the estimate is meaningless "
                          f"here, so this is NOT a pass")
        else:
            status = "OK" if r["sufficient"] else "TOP UP"
            if r["priceSource"] == "override":
                status += (f" [priced from PINNED {r['gasPriceWei']} wei, not the node's "
                           f"{r['quotedGasPriceWei']} — see workarounds]")
            if r["l1Note"]:
                status += f" [{r['l1Note']}]"
        print(f"{r['chainId']:>8} {r['name']:16} {r['balanceEth']:>12.5f} {r['needEth']:>12.5f} "
              f"{r['shortfallEth']:>11.5f}  {status} ({sym})")
        if r["sufficient"] is None:
            unpriceable.append({"chainId": r["chainId"], "name": r["name"], "nativeSymbol": sym,
                                "gasPriceWei": r["gasPriceWei"],
                                # `priceNote` must be consulted here too, not just in the status line
                                # above: the default tail says the quote was too LOW, which is the exact
                                # opposite of the stale-pin cause (a quote too HIGH for the pin), and
                                # this string is what the `--json` consumers read.
                                "reason": (r.get("l1Note") or r.get("priceNote")
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
