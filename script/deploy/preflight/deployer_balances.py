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
# 50_000 wei (0.00005 gwei) is a MEASURED boundary, not a guess, chosen to separate three mechanisms that
# all present as "quote too low" but need different handling:
#
#   * gnosis (100)  — baseFee 43-64 wei over 20 blocks, blocks 6.7-98.1% full: EIP-1559 legitimately
#     decaying to its floor. The quote is honest (baseFee + a ~31 wei suggested tip) but it is the
#     MINIMUM price, not the INCLUSION price — the median landed tx paid 1_000_000_048 wei and the
#     20-block tip p90 reached 9.8 gwei. Tip-driven, so unpriceable from the node; pinned below.
#   * scroll (534352) — baseFee EXACTLY 120_008 wei across -0/-5k/-50k/-200k/-1_000_000 blocks, tips a
#     flat 100 wei. A hard enforced floor, not a decayed value: the quote is CORRECT and is what
#     transactions pay. It still does not pass — L1_FEE_UNMODELLED fails it closed (#287).
#   * plasma (9745) — the opposite failure, and why a bare threshold is not enough. baseFee is 8 wei but
#     the node PADS eth_gasPrice with a large suggested tip: quote 8_000_318 wei against a MEDIAN LANDED
#     price of 9 wei. Neither value reflects what txs pay, so plasma is pinned rather than left to this
#     threshold, whose verdict on it would flip with whichever number the node returns.
#
# NOT raised to cover gnosis: a 1 gwei floor was measured reporting TOP UP on 11 of 24 amply-funded
# chains, and a false alarm on 11 chains is its own failure. Genuinely cheap chains must stay priceable;
# a chain whose real price is known is pinned instead. That 11-of-24 measurement is what holds this value
# now — scroll, which the 20x lowering was originally argued from, is failed closed regardless.
GAS_PRICE_IMPLAUSIBLE_WEI = 50_000  # 0.00005 gwei

# Per-chain gas price, in wei, used INSTEAD of the node's `eth_gasPrice`. For chains where the node's
# quote is not a usable sizing input in either direction. Each entry must carry its measurement.
#
# These make the chain priceable from a pinned constant rather than from the node, so `priceSource` is
# reported as "override" and a pass here is never evidence the node was trusted. Over-estimating is
# the safe direction for a funding check; under-estimating is not.
GAS_PRICE_OVERRIDE_WEI = {
# gnosis: observed median landed price 1 gwei (baseFee ~48 + a 1 gwei client-default tip), 20-block tip
# p90 9.8 gwei. 2 gwei = median + 100% margin. NOT derived from a test send.
#
# THIS PIN SITS BELOW THE p90 IT WAS MEASURED AGAINST, which qualifies the "over-estimating is the safe
# direction" rule above: even with FEE_VOLATILITY_HEADROOM the effective 4 gwei is 2.45x under the p90,
# so a deploy landing in such a window costs more than `need` says. The margin absorbs it today (gnosis
# holds ~53x its `need`) — a fact about today's balance, not a property of the pin. Sizing from a tip
# percentile is the real fix and needs sampling this script does not do; re-derive by hand if gnosis
# fees are elevated.
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

# The two collections below and L1_FEE_OMITTED_PRICED define a deploy-gate invariant between them, and
# all three are hand-maintained. Divergence is checked at IMPORT so a bad edit fails immediately with a
# named cause. Not an `assert`: `python -O` strips those, and this guards a deploy gate.
#
# Chains whose cost includes an additive L1 data-availability fee that this script does NOT model. On a
# rollup that fee is charged on top of (gas x gasPrice) and is not a rounding error, so an execution-only
# figure is a LOWER BOUND, not an estimate. Modelling all TEN is #287 — the eight priced-with-omission
# chains plus scroll and hemi. (#287's own text still says nine and should be widened.)
#
# TWO CHAINS FAIL CLOSED HERE, both because the omitted term DOMINATES rather than rounds:
#   scroll (534352) — ~99.9% of total cost. Its quote is usable, which is exactly why the carve-out is
#     load-bearing: without it scroll would print a confident OK omitting almost all of its cost.
#   hemi (43111)    — measured live 2026-08-12 against the OP GasPriceOracle at 0x420...0F (present,
#     2,059 bytes): getL1Fee over the 64,887-byte payload is 5.485e-5 ETH against a whole `need` of
#     2.801e-5 ETH, i.e. 1.96x the entire estimate and ~2/3 of real cost. Scroll's category, not the
#     eight's. No baseline measured under a regime this far from the others would make it priceable.
#
# THE EIGHT ARE DELIBERATELY NOT LISTED, and that decision was MEASURED. Each chain's own getL1Fee was
# summed over the shell payload; the worst case is ~2.7e-5 ETH (mantle). TREAT THAT AS AN ORDER OF
# MAGNITUDE AND NOT A FIGURE TO QUOTE — it is scaled from a measured ratio, not re-measured per
# transaction, and an aggregate call is known to misprice against a sum of parts.
#
# The robustness is what decides it, not the point estimate: for any of the eight to flip, the L1 term
# would have to exceed the entire current `need` by between one and three ORDERS OF MAGNITUDE. THE
# CONCLUSION IS CERTIFIED, NOT THE MARGIN — it holds across three orders of magnitude of error in the
# readings, which is why the imprecision does not weaken it. Full table: REDEPLOY_RUNBOOK.md 0.6.
#
# EXPIRY: that bound covers error in the FEE, not a falling BALANCE, which moves independently. THE
# TRIGGER IS ENFORCED, NOT ADVISORY — see L1_OMITTED_MIN_HEADROOM_WEI below. Do not reintroduce a
# ratio rule ("re-measure below ~10x need"); the absolute floor is the rule, for the reason recorded
# there.
#
# LIMIT: the magnitude of those getL1Fee figures could not be independently certified (base returns
# 8.35e-9 ETH for the payload scroll charges ~1e-3 for, and a hand-check from its scalars did not
# reproduce it). Only the flip conclusion is certified.
L1_FEE_UNMODELLED = {534352, 43111}

# The eight chains that ALSO omit an L1 fee but are allowed to price, and the STRUCTURAL guard that keeps
# that safe. Named explicitly rather than "everything not in L1_FEE_UNMODELLED", because the guard below
# iterates them.
#
# SCOPE — THIS GUARD IS BALANCE-ONLY. It watches `balance - need`, and `need` EXCLUDES the L1 fee, so it
# reads neither l1BaseFee nor blobBaseFee. The FEE axis is covered separately by the regime probe below,
# which does read each chain's oracle and fails closed on a large rise. Both axes are enforced, by two
# different checks. What #287 still owns is FULL FEE PRICING: adding the L1 term to `need`.
#
# WHY AN ABSOLUTE FLOOR AND NOT A RATIO. A ratio ignores the measured SIZE of the omitted term: celo sits
# at 9.95x need with ~50 CELO of headroom against a measured L1 addition of ~0, so a "10x need" rule
# would fail it closed for nothing. The floor is derived from that size instead — 1e-3 native is ~38x the
# largest addition across the eight (mantle, ~2.7e-5). If a balance falls so headroom drops under it, the
# row goes UNPRICEABLE by itself.
#
# THE UNDER-COMPUTED TOP-UP GAP is why the flag exists as well as the floor. `shortfallEth` is
# `need - bal` and `need` omits the L1 fee, so a shortfall printed for such a chain tells the operator to
# send TOO LITTLE. The floor makes that unreachable for these eight today, but UNREACHABLE IS NOT
# CORRECT — it holds only while the floor exists and only for listed chains. The row carries
# `shortfallExcludesL1` so the top-up line says LOWER BOUND / SEND MORE on its own.
L1_FEE_OMITTED_PRICED = {10, 130, 204, 480, 5000, 8453, 42220, 57073}

# THE PARTITION IS TOTAL: silence is not an answer. The two sets above answer "does this chain charge an
# unmodelled L1 fee?" only for chains someone remembered to classify, and an unclassified chain defaulted
# to "no" — which is how hemi printed a clean OK at ~1/3 of real cost. The remaining chains are therefore
# classified explicitly below, and a test asserts the four sets cover the deploy scope with no overlaps.
#
# The two differ in kind and must not be collapsed: one records a MEASUREMENT, the other the ABSENCE of
# one.
#
# Measured to charge no such fee — each verified on-chain 2026-08-12, not inferred from rollup family:
#   42161 arbitrum — no predeploy (codesize 0). Nitro charges its L1 component by INFLATING GAS UNITS,
#                    so `gas x price` already contains it: a different fee model, not an absent fee.
#   196   xlayer   — HAS the predeploy (codesize 2,059) and returns 0 for the 64,887-byte payload, like
#                    celo. Present-but-zero is a real answer, and a different one from absent-oracle.
#   1     mainnet  — no predeploy. It IS the L1; there is no DA fee to post.
#   100   gnosis   — no predeploy. Standalone L1, not a rollup.
#   143   monad, 16661 0g — no predeploy (codesize 0).
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

# FEE-SIDE CHECK. The headroom guard above covers a falling BALANCE; this covers a rising FEE.
#
# It is a REGIME PROBE, NOT A FEE MODEL: `getL1Fee` on fixed reference payloads, compared against
# baselines measured 2026-08-12 (the date matters — the baselines are payload-specific, see
# _probe_payload). It answers only "are fee conditions still the ones the margin table was measured
# under?" and never prices. Modelling the fee is #287.
#
# TWO PROBE SIZES, because one alone cannot separate a base-fee move from a curve move:
#   BIG (64,887 bytes)   — the region the real deploy payload occupies. Primary signal.
#   SMALL (4,096 bytes)  — the second point on the curve.
# Either exceeding L1_REGIME_MAX_RISE trips the fail-closed. The measured big/small ratio is 15.7787x on
# every chain that charges, identical to four decimals across all seven — evidence that the fee is linear
# in compressed size with a per-chain scalar. A change in that RATIO is a curve change even if both
# readings stay under the limit individually. celo returns 0 for both, i.e. no such fee, and a baseline
# of 0 is handled as "any non-zero reading is a regime change".
#
# One probe pair captures both fee inputs and both scalars at once, which is why this is used instead of
# reading l1BaseFee/blobBaseFee separately. It also avoids a selector trap: OP-stack exposes
# `blobBaseFee()` 0xf8206140 while scroll exposes `l1BlobBaseFee()` 0x84189161 — reusing scroll's
# selector on an OP chain reverts.
#
# THRESHOLD — THE ADEQUACY CLAIM FOR 100x IS RETRACTED, AND NO REPLACEMENT NUMBER IS OFFERED.
# THE GAP, stated for whoever deploys this: headroom is ~38x the largest addition (mantle ~2.7e-5 native
# against a 1e-3 floor) and this probe does not trip until 100x, so there is a window — roughly 38x to
# 100x — in which a row near the floor can have its headroom consumed while the probe stays quiet and the
# row still prints OK. On that row, OK does not mean funded. Every chain sits far above the floor today,
# which is a fact about today's balances, not a property of this guard.
# WHY NO NEW NUMBER: two earlier revisions asserted adequacy and both were wrong about the margin. The
# defect is a method that produces confident numbers from an argument that cannot see its own gap, so a
# third number derived the same way would carry the same defect. 100x stands as a documented tripwire of
# UNJUSTIFIED width, not a bound to rely on. What it IS credited with: it only ever TRIPS a fail-closed
# and never prices, so it cannot make a row pass that would otherwise fail. Sizing the term is #287.
#
# FEE MODE IS NOT VALIDATED, measured 2026-08-11 against 0x420...0F:
#   10, 130, 480, 8453, 42220, 57073 -> isEcotone=1 isFjord=1 isIsthmus=1
#   204 opbnb                        -> isEcotone=1 isFjord=1 isIsthmus REVERTS (older oracle)
#   5000 mantle                      -> ALL THREE REVERT, yet getL1Fee works — so mantle is not a
#                                       standard OP-stack oracle, which qualifies "membership is by
#                                       rollup family, not measured".
# A naive mode check would have to treat a revert as "mode unknown" and fail mantle and opbnb closed on
# interface discovery. Not done here; #287 owns it, with this table so it is not rediscovered. The
# two-point probe already covers the concrete risk: a mode change that alters the fee shows up at one or
# both sizes.
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

# THE PROBE PAYLOAD MUST BE INCOMPRESSIBLE, and the reason is measured. Post-Fjord `getL1Fee` prices the
# FASTLZ-COMPRESSED size of the payload, not its raw length, and `isFjord()` is 1 on seven of these eight
# chains (mantle reverts every mode getter yet behaves identically here). A compressible payload
# therefore reads far below what the real deploy pays: measured 2026-08-12 at one pinned block per chain,
# the ratio to this incompressible payload is identical to four significant figures on every chain that
# charges — 35.4684x at 4,096 bytes and 86.9003x at 64,887 bytes against `"ff"`.
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

# Multiplier applied to `gas x gasPrice`, which is the WHOLE of what this script estimates.
#
# IT DOES NOT COVER THE L1 DATA-AVAILABILITY FEE: `need` has no L1 term to multiply. Both the ~38x
# residual sizing at L1_OMITTED_MIN_HEADROOM_WEI and the 38x-to-100x window at L1_REGIME_MAX_RISE weigh
# the omitted fee (~2.7e-5 native) against the absolute headroom floor (1e-3 native), and NEITHER of
# those operands passes through this multiplier. #287 has to ADD the term, not assume it is padded.
FEE_VOLATILITY_HEADROOM = 2

# THE FILE'S OWN RULE, APPLIED TO ITS OWN CONSTANTS. Each of the three below is a multiplicand or floor
# in the verdict path, and setting any to 0 re-creates the tautological pass with NOTHING firing:
#   * FEE_VOLATILITY_HEADROOM = 0    -> `need` is 0 -> `bal >= need` for every balance
#   * GAS_UNITS_IMPLAUSIBLE = 0      -> the gas floor stops rejecting a zero-gas estimate
#   * GAS_PRICE_IMPLAUSIBLE_WEI = 0  -> the price floor stops rejecting a zero quote AND the
#     _bad_overrides check silently becomes vacuous, since every pin is then >= 0
# `raise`, not `assert`: `python -O` strips asserts and CI runs this suite under -O.

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


# THE OTHER MULTIPLICAND. `need` is `gas x price x headroom`; a zero or nonsense `gas` collapses it
# exactly as an implausible price does, and `bal >= need` then holds for ANY balance including zero.
# `--gas-units` takes `{chainId: {"total": <gas>}}`, and a missing `total` reads as 0 — the rehearsal's
# steps.tsv column is named `gas`, so `{"100": {"gas": ...}}` is the natural mis-transcription.
#
# 1_000_000 is chosen against the built-in estimates: every chain deploys at least the shell
# (GAS_SHELL = 14_000_000) and the smallest single contract deploy is ~200k, so a TOTAL under 1M cannot
# be a real deploy. Far below 14M so a legitimately reduced scope is not failed closed.
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
# A bad value degrades to 0, which the GAS_UNITS_IMPLAUSIBLE floor turns into a per-row UNPRICEABLE
# naming the chain, rather than aborting a 24-chain run. The catch is deliberately TOTAL: enumerating
# exception types has the same defect as enumerating probe outcomes — the next unexpected shape is
# unhandled. `{"100": 36730000}` (the flat form) makes `override` an int and raises AttributeError.
# The contract is total: return a gas number, or 0, which cannot certify anything.
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
# A PIN CAN GO STALE, AND STALE IN THE UNSAFE DIRECTION IS SILENT: the override replaces the quote
# unconditionally, so if the real price rises past the pin the row keeps sizing at the pin and prints an
# authoritative OK from an under-estimate. A PLAUSIBLE QUOTE ABOVE THE PIN therefore fails the row closed
# rather than adopting either number. `max(pin, quoted)` is REJECTED: plasma's quote is node-side padding
# (8_000_318 wei against a 9 wei median landed price), so it would size a deploy from a measured-
# meaningless number and reintroduce the node-dependence the pin exists to remove.
#
# WHAT THIS DOES NOT COVER:
#   plasma (9745) — pin only 1.25x above the quote, so the padding this guard watches is what moves. A
#     trip is a false alarm about plasma's real cost but a fail-CLOSED one.
#   gnosis (100)  — STRUCTURALLY BLIND to how this pin actually goes stale. The 2 gwei pin came from the
#     observed TIP, but `eth_gasPrice` returns baseFee + a ~31 wei suggestion and does not track it
#     (95 wei against a 2e9 pin). The inclusion price can pass 2 gwei with the quote barely moving and
#     this guard will not fire. Detecting that needs tip sampling, which this script does not do.
#
# No plausibility term is needed: the import-time `_bad_overrides` check forces every pin >= the floor,
# so `quoted > override` already implies `quoted >= GAS_PRICE_IMPLAUSIBLE_WEI`. If that invariant is ever
# relaxed, restore one here.
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
# THE LABELS NAME WHICH PROBE TRIPPED, NOT WHAT CAUSED IT. BIG is checked first and the loop BREAKS on
# the first trip, so the small label is only ever reached when big did NOT trip and small did — the
# readings moving APART, i.e. a RATIO change, which is a curve move. A pure base-fee move scales both
# and trips big first. Diagnosing the cause needs both readings and the 15.7787x ratio; the guard only
# establishes that the regime no longer matches, and leaves diagnosis to #287.
            pairs = ((L1_REGIME_PROBE_BYTES_BIG, L1_REGIME_BASELINE_WEI[chain_id], "big-payload"),
                     (L1_REGIME_PROBE_BYTES_SMALL, L1_REGIME_BASELINE_SMALL_WEI[chain_id], "small-payload"))
# BOTH PROBES PIN TO ONE BLOCK. With `latest` per call the two readings can land on different blocks, so
# a fee change between them produces a hybrid snapshot and hides the size-dependent move this exists to
# catch.
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
        # G1: THE TWO NARROW HANDLERS BELOW ARE SAFE ONLY BECAUSE THE TOTAL ONE CLOSES THIS SAME `try`.
        # `except Exception` at the end catches anything that is neither KeyError nor ValueError, and it
        # fails the row closed — so narrowing here cannot leak an unhandled shape past the guard. Remove
        # or narrow that last handler and these two become a fail-open.
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
# NOT retryable. `int(x, 16)` raises ValueError on empty `0x` returndata — a chain with no OP
# GasPriceOracle predeploy — which is a permanent property, so "retry" would loop forever. Do NOT
# resolve it by dropping the chain from L1_FEE_OMITTED_PRICED: that leaves it in NEITHER collection,
# the unguarded state hemi was in. Move it to L1_FEE_UNMODELLED, or establish it charges no such fee.
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
# THE ENUMERATION CHECKS ITSELF. Both L1 collections are hand-maintained, and a list that is correct only
# when someone remembers to edit it is a documentary guard; this file's rule is that guards are
# structural. So any chain in NEITHER collection is asked, on-chain, whether it actually charges the fee
# this script does not model, and a non-zero reading fails the row closed naming itself.
#
# SCOPED TO WHAT IT CAN DETECT, measured not assumed:
#   * no predeploy -> the node answers empty `0x`, read as "no OP-stack fee". Correct for arbitrum
#     (42161, codesize 0): Nitro inflates GAS UNITS instead, so `gas x price` already contains it.
#   * present-but-zero is a genuine "no fee" — xlayer (196) has the predeploy and returns 0, like celo.
#   * it CANNOT see a DA surcharge on a chain with no such predeploy.
# A probe failure is not fail-closed here for chains with a prior measurement; see the L1_FEE_UNVERIFIED
# branch below, which is where absence of evidence must not read as evidence of absence.
    if priceable and chain_id not in L1_FEE_OMITTED_PRICED and chain_id not in L1_FEE_UNMODELLED:
        n = L1_REGIME_PROBE_BYTES_BIG
        raw, probe_failed = None, None
        try:
            raw = c.rpc(url, "eth_call", [{"to": OP_GAS_ORACLE,
                                           "data": OP_GET_L1_FEE + f"{32:064x}" + f"{n:064x}"
                                           + _probe_payload(n)}, "latest"])
        except Exception as e:  # noqa: BLE001
            probe_failed = f"{type(e).__name__}: {str(e)[:120]}"
# FAIL CLOSED BY CONSTRUCTION, NOT BY ENUMERATION. The question is not "which known failure is this?"
# but "did I positively obtain a reading?" — anything that is not a recognised answer becomes
# `probe_failed`, which the branch below turns into UNPRICEABLE for an unverified chain. A shape nobody
# predicted therefore fails closed on its own. (`c.rpc` returns `body["result"]` verbatim, so a node
# answering `{"result": null}` yields None with no RpcError; that is not an answer.)
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
                # G2: `ValueError` alone is COMPLETE here only because the `isinstance(raw, str)` check
                # above has already rejected every non-string, so `int()` cannot raise TypeError at this
                # point. Delete that check and this handler stops covering the reachable failures.
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
# NOT gated on `priceable`. This fail-closed is unconditional and DOMINANT, so gating it let a row whose
# quote also fell below the floor skip it and report a NODE-QUOTE cause — pointing the operator at
# `--with-gas-price`, the one remedy the runbook forbids for these chains. A dominant reason must not be
# gated on a flag a subordinate reason can clear first.
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
# `sufficient` is a THIRD state, not a boolean. On an unpriceable chain `need` computes to ~0 from an
# unusable quote, so `bal >= need` is true for every possible balance — a tautology whose `True` carries
# no information. It reports None and the chain is listed separately; a green row here is never evidence
# the chain was funded.
#
# `shortfallEth` is `need - bal`, and `need` OMITS the L1 fee on any chain that charges one, so a
# shortfall printed bare tells the operator to send TOO LITTLE. Carried as `shortfallExcludesL1` rather
# than inferred at print time, so the JSON consumers see it too.
#
# THE TOP-UP WARNING IS UNREACHABLE FOR THE TWO ORIGINAL SETS AND LIVE FOR THE THIRD.
# Unreachable for L1_FEE_OMITTED_PRICED and L1_FEE_UNMODELLED: a row reaches TOP UP only when
# `sufficient is False`, which needs `priceable`, and every member of those two loses `priceable` first —
# L1_FEE_UNMODELLED unconditionally, L1_FEE_OMITTED_PRICED via the L1_OMITTED_MIN_HEADROOM_WEI floor,
# which fires whenever `bal - need` drops under 1e-3 native, and a short row has `bal - need < 0`.
# LIVE for L1_FEE_UNVERIFIED: those chains price normally, get no headroom floor, and can reach TOP UP
# while their fee status is unknown — exactly when a shortfall is a LOWER BOUND and must say so.
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
# NO `l1Note` BRANCH HERE: every assignment of `l1_note` also clears `priceable`, which routes the row
# to the branch above. A note wanted on a PRICED row needs one that does not also fail the row closed.
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
