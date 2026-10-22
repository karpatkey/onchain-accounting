#!/usr/bin/env python3
"""The DECLARED-heartbeat guard: a registered heartbeat must EQUAL the provider's declared heartbeat.

SUPERSEDED RULE, KEPT AS HISTORY. This guard previously required registered > declared and treated
equality as a WARN candidate. ADR 0025 inverted it to strict equality — margin above declared is a
window in which a DEAD feed still reads FRESH, which is the one error this system treats as critical,
and consumers already gate on `stale`, so a false-stale is a loud halt rather than a wrong number. The
measured reasoning for the OLD rule is preserved below because it is still true as far as it goes: zero
margin does make heartbeat-driven feeds go stale each cycle. ADR 0025 accepts that cost knowingly.
See docs/decisions/0025-heartbeat-equals-declared.md.

This is a SECOND, independent axis from `preflight_config.heartbeat_findings`, which checks the
*derived-vs-base* pairing (ADR 0019 / finding #8). Both are heartbeat guards; neither subsumes the other:

  * derived-vs-base  — a NAV-sourced feed must not be gated TIGHTER than the base whose timestamp it inherits.
  * declared-margin  — ANY feed must not be gated at-or-below the timestamp cadence its PROVIDER actually publishes at.

WHY AT-OR-BELOW IS A DEFECT, measured not assumed. A provider's declared heartbeat is a *target*; publication
lands tens of seconds PAST it (block granularity + trigger latency). So a feed registered at EXACTLY the declared
value has zero margin and goes stale at the end of essentially every publish cycle — the asset is listed in
`stalePriceAssets` (since ADR 0029 it keeps its last-known price; before it, the asset was valued $0).
Two independent proofs:

  * USDS/USD declared 82800, sUSDS registered 82800 -> 59/61 intervals overshot (median +24 s). Fixed by PR #211.
  * OETH/ETH declared 86400, registered 86400       -> 29/29 intervals overshot, max gap 86,448. Fixed by PR #236.

THREE STATES, AND THE SEVERITY SPLIT IS THE WHOLE DESIGN. Zero margin only bites HEARTBEAT-DRIVEN feeds; where the
deviation threshold fires long before the heartbeat, the heartbeat never binds and zero margin is harmless. A bare
`registered <= declared` rule ERRORs on every deviation-active feed — 30 of them on the configured chains — which
blocks every deploy on feeds nobody has shown to be broken, and a guard that cries wolf gets bypassed rather than
satisfied. So:

  * MEASURED-FINE      -> silent. An ALLOWLIST entry with 0 breaches and matching `registered`.
  * MEASURED-BREACHING -> not representable: such a feed is FIXED (raise the heartbeat), never exempted. An
                          allowlist entry recording breaches > 0 is itself an ERROR.
  * UNMEASURED         -> **WARN**, naming both exits. At-or-below margin is a CANDIDATE, not a defect.
  * EVIDENCE CONTRADICTION -> **ERROR**. An allowlist entry with breaches > 0, or one measured against a
                          heartbeat the config has since changed (a stale exemption is not evidence).

ERROR is therefore reserved for a broken *exemption*, not for an unmeasured feed. That keeps the gate meaningful:
on a clean tree it is 0 ERRORs, and the WARNs are an auditable to-measure queue rather than noise to be ignored.

THE ALLOWLIST CARRIES ITS EVIDENCE ON PURPOSE. An allowlist whose entries cannot be audited becomes a place to hide
a real defect: in six months nobody will remember that Base COMP was *measured* rather than assumed. Every entry
records the measurement window, interval count, breach count, max gap and the date, so a reviewer can re-run it.

PROVENANCE OF THE SEED SET, stated precisely so nobody over-reads it. The 2026-07-31 audit was exhaustive over the
feeds it TARGETED — every zero-margin reference whose shape suggested it was heartbeat-driven (pegged assets, LST
rates, forex) was measured, and each was either fixed with per-asset evidence (18 feeds, PR #236) or exempted with
per-asset evidence (the 6 entries below). It did NOT measure the remaining ~30 zero-margin refs, which are volatile
assets expected to be deviation-active. Those are UNMEASURED, not cleared, and the guard reports them as WARNs on
purpose — that is the to-measure queue, and an honest one. Do not convert a WARN to an allowlist entry without
actually measuring it.

WHAT THIS AXIS DOES NOT COVER — read this before trusting a silent chain. A `type: Custom` price feed is
gated on TWO independently-registered heartbeats against the SAME provider cadence, and this axis checks at
most one of them:

  * the CONSTRUCTOR heartbeat, `<stem>Heartbeat` in contracts-deployment-config/custom-price-feeds/, applied
    inside the feed (TwoFeedChainlinkPriceFeed: `block.timestamp - effRate >= RATE_HEARTBEAT`). CHECKED here,
    as a `rate leg (...)` row.
  * the NAV-SIDE heartbeat, `priceFeeds[i].heartbeat` on the nav-config entry, applied by
    PriceFeedLib (`block.timestamp - effectiveTime >= cfg.chainlinkHeartbeat` -> the feed is no longer fresh;
    if no primary is fresh the asset is flagged stale and keeps its last usable price, ADR 0029). NOT CHECKED
    here against the declared cadence. (It IS checked against the ADR 0029 7-day cap, by `stale_cap_findings`,
    which scans every primary.) It is gated against the same provider cadence because a custom feed propagates
    its rate leg's timestamp, `min(rate, base)`.

Concretely, the named-custom nav entries across the configured chains split two ways:
  * those with a Chainlink rate leg -> their CONSTRUCTOR heartbeat is checked, their NAV-SIDE heartbeat is NOT.
  * those with no Chainlink rate leg at all (they read an on-chain exchange rate) -> NOT CHECKED on this axis
    at all. (This split was once written here as exact counts. Nothing asserted them, they drifted the
    first time feeds were added, and a stale census reads as a measurement -- so the numbers are gone
    deliberately. Run this module to get the current split.) That set includes sUSDS, and now the four
    Spark/Sky savings feeds, the class whose 59/61-cycle staleness is cited above as this module's
    motivating defect. Reaching it means following `baseAsset` into the NAV-sourced chain, which is the
    derived-vs-base axis's territory (ADR 0019); it is deliberately out of scope here.

The derived-vs-base axis does NOT close that gap either: it asserts `derived >= base` and explicitly treats
LST feeds at 86400 against WETH's 3600 as correct. So no check in this repo compares a NAV-side custom-feed
heartbeat to its provider's declared cadence. Today every named-custom entry happens to register the same
value on both gates, so there are zero live holes — but that lockstep is an undocumented convention, not an
invariant, and nothing enforces it. Silence from this module about a `type: Custom` asset means "not
examined", never "examined and fine".

usage:
  python3 declared_heartbeat_guard.py                # check every chain the CONFIG registers feeds for
  python3 declared_heartbeat_guard.py 1 8453
  python3 declared_heartbeat_guard.py --self-test    # prove the guard, incl. by mutation
  python3 declared_heartbeat_guard.py --refresh      # re-fetch the declared-heartbeat snapshot (needs network)
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent.parent
SNAPSHOT = HERE / "chainlink_declared_heartbeats.json"

ERROR = "ERROR"
WARN = "WARN"

# Mirrors src/constants.sol MAX_STALE_PRICE_AGE (ADR 0029): every finite PRIMARY heartbeat must be below it.
MAX_STALE_PRICE_AGE = 7 * 24 * 3600
# `type(uint256).max` disables the NAV-side heartbeat gate; it is exempt from the cap check.
UINT256_MAX = 2**256 - 1


_UINT_STR = re.compile(r"0[xX][0-9a-fA-F]+|[0-9]+")


def _parse_heartbeat(v):
    """A config heartbeat as the deploy path reads it, or None if it cannot be read.

    Mirrors `ConfigReader.readAssetFeedHeartbeat` + `vm.parseUint`: a JSON integer, or a string of decimal digits
    (leading zeros allowed) or `0x` hex. Rejects booleans, negatives and anything else (`"7d"`, `"86_400"`,
    `" 86400"`, `"0o..."`), so one parser serves every check in this module and none can disagree with another.
    A JSON float is truncated, which is stricter than the deploy path (it would revert) and never hides a breach.
    """
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, int):
        return v if v >= 0 else None
    if isinstance(v, float):
        return int(v) if v >= 0 else None
    if isinstance(v, str) and _UINT_STR.fullmatch(v):
        return int(v, 16) if v[:2].lower() == "0x" else int(v, 10)
    return None

# Refuse to trust a snapshot older than this without saying so. Chainlink can re-tune a feed's heartbeat.
SNAPSHOT_STALE_DAYS = 180

# The same logic applied to the ALLOWLIST's own evidence. An exemption is a measurement, and a
# measurement ages exactly like the snapshot does — publisher behaviour drifts, and a feed that was
# deviation-active two years ago need not be today. Warning on a stale snapshot while treating a
# two-year-old exemption as permanent would be the same blind spot wearing a different hat.
MEASUREMENT_STALE_DAYS = 365

# Chainlink reference-data-directory filenames, per chain id.
DIRECTORY_FILES = {
    "1": "feeds-mainnet.json",
    "10": "feeds-ethereum-mainnet-optimism-1.json",
    "56": "feeds-bsc-mainnet.json",
    "100": "feeds-xdai-mainnet.json",
    "137": "feeds-matic-mainnet.json",
    "8453": "feeds-ethereum-mainnet-base-1.json",
    "42161": "feeds-ethereum-mainnet-arbitrum-1.json",
    "5042": "feeds-arc-mainnet.json",
}
DIRECTORY_BASE = "https://reference-data-directory.vercel.app/"

# ---------------------------------------------------------------------------------------------------
# PROXY ALIASES. Chainlink sometimes publishes a feed in its reference directory under a DIFFERENT proxy
# than the one a config points at, while both proxies wrap the SAME aggregator. The address is then
# absent from the catalogue and `refresh` records no declared value for it — the feed becomes
# unverifiable, which is precisely the blind spot that let POL sit at 90000 against a declared 86400
# through an entire rollout without the guard being able to raise an ERROR.
#
# An alias maps OUR address to the catalogued one so the declared value can still be resolved. It is NOT
# a licence to substitute a convenient feed: each entry records the on-chain evidence that the two
# proxies are the same feed, and that evidence is what a reviewer should re-check before trusting it.
# Verification is `aggregator()`, `decimals()` and `version()` on both proxies — matching prices alone is
# not sufficient, since two independent ETH/USD feeds agree to several decimal places most of the time.
PROXY_ALIASES: dict[tuple[str, str], dict] = {
    ("8453", "0x71041dddad3595f9ced3dccfbe3d1f4b0a16bb70"): {
        "catalogued": "0x50015f8b17fb2c290dde41fdc246ed0dcee93a8b",
        "name": "ETH / USD (Base)",
        "evidence": "Both proxies return aggregator() == 0x05c84a58FE042275b37db038bAAcD15F410c7bB0, "
                    "decimals() == 8, version() == 6; verified 2026-08-28. Our proxy is live and fresh "
                    "(age 176 s at the time of checking) and reports the same answer as the catalogued "
                    "one. Chainlink dropped OUR proxy from feeds-ethereum-mainnet-base-1.json while "
                    "continuing to list the alias, so this is a catalogue-key change, not a delisting.",
        "used_by": "ETH and WETH on chain 8453",
    },
}

# ---------------------------------------------------------------------------------------------------
# THE ALLOWLIST. A feed here is exempt from the margin rule because it was MEASURED to be
# deviation-active: its publish cadence sits far below its heartbeat, so the heartbeat never binds.
#
# TO ADD AN ENTRY YOU MUST MEASURE IT. Fetch the aggregator's `AnswerUpdated` events over >= 14 days,
# compute the inter-update gaps, and record: intervals, breaches (gaps >= registered heartbeat), the max
# gap, and the date. `breaches` MUST be 0 — a feed with any breach is a defect to fix, not to exempt.
# ---------------------------------------------------------------------------------------------------
ALLOWLIST: dict[tuple[str, str], dict] = {
    ("100", "0x22441d81416430a54336ab28765abd31a792ad37"): {
        "asset": "GNO", "name": "GNO / USD", "registered": 86400,
        "intervals": 431, "breaches": 0, "max_gap_s": 37690, "median_gap_s": 1170,
        "window_days": 17.8, "measured": "2026-07-31",
        "note": "Volatile asset; deviation fires ~every 20 min, so the 24 h heartbeat never binds.",
    },
    ("100", "0xa767f745331d267c7751297d982b050c93985627"): {
        "asset": "WETH", "name": "ETH / USD", "registered": 86400,
        "intervals": 287, "breaches": 0, "max_gap_s": 82175, "median_gap_s": 2530,
        "window_days": 17.9, "measured": "2026-07-31",
        "note": ("Deviation-active. NOTE: max gap is 95% of the heartbeat — the TIGHTEST margin of any "
                 "non-breaching feed measured. Re-measure this one FIRST if Gnosis publisher behaviour changes."),
    },
    ("8453", "0xe95e258bb6615d47515fc849f8542da651f12bf6"): {
        "asset": "MORPHO", "name": "MORPHO / USD", "registered": 86400,
        "intervals": 989, "breaches": 0, "max_gap_s": 24104, "median_gap_s": 960,
        "window_days": 21.0, "measured": "2026-07-31",
        "note": "Volatile asset; deviation fires ~every 16 min.",
    },
    ("8453", "0x9dda783de64a9d1a60c49ca761ebe528c35ba428"): {
        "asset": "COMP", "name": "COMP / USD", "registered": 86400,
        "intervals": 373, "breaches": 0, "max_gap_s": 41490, "median_gap_s": 2852,
        "window_days": 20.9, "measured": "2026-07-31",
        "note": "Volatile asset; deviation-active.",
    },
    ("10", "0xe1011160d78a80e2eebd60c228eef7af4dfcd4d7"): {
        "asset": "COMP", "name": "COMP / USD", "registered": 86400,
        "intervals": 322, "breaches": 0, "max_gap_s": 41516, "median_gap_s": 2569,
        "window_days": 16.9, "measured": "2026-07-31",
        "note": "Volatile asset; deviation-active.",
    },
    ("10", "0x698b585cbc4407e2d54aa898b2600b53c68958f7"): {
        "asset": "wstETH", "name": "WSTETH / USD", "registered": 86400,
        "intervals": 262, "breaches": 0, "max_gap_s": 60596, "median_gap_s": 2694,
        "window_days": 16.9, "measured": "2026-07-31",
        "note": "LST/USD tracks ETH, so deviation fires well before the heartbeat.",
    },
}


def _fix_hint(chain_id: str, name: str, declared: int, where: str = "", hb_key: str = "") -> str:
    """Name BOTH legitimate exits. A guard that fires without saying how to satisfy it gets bypassed."""
    suggested = declared          # ADR 0025: exactly declared, no margin
    nav_file = f"nav-config/assets-and-price-feeds/{chain_id}.json"
    # THE HINT MUST NOT PRESCRIBE THE SILENCING EDIT. A custom feed is gated on TWO independently
    # registered heartbeats against the same provider cadence: the constructor key this axis checks, and
    # the NAV-side `priceFeeds[i].heartbeat` it does not. The feed propagates its rate leg's timestamp
    # (min(rate, base)), so the NAV applies that second heartbeat to the same publish cadence — and it is
    # the one that drops the feed and zeroes the asset. Raising only the key named below therefore makes
    # this warning disappear while the defect it reported is still there, which is the exact shape of the
    # historical --allow-shrink defect: the remedy re-creates what it was added to prevent.
    two_gates = ""
    if hb_key not in ("", "heartbeat"):
        two_gates = (
            f"        (1b) RAISE BOTH — this feed has TWO heartbeats and this axis checks only one. "
            f"`{hb_key}` (above) is the constructor value; the NAV separately gates the same feed on "
            f"`priceFeeds[i].heartbeat` in {nav_file}. A custom feed propagates its rate leg's timestamp, "
            f"so that second value is applied to the SAME provider cadence and is the one that zeroes the "
            f"asset. Editing only the constructor key SILENCES this warning without fixing anything — "
            f"this guard cannot tell you when that has happened. PR #236 raised both, for OETH.\n")
    return (
        f"FIX:\n"
        f"        SET the registered heartbeat to EXACTLY the declared value. For '{name}' that is "
        f"{suggested}. Edit `{hb_key or 'heartbeat'}` in {where or nav_file}. Do not add margin — see "
        f"docs/decisions/0025-heartbeat-equals-declared.md for why, including the measured cost.\n"
        f"{two_gates}"
        f"        THERE IS NO SECOND EXIT. An ALLOWLIST entry does NOT resolve this finding: the "
        f"exemption answers whether the heartbeat ever BINDS (a deviation-active feed publishes long "
        f"before it), and ADR 0025's rule is about the VALUE, which the exemption does not waive. An "
        f"allowlisted feed registered away from declared is still an ERROR — see the allowlist branch in "
        f"`_declared_findings`. Add the entry if the cadence argument is worth recording, but set the "
        f"heartbeat to the declared value either way.\n"
        f"        Do NOT simply widen the heartbeat to silence this without checking the derived-vs-base "
        f"pairing too: raising a BASE asset's heartbeat can leave its DERIVED feed tighter than its base, "
        f"which is the separate invariant preflight_config.heartbeat_findings enforces."
    )


def configured_chain_ids() -> list[str]:
    """Every chain the CONFIG registers feeds for — the authority on what must be checked.

    Deliberately NOT derived from the snapshot's own `chains` keys. Scoping the run to the snapshot lets
    the snapshot decide what gets audited, so a snapshot that lost a chain silently stops checking it and
    an EMPTY snapshot examines ZERO FEEDS. Config is the invariant; the snapshot is the evidence being
    tested against it, and evidence must never get to choose its own scope.

    PRECISELY WHAT THIS BUYS, and what it does not: it guarantees every configured chain is EXAMINED, so
    a degraded snapshot can no longer shrink the audit silently. It does NOT by itself make the run exit
    non-zero — with an empty snapshot every feed reports "no declared heartbeat recorded", which is a
    WARN, so `total ERRORs: 0` still holds. That is intended (an unrecorded address is not an evidence
    contradiction), but it means the exit code alone must never be read as "coverage was good": read the
    WARN count too.
    """
    ids: set[str] = set()
    for sub in ("nav-config/assets-and-price-feeds", "contracts-deployment-config/custom-price-feeds"):
        d = REPO / "script/config" / sub
        if d.is_dir():
            ids.update(p.stem for p in d.glob("*.json") if p.stem.isdigit())
    # DELIBERATELY UNFILTERED — scope comes from the config tree and nothing else. A `chains/<id>.json`
    # requirement was tried here to suppress a stray test fixture being audited as a real chain, and it
    # was withdrawn: it broke this module's own `--self-test` (whose arm points REPO at a tempdir with no
    # `chains/` directory), it silently shrank the audit for a chain configured before its metadata file
    # landed — the exact "evidence must never choose its own scope" failure this function exists to
    # prevent — and its own not-readable fallback restored the phantom it was added to kill, without even
    # a warning. Three defects to suppress one visually obvious symptom (an empty `chain 999901` section
    # from an abnormally-terminated test run, which `git status` also shows) was the wrong trade.
    return sorted(ids, key=int)


def load_snapshot() -> dict:
    if not SNAPSHOT.exists():
        raise SystemExit(f"missing snapshot {SNAPSHOT}; run: python3 {Path(__file__).name} --refresh")
    return json.loads(SNAPSHOT.read_text())


class _NotAConfigObject(json.JSONDecodeError):
    """A file that is valid JSON but not a config object. Raised as a JSONDecodeError subclass so the
    existing `except json.JSONDecodeError` handlers report it identically — a top-level `[]`/`null`/`0`
    used to slip through `or {}` and produce zero rows, which reads exactly like 'this chain has no feeds'.
    """

    def __init__(self, value):
        super().__init__(f"top level is {type(value).__name__}, expected an object", "", 0)


def _as_config_object(v):
    if not isinstance(v, dict):
        raise _NotAConfigObject(v)
    return v


def registered_feeds(chain_id: str) -> list[dict]:
    """Every (address, heartbeat) this chain registers, from both config shapes.

    Custom feeds appear via their RATE LEG rather than their nav-config entry, because it is the rate leg
    that has a provider cadence — the custom wrapper has no provider of its own. Rate legs are discovered
    BY SHAPE, not by one key name: every `<stem>Heartbeat` constructor key is paired with the
    address-valued sibling sharing its stem. Matching only `yToXFeed`/`yToXHeartbeat` silently missed nine
    enabled feeds whose leg is named for the pair it prices (`wstEthToEthChainlink`, `ldoToEth…`, …).
    A heartbeat whose address cannot be identified, or which matches several, is REPORTED, never guessed.
    """
    def _is_address(v):
        # Hex-ness matters: without it a 42-character non-address string could be selected as a feed's
        # rate-leg address, which is a wrong-address verdict rather than a missing one.
        if not (isinstance(v, str) and v.startswith("0x") and len(v) == 42):
            return False
        try:
            int(v, 16)
        except ValueError:
            return False
        return True

    def _int_or_none(v):
        """Never raise while ENUMERATING. A row this cannot parse is emitted with heartbeat=None and
        reported by `_row_findings`; raising here would lose the whole chain's rows at once, which is
        the same failure `findings` contains per row. Parses exactly like the stale-cap scan."""
        return _parse_heartbeat(v)

    out: list[dict] = []
    nav = REPO / f"script/config/nav-config/assets-and-price-feeds/{chain_id}.json"
    if nav.exists():
        try:
            assets = _as_config_object(json.loads(nav.read_text()))
        except json.JSONDecodeError as e:
            # NOT swallowed into {}. An unparseable config would otherwise yield zero rows, and zero rows
            # is indistinguishable from "this chain has no feeds" — so a corrupt config would report a
            # clean chain. Emitted as a row so `_row_findings` turns it into an ERROR.
            assets = {}
            out.append({"asset": "(config)", "role": "file", "address": str(nav.name),
                        "heartbeat": None, "config_error": f"not valid JSON: {e}",
                        "where": f"nav-config/assets-and-price-feeds/{chain_id}.json"})
        for sym, entry in assets.items():
            if not isinstance(entry, dict):
                continue
            for kind in ("priceFeeds", "monitorFeeds"):
                for i, fd in enumerate(entry.get(kind) or []):
                    # An address with an UNUSABLE heartbeat is emitted, not dropped. Silently skipping
                    # it would leave the feed unchecked while the run still reads as full coverage.
                    if not isinstance(fd, dict):
                        out.append({"asset": sym, "role": f"{kind}[{i}]", "address": "-",
                                    "heartbeat": None,
                                    "where": f"nav-config/assets-and-price-feeds/{chain_id}.json",
                                    "no_address": f"the entry is {type(fd).__name__}, not an object, so "
                                                  f"it cannot be read"})
                        continue
                    if not fd.get("address"):
                        # A `type: Custom` entry names its feed (`"feed": "wstETH"`) instead of carrying
                        # an address — the address lives in the deployment record. Silent here, for two
                        # DIFFERENT reasons, and the distinction matters because an earlier version of
                        # this comment asserted the first reason for all of them and was wrong for half:
                        #   * 21 of the 41 have a Chainlink rate leg in the deploy config, whose
                        #     CONSTRUCTOR heartbeat this axis checks as a `rate leg (...)` row. Their
                        #     NAV-SIDE heartbeat — the one on this very entry — is NOT checked by anything.
                        #   * the other 20 (wstETH, eETH, rETH, sUSDS, sGHO, …) have NO Chainlink leg at
                        #     all — they read an on-chain exchange rate — so this axis does not apply.
                        # Do NOT read the second bullet as "covered elsewhere": the derived-vs-base axis
                        # does NOT close that gap either (see the module docstring — it asserts
                        # derived >= base and treats LST feeds at 86400 against WETH's 3600 as correct).
                        # Silence here means NOT EXAMINED, never examined-and-fine. This comment has now
                        # been wrong twice about what this exemption covers; it is load-bearing, because
                        # it is what the next reader will trust instead of re-deriving.
                        # Reporting them flagged 41 correct entries: pure cry-wolf. Anything with no
                        # address AND no named custom feed genuinely cannot be looked up.
                        if not (fd.get("type") == "Custom" and fd.get("feed")):
                            out.append({"asset": sym, "role": f"{kind}[{i}]", "address": "-",
                                        "heartbeat": None,
                                        "where": f"nav-config/assets-and-price-feeds/{chain_id}.json",
                                        "no_address": "the entry has no `address` and does not name a "
                                                      "custom `feed`, so there is nothing to look up"})
                        continue
                    if True:  # address present: the branch above `continue`s when it is not
                        out.append({"asset": sym, "role": f"{kind}[{i}]",
                                    "address": fd["address"],
                                    "heartbeat": _int_or_none(fd.get("heartbeat")),
                                    "heartbeat_raw": fd.get("heartbeat"),
                                    "where": f"nav-config/assets-and-price-feeds/{chain_id}.json"})
    dep = REPO / f"script/config/contracts-deployment-config/custom-price-feeds/{chain_id}.json"
    if dep.exists():
        try:
            feeds = _as_config_object(json.loads(dep.read_text()))
        except json.JSONDecodeError as e:
            feeds = {}
            out.append({"asset": "(config)", "role": "file", "address": str(dep.name),
                        "heartbeat": None, "config_error": f"not valid JSON: {e}",
                        "where": f"contracts-deployment-config/custom-price-feeds/{chain_id}.json"})
        for name, v in feeds.items():
            if not isinstance(v, dict):
                continue
            # EVERY SCOPE `readAdapterParam` SEARCHES, not just `constructor`. A leg written beside
            # `constructor` — which that resolver checks FIRST, so `03` deploys from it — produced no row
            # here at all, and `coverage_census` read the same narrow path, so the containment check
            # compared a short list against a short expectation and reported FULL coverage over a leg it
            # had never examined. On an exact key collision the OUTER scope WINS — the last spread in a
            # dict literal takes precedence, and `readAdapterParam` tests `.<feed>.<key>` FIRST.
            ctor = {**(v.get("initialize") or {}), **(v.get("constructor") or {}),
                    **{k: x for k, x in v.items() if not isinstance(x, dict) and not k.startswith("$")}}
            # RATE LEGS ARE FOUND BY SHAPE, NOT BY ONE HARD-CODED KEY NAME. Matching only
            # `yToXFeed`/`yToXHeartbeat` silently missed nine ENABLED custom feeds whose leg is named for
            # the pair it prices — `wstEthToEthChainlink`/`wstEthToEthHeartbeat`,
            # `ldoToEthChainlinkAddress`/`ldoToEthChainlinkHeartbeat`, and so on. Those are exactly the
            # LST-rate feeds this audit targeted, so the guard read as covering custom feeds while
            # checking a third of them. Every `<stem>Heartbeat` is paired with the address-valued key
            # that shares its stem; a heartbeat with no such partner is REPORTED, never dropped.
            hb_keys = sorted(k for k in ctor if k.endswith("Heartbeat"))
            if not hb_keys and isinstance(ctor.get("yToXFeed"), str):
                # A rate leg with NO heartbeat key at all. Discovery is driven by heartbeat keys, so this
                # shape would otherwise vanish entirely — the silent drop this module exists to prevent.
                # Gating this on `_is_address` was itself a silent drop: a malformed `yToXFeed` was
                # counted by the census (which sees a string) and enumerated by nobody, so it fell through
                # the invariant's own crack. Emit the row either way and let `_row_findings` judge it.
                _leg = {"asset": name, "role": "rate leg (yToXFeed)", "address": ctor["yToXFeed"],
                        "heartbeat": None, "heartbeat_raw": None, "enabled": bool(v.get("enabled")),
                        "where": f"contracts-deployment-config/custom-price-feeds/{chain_id}.json"}
                if not _is_address(ctor["yToXFeed"]):
                    _leg = {**_leg, "address": "-",
                            "unpaired_heartbeat": f"`yToXFeed` is {ctor['yToXFeed']!r}, which is not an "
                                                  f"address, so no rate leg could be identified"}
                out.append(_leg)
            for hb_key in hb_keys:
                stem = hb_key[: -len("Heartbeat")]
                # An EMPTY stem (a key named exactly "Heartbeat") would prefix-match every key in the
                # constructor and pair the heartbeat with an arbitrary unrelated address — a confident
                # verdict about the wrong feed, which is worse than no coverage. Require a real stem.
                cands = [k for k in sorted(ctor)
                         if stem and k != hb_key and k.startswith(stem) and _is_address(ctor.get(k))]
                # Prefer an exact stem match, then a recognised rate-leg suffix. If that still leaves
                # more than one candidate, REPORT the ambiguity instead of guessing: silently picking
                # whichever sorts first is exactly how a wrong-address verdict would go unnoticed.
                exact = [k for k in cands if k == stem]
                suffixed = [k for k in cands
                            if k[len(stem):] in ("Feed", "Chainlink", "ChainlinkAddress", "Address",
                                                 "Oracle", "Aggregator", "PriceFeed")]
                pick = exact or suffixed or cands
                addr = ctor[pick[0]] if len(pick) == 1 else None
                if len(pick) > 1:
                    out.append({"asset": name, "role": f"rate leg ({hb_key})", "address": "-",
                                "heartbeat": None, "enabled": bool(v.get("enabled")),
                                "where": f"contracts-deployment-config/custom-price-feeds/{chain_id}.json",
                                "unpaired_heartbeat": f"`{hb_key}` matches MORE THAN ONE address key "
                                                      f"({', '.join(pick)}), so its rate leg is ambiguous "
                                                      f"and was not guessed"})
                    continue
                hb = ctor.get(hb_key)
                row = {"asset": name, "role": f"rate leg ({hb_key})",
                       "heartbeat": _int_or_none(hb), "heartbeat_raw": hb,
                       "enabled": bool(v.get("enabled")),
                       "where": f"contracts-deployment-config/custom-price-feeds/{chain_id}.json"}
                if addr:
                    out.append({**row, "address": addr})
                else:
                    # A heartbeat with no resolvable address is not "nothing to check" — it means the
                    # pairing heuristic did not recognise this feed's shape, which is how coverage goes
                    # missing quietly. Say so.
                    out.append({**row, "address": "-",
                                "unpaired_heartbeat": f"`{hb_key}` has no sibling address key starting "
                                                      f"with '{stem}'"})
    return out


def _strict_int(v):
    """`v` as an int only if it is genuinely an integer. `False == 0` and `isinstance(True, int)` are
    both true in Python, and a float slips a `!= 0` test, so a bare comparison lets `breaches: False`
    and `intervals: True` satisfy an evidence gate whose whole job is to catch authoring mistakes in
    exemptions. The module already guards this in `_int_or_none` and in `refresh`'s recorder; the one
    place where getting it wrong grants a PERMANENT exemption was the one place that omitted it.
    """
    return v if isinstance(v, int) and not isinstance(v, bool) else None


def _hb_key(r: dict) -> str:
    """The config key an operator must actually edit for this row — `heartbeat` for a nav-config feed,
    or the real `<stem>Heartbeat` name for a custom feed's rate leg. Naming the wrong key sends the
    operator to a field that does not exist, which is how a guard gets bypassed rather than satisfied."""
    role = r.get("role", "")
    if role.startswith("rate leg (") and role.endswith(")"):
        return role[len("rate leg ("):-1]
    return "heartbeat"


def _consequence(role: str) -> str:
    """The consequence of going stale is NOT the same for a pricing feed and a monitor feed.

    A PRIMARY feed going stale lists the asset in `stalePriceAssets`; if no primary is fresh the asset keeps
    its last-known price (ADR 0029) until that price is `MAX_STALE_PRICE_AGE` old. A MONITOR feed
    never prices — `getPriceDataNoDivergence` selects over the primary mapping only — so its staleness
    surfaces as an unhealthy-monitor signal instead. Stating the pricing consequence for a monitor row
    would overstate the impact, and overstated findings are how a guard loses its credibility.
    """
    if role.startswith("monitorFeeds"):
        return (" This is a MONITOR feed, so it does not price the asset: staleness here does not touch "
                "the valuation, it degrades the divergence check and surfaces as an unhealthy monitor.")
    if role.startswith("rate leg"):
        # A custom feed's rate leg may back a PRIMARY or a MONITOR registration — which one is not
        # visible from this row. State the conditional rather than asserting the pricing consequence,
        # because asserting it for a monitor-only feed would overstate the impact.
        return (" This is a custom feed's RATE LEG: if that feed is registered as a primary it flags "
                "the asset stale (it keeps its last-known price, ADR 0029), and if it is registered only as "
                "a monitor it degrades the divergence check instead. Check which the feed is registered as "
                "before triaging.")
    return (" The asset is listed in `stalePriceAssets` and, if no other primary is fresh, keeps its "
            "last-known price flagged stale (ADR 0029).")


def _row_findings(chain_id: str, r: dict, declared: dict) -> list[tuple[str, str]]:
    """Verdict for ONE registered feed row. Split out of `findings` so a malformed row can be contained.

    Raises only if the row or its snapshot entry is genuinely malformed; `findings` catches that per row.
    """
    key = str(r["address"]).lower()
    rec = declared.get(key)
    # A custom feed the deploy step will not deploy is lower priority, but it is not exempt — it bites
    # the moment someone flips `enabled`. Surfaced rather than filtered, so the queue stays honest.
    off = " (NOTE: this custom feed is currently enabled=false, so it will not be deployed yet — lower "\
          "priority, but it will bite the moment it is enabled.)" if r.get("enabled") is False else ""
    if r.get("no_address"):
        return [(WARN, f"asset '{r['asset']}' {r['role']}: {r['no_address']}, so this entry is NOT "
                       f"covered by the declared-margin guard.{off}")]
    if r.get("unpaired_heartbeat"):
        # A heartbeat with no sibling address is NOT necessarily a defect: some custom feeds declare a
        # heartbeat for a non-Chainlink source (ETHPlus's `reserveProtocolHeartbeat` reads the Reserve
        # protocol, not a Chainlink aggregator), and this axis only models Chainlink cadences. So it is a
        # WARN — "this feed is not covered" — never an ERROR, which would cry wolf on a correct config
        # and break the 0-ERRORs-on-a-clean-tree contract the severity ladder depends on.
        return [(WARN, f"asset '{r['asset']}' {r['role']}: {r['unpaired_heartbeat']}, so no Chainlink "
                       f"rate-leg address could be identified and this heartbeat is NOT covered by the "
                       f"declared-margin guard. Expected when the heartbeat governs a non-Chainlink "
                       f"source; otherwise the constructor key naming needs a look.{off}")]
    if r.get("config_error"):
        # The config file itself could not be read. ERROR, because the chain cannot be audited at all
        # and "no rows" would otherwise read exactly like "no feeds configured".
        return [(ERROR, f"config file {r['address']} could not be parsed ({r['config_error']}). This "
                        f"chain has NO declared-heartbeat coverage — that is not the same as clean.")]
    if r.get("heartbeat") is None:
        # Enumerated but unusable. Reported, never skipped: a feed this axis cannot check must not be
        # indistinguishable from one it checked and cleared.
        return [(WARN, f"asset '{r['asset']}' {r['role']} {r['address']} has NO usable integer "
                       f"`heartbeat` in config (found {r.get('heartbeat_raw')!r}), so this feed is NOT "
                       f"covered by the declared-margin guard. Fix the config value; until then this "
                       f"feed is unchecked, not clean.{off}")]
    if rec is None:
        # Not a Chainlink-catalogue feed (RedStone/API3), or the snapshot predates this address.
        # Reported as actionable rather than passing silently — the two cases look identical here.
        # The remedy has to TERMINATE: --refresh only ever resolves Chainlink-catalogue addresses, so
        # telling the operator to keep running it would loop forever on a RedStone/API3 feed.
        if str(chain_id) not in DIRECTORY_FILES:
            # --refresh cannot reach this chain at all, so the usual "run it and see" advice would tell
            # the operator to dismiss REAL Chainlink feeds as non-Chainlink. Name the actual blocker.
            return [(WARN, f"asset '{r['asset']}' {r['role']} {r['address']} has NO declared heartbeat "
                           f"recorded, and chain {chain_id} has NO entry in DIRECTORY_FILES — so "
                           f"--refresh cannot resolve it and NOTHING on this chain is covered by this "
                           f"axis. Do NOT read this as 'not a Chainlink feed': add the chain's "
                           f"reference-data-directory filename to DIRECTORY_FILES, then --refresh.{off}")]
        return [(WARN, f"asset '{r['asset']}' {r['role']} {r['address']} has NO declared heartbeat "
                       f"recorded. Either it is not a Chainlink-catalogue feed (RedStone/API3 — expected, "
                       f"no action), or the snapshot is missing it. To distinguish: run --refresh once. A "
                       f"Chainlink feed gains an entry; a non-Chainlink one never will, so a WARN that "
                       f"survives a SUCCESSFUL refresh means 'not a Chainlink feed' and needs no "
                       f"action.{off}")]
    dh, rh = int(rec["declaredHeartbeat"]), int(r["heartbeat"])
    if dh == 0:
        # A declared heartbeat of 0 means "no heartbeat cadence" — a deviation-only feed. The margin rule
        # genuinely does not apply, but staying SILENT would make that indistinguishable from a verified
        # positive margin, which is the confusion this whole module exists to remove. Say which it is.
        return [(WARN, f"asset '{r['asset']}' {r['role']} ({rec.get('name')}) has a provider-declared "
                       f"heartbeat of 0 — a deviation-only feed with no heartbeat cadence, so the margin "
                       f"rule does not apply. Reported rather than passed silently: silence here would "
                       f"read exactly like a checked-and-fine positive margin. Its freshness depends "
                       f"entirely on the deviation threshold, which this axis does not model.{off}")]
    # ADR 0025 REMOVED THIS EARLY RETURN. It used to read `if rh > dh: return []` — margin above
    # declared was the PASS state. Under the equality rule it is the critical failure: every second
    # above declared is a window in which a dead feed reads fresh. Leaving it in place made the
    # inverted check below unreachable for exactly the registrations it exists to catch, which a
    # revert-probe caught (DAI set to 7200 against a declared 3600 produced zero findings).
    allow = ALLOWLIST.get((str(chain_id), key))
    if allow:
        if _strict_int(allow.get("breaches")) != 0:
            return [(ERROR, f"asset '{r['asset']}' {r['role']} is allowlisted but its recorded evidence "
                            f"shows {allow.get('breaches', 'no `breaches` field')} — an allowlist entry "
                            f"must record 0 breaches. "
                            f"Fix the feed, do not exempt it.")]
        if allow.get("registered") != rh:
            return [(ERROR, f"asset '{r['asset']}' {r['role']} allowlist entry was measured against "
                            f"registered={allow.get('registered')} but the config now says {rh}. "
                            f"Re-measure and update the entry; a stale exemption is not evidence.")]
        # THE EVIDENCE MUST ACTUALLY BE THERE. `breaches: 0` alone is not a measurement — an entry with
        # no interval count and no date asserts a conclusion while recording nothing that can be re-run,
        # which is precisely the "place to hide a real defect" the allowlist's own comment warns about.
        if (_strict_int(allow.get("intervals")) or 0) <= 0:
            return [(ERROR, f"asset '{r['asset']}' {r['role']} is allowlisted but records no `intervals` "
                            f"count, so its `breaches: 0` rests on nothing re-runnable. An exemption "
                            f"without a measurement is not evidence.")]
        age = _measurement_age_days(allow.get("measured"))
        if age is None:
            return [(ERROR, f"asset '{r['asset']}' {r['role']} is allowlisted but its `measured` date is "
                            f"missing or unparseable ({allow.get('measured')!r}), so the evidence cannot "
                            f"be aged and could be arbitrarily old.")]
        if age > MEASUREMENT_STALE_DAYS:
            # Emitted HERE, on the path preflight actually runs — not only in --self-test. Aging evidence
            # solely inside the self-test would repeat this module's original defect exactly: a signal
            # that fires when a human runs the tool by hand and never during the run that gates a deploy.
            return [(WARN, f"asset '{r['asset']}' {r['role']} is exempt on evidence that is {age} days "
                           f"old (>{MEASUREMENT_STALE_DAYS}). Publisher cadence drifts, so an old "
                           f"measurement ages exactly like the snapshot does. Re-measure the "
                           f"AnswerUpdated gaps and update `measured`, or drop the exemption.{off}")]
        # ADR 0025: the exemption may not silently carry a registration that is NOT equal to declared.
        # The allowlist predates the equality rule — it exempted deviation-active feeds from the old
        # margin requirement — and it returns on `registered == rh` without ever comparing rh to dh. All
        # six current entries happen to sit exactly at declared, so this is inert today; it is guarded so
        # a future entry cannot reintroduce a false-fresh window behind a measurement.
        if dh and rh != dh:
            # ERROR, matching the non-allowlisted path. The comment above already says the exemption
            # covers the CADENCE argument and not the equality rule; leaving this a WARN said the
            # opposite in the only place that binds, since WARNs do not fail the build. An allowlisted
            # feed would then carry a false-fresh window through the very gate meant to block it.
            return [(ERROR, f"declared-heartbeat MISMATCH: asset '{r['asset']}' {r['role']} is exempt by "
                            f"measurement but registered at {rh} against a declared {dh} ({rh - dh:+d}s). "
                            f"The measured exemption answers the CADENCE question — whether the heartbeat "
                            f"ever binds — and does NOT waive ADR 0025's equality rule. Set the heartbeat "
                            f"to {dh}; the exemption can stay.{off}")]
        return []
    # ADR 0025 INVERTED THIS CHECK. The rule is now EQUALITY: a registered heartbeat must equal the
    # provider's declared value exactly. Margin ABOVE declared is a window in which a dead feed reads
    # fresh — the one error this system treats as critical — and margin BELOW declared manufactures
    # staleness in quiet markets, where provider silence is legitimate.
    #
    # This file previously required margin ABOVE declared and treated zero margin as a WARN-level
    # candidate. That reasoning is preserved in the module docstring as history: it correctly
    # identified that at-or-below margin makes heartbeat-driven feeds go stale each cycle (sUSDS
    # 59/61, OETH 29/29), and `f047d350` acted on it. ADR 0025 accepts that cost deliberately — the
    # landing delay is +2..+96s, so the staleness share is 0.0-0.03% of reads for most feeds and at
    # worst 5.6% (Arbitrum USDC) — in exchange for closing false-fresh windows that reached ~24 h.
    #
    # ERROR, not WARN: under an equality rule there is no "candidate" state. A mismatch is either
    # unearned false-fresh exposure or manufactured staleness, and both are defects.
    if rh == dh:
        return []
    direction = ("ABOVE declared — every second of this is a window in which a DEAD feed still reads "
                 "FRESH, the critical error under ADR 0025") if rh > dh else \
                ("BELOW declared — the provider is entitled to stay silent this long, so this "
                 "manufactures staleness in a quiet market")
    return [(ERROR,
             f"declared-heartbeat MISMATCH: asset '{r['asset']}' {r['role']} ({rec.get('name')}) is "
             f"registered at {rh} but the provider declares {dh} — {rh - dh:+d}s {direction}."
             f"{_consequence(r['role'])}{off}\n"
             f"        {_fix_hint(str(chain_id), rec.get('name') or '?', dh, r.get('where', ''), _hb_key(r))}")]


def coverage_census(chain_id: str) -> dict:
    """What the CONFIG declares, counted independently of `registered_feeds`.

    THE INVARIANT THIS EXISTS FOR: every configured feed entry must be ACCOUNTED FOR — it either produced
    an enumerated row, or it is in the explicitly-counted exempt set. Nothing may simply disappear.

    Every silent-coverage defect this module has had would have been caught by that one equality: nine
    rate legs missed because only `yToXFeed` was matched, rows dropped for a non-int heartbeat, a non-dict
    entry skipped, `if not refs: continue` deleting a chain, and a top-level `[]` config reading as zero
    feeds. Each of them shows up here as `enumerated + exempt != configured`.

    It is deliberately re-derived from the raw JSON rather than by calling `registered_feeds`, because a
    census that shares the enumerator's code shares its blind spots and can only ever agree with it.
    """
    nav_entries = exempt_named_custom = leg_keys = 0
    nav = REPO / f"script/config/nav-config/assets-and-price-feeds/{chain_id}.json"
    if nav.exists():
        raw = json.loads(nav.read_text())
        if not isinstance(raw, dict):
            raise _NotAConfigObject(raw)
        for _sym, entry in raw.items():
            if not isinstance(entry, dict):
                nav_entries += 1          # malformed, but still a configured thing that must be accounted for
                continue
            for kind in ("priceFeeds", "monitorFeeds"):
                for fd in entry.get(kind) or []:
                    nav_entries += 1
                    if (isinstance(fd, dict) and not fd.get("address")
                            and fd.get("type") == "Custom" and fd.get("feed")):
                        exempt_named_custom += 1
    dep = REPO / f"script/config/contracts-deployment-config/custom-price-feeds/{chain_id}.json"
    if dep.exists():
        raw = json.loads(dep.read_text())
        if not isinstance(raw, dict):
            raise _NotAConfigObject(raw)
        for _name, v in raw.items():
            if not isinstance(v, dict):
                continue
            # Same merge as `registered_feeds` above — the census must count what that function can see,
            # or the containment check it feeds is comparing a number against itself.
            ctor = {**(v.get("initialize") or {}), **(v.get("constructor") or {}),
                    **{k: x for k, x in v.items() if not isinstance(x, dict) and not k.startswith("$")}}
            hb = [k for k in ctor if k.endswith("Heartbeat")]
            leg_keys += len(hb) or (1 if isinstance(ctor.get("yToXFeed"), str) else 0)
    return {"navEntries": nav_entries, "exemptNamedCustom": exempt_named_custom, "legKeys": leg_keys,
            "expectedRows": nav_entries - exempt_named_custom + leg_keys}


def stale_cap_findings(chain_id: str) -> list[tuple[str, str]]:
    """ADR 0029: every PRIMARY heartbeat must be below MAX_STALE_PRICE_AGE (7 days), `type(uint256).max` excepted.

    A separate scan of the nav-config, NOT a `_row_findings` arm, because the cap applies to EVERY primary while
    `registered_feeds` deliberately omits named `Custom` primaries (`{"type": "Custom", "feed": "wstETH"}`: no
    address, no provider cadence for the declared-heartbeat axis). Those are most of the custom-feed primaries, so
    checking the cap only on enumerated rows missed exactly the feeds the cap matters most for. Independent of the
    declared snapshot. At or above the cap a primary goes from fresh straight to unusable and prices at 0. On-chain,
    `PriceFeedLib.addFeed` rejects such a registration (`HeartbeatNotBelowStaleCap`); this catches it in config.
    Monitors never price, so they are exempt. An unparseable config is reported by `registered_feeds`, not here.
    """
    nav = REPO / f"script/config/nav-config/assets-and-price-feeds/{chain_id}.json"
    if not nav.exists():
        return []
    try:
        assets = json.loads(nav.read_text())
    except json.JSONDecodeError:
        return []
    if not isinstance(assets, dict):
        return []
    out: list[tuple[str, str]] = []
    for sym, entry in assets.items():
        if not isinstance(entry, dict):
            continue
        for i, fd in enumerate(entry.get("priceFeeds") or []):
            if not isinstance(fd, dict):
                continue
            raw = fd.get("heartbeat")
            ident = fd.get("address") or (f"Custom feed '{fd['feed']}'" if fd.get("feed") else "(no address)")
            hb = _parse_heartbeat(raw)
            if hb is None:
                # An absent heartbeat defaults to 3600 on the deploy path, so only a PRESENT unreadable one is a
                # gap. Reported for named Custom rows only: `registered_feeds` omits them, so nothing else would
                # surface it, while an addressed row's bad heartbeat is already a `_row_findings` WARN.
                # A present `null` counts too: the deploy path's `vm.keyExists` is true for it and the read reverts.
                if "heartbeat" in fd and not fd.get("address"):
                    out.append((WARN, f"chain {chain_id} asset '{sym}' priceFeeds[{i}] {ident}: heartbeat "
                                      f"{raw!r} is not a non-negative integer, so it is NOT checked against "
                                      f"MAX_STALE_PRICE_AGE."))
                continue
            if hb == UINT256_MAX or hb < MAX_STALE_PRICE_AGE:
                continue
            out.append((ERROR, f"chain {chain_id} asset '{sym}' priceFeeds[{i}] {ident} registers heartbeat "
                               f"{hb} s, at or above MAX_STALE_PRICE_AGE ({MAX_STALE_PRICE_AGE} s = 7 days, "
                               f"src/constants.sol, ADR 0029). Past its heartbeat a primary keeps pricing only "
                               f"while it is younger than the cap, so this feed would go from fresh straight to "
                               f"unusable and the asset would price at 0; on-chain registration reverts "
                               f"HeartbeatNotBelowStaleCap. Register a heartbeat below 7 days "
                               f"(nav-config/assets-and-price-feeds/{chain_id}.json)."))
    return out


def findings(chain_id: str, snapshot: dict | None = None) -> list[tuple[str, str]]:
    """(level, message) for one chain — the per-feed declared-heartbeat verdicts.

    Severity under ADR 0025 (EQUALITY): SILENT when registered == declared, or for an evidenced allowlist
    entry that is itself at declared. ERROR for a mismatch in EITHER direction — above declared is an
    unearned false-fresh window, below it manufactures staleness, and under an equality rule neither is a
    "candidate" state. WARN is reserved for the cases where the rule cannot be evaluated or the exemption
    needs a human look: no declared value recorded, a declared value of 0, an allowlist entry with stale or
    missing evidence, and an exemption carrying a registration that is not equal to declared.

    THIS REPLACED A THREE-STATE MARGIN LADDER (silent above declared, WARN at-or-below-and-unmeasured,
    ERROR only on a contradicted exemption). If you are reading that model anywhere in this module, it is
    stale — the module docstring keeps its MEASUREMENTS as history, not its severities.

    Snapshot-LEVEL findings (staleness) are deliberately NOT returned here, because they are not
    per-chain. Every caller must ALSO call `snapshot_findings_once` — both entry points in this repo do.
    """
    snap = snapshot if snapshot is not None else load_snapshot()
    declared = (snap.get("chains") or {}).get(str(chain_id), {})
    f: list[tuple[str, str]] = []
    # ENUMERATION is contained too, not just each row. `registered_feeds` reads config files whose shape
    # it does not control; if it raises here the `for` header never binds and the whole chain's coverage
    # is lost through preflight_config's fail-soft handler — the per-row containment below would never
    # get the chance to run.
    try:
        rows = registered_feeds(str(chain_id))
    except Exception as e:  # noqa: BLE001 - a chain that cannot be enumerated must not read as clean
        return [(ERROR, f"chain {chain_id}: could NOT enumerate registered feeds ({e!r}), so this chain "
                        f"has NO declared-heartbeat coverage. Fix the config shape; an unenumerable "
                        f"chain is not a clean one.")]
    for r in rows:
        # CONTAINMENT, per row. One malformed row must never discard the verdicts already computed for
        # this chain. Without this, a single KeyError propagated out of findings(), and preflight_config's
        # fail-soft `except Exception` collapsed the WHOLE chain — including a deploy-blocking ERROR it
        # had already detected — into one WARN, so preflight exited 0 on a stale exemption.
        try:
            f += _row_findings(str(chain_id), r, declared)
        except Exception as e:  # noqa: BLE001 - an unevaluatable row must not read as a clean one
            f.append((ERROR, f"asset '{r.get('asset', '?')}' {r.get('role', '?')} "
                             f"{r.get('address', '?')}: the guard could NOT evaluate this feed — its "
                             f"snapshot entry or configured heartbeat is malformed ({e!r}). Its margin is "
                             f"UNKNOWN, not fine. Regenerate with --refresh, or fix the entry by hand. "
                             f"ERROR because a feed the guard cannot evaluate must not read as coverage."))
    # The ADR 0029 stale cap covers every primary, including the named Custom ones `registered_feeds` omits.
    try:
        f += stale_cap_findings(str(chain_id))
    except Exception as e:  # noqa: BLE001 - an unevaluatable cap check must not read as a clean one
        f.append((ERROR, f"chain {chain_id}: the ADR 0029 stale-cap check could NOT run ({e!r}); the primary "
                         f"heartbeats on this chain are unchecked against MAX_STALE_PRICE_AGE, not clean."))
    return f


_SNAPSHOT_FINDINGS_EMITTED = False


def _reset_snapshot_findings_once() -> None:
    """Re-arm `snapshot_findings_once`.

    Used by the self-test to assert both the emit and the dedupe, AND by `preflight_config`'s per-chain
    error handler: the staleness signal is emitted once per process, so a chain that consumed it and then
    failed would take that signal down for the whole run unless the latch is re-armed.
    """
    global _SNAPSHOT_FINDINGS_EMITTED
    _SNAPSHOT_FINDINGS_EMITTED = False


def snapshot_findings_once(snap: dict | None = None) -> list[tuple[str, str]]:
    """Snapshot-LEVEL findings (staleness), emitted at most once per process.

    THE SINGLE ENTRY POINT FOR THE STALENESS SIGNAL, and it exists because that signal silently went
    missing. `snapshot_age_findings` used to be reachable ONLY from this module's `main()`, so the
    >180-day warning fired when a human ran the guard by hand and NEVER during an actual
    `preflight_config.py` run — the path the deploy runbook actually uses. The module advertised the
    check while the integrated path had none of it, which is the worst kind of gap: it reads as coverage.

    Emitted ONCE because the snapshot's age is a property of the FILE, not of any one chain, while the
    only integration point `preflight_config` offers is the per-chain `check_chain`. Per-chain emission
    would repeat one warning on every chain checked; emission on neither path is the bug being fixed.
    Both entry points now route through here, so the two paths cannot drift apart again.
    """
    global _SNAPSHOT_FINDINGS_EMITTED
    if _SNAPSHOT_FINDINGS_EMITTED:
        return []
    out = snapshot_age_findings(snap if snap is not None else load_snapshot())
    _SNAPSHOT_FINDINGS_EMITTED = True
    return out


def _measurement_age_days(measured) -> int | None:
    """Age in days of an allowlist entry's `measured` date, or None if it cannot be parsed."""
    from datetime import date
    try:
        y, m, d = (int(x) for x in str(measured).split("-"))
        return (date.today() - date(y, m, d)).days
    except Exception:  # noqa: BLE001 - an unparseable date is reported by the caller, not raised
        return None


def snapshot_age_findings(snap: dict) -> list[tuple[str, str]]:
    from datetime import date
    fetched = snap.get("fetched")
    if not fetched:
        return [(WARN, "snapshot has no `fetched` date; cannot judge staleness")]
    try:
        y, m, d = (int(x) for x in str(fetched).split("-"))
        age = (date.today() - date(y, m, d)).days
    except Exception:
        return [(WARN, f"snapshot `fetched` is unparseable: {fetched!r}")]
    if age > SNAPSHOT_STALE_DAYS:
        return [(WARN, f"declared-heartbeat snapshot is {age} days old (>{SNAPSHOT_STALE_DAYS}). Chainlink can "
                       f"re-tune a feed's heartbeat; run --refresh so the comparison means something.")]
    return []


def _fetch_directory(fn: str) -> list:
    """Fetch one reference-data-directory file. A seam, so --self-test can drive refresh()'s failure
    paths without a network and without monkeypatching urllib globally."""
    import urllib.request
    with urllib.request.urlopen(DIRECTORY_BASE + fn, timeout=120) as resp:
        return json.load(resp)


def refresh(allow_shrink: bool = False, fetch=None) -> int:
    """Re-fetch declared heartbeats for every address config references. Needs network.

    INTEGRITY RULE: this writes ONLY a snapshot it fully fetched. If any chain's fetch fails, or if an
    address that WAS resolvable and is STILL referenced by config no longer resolves, the committed file
    is left UNTOUCHED and this returns non-zero.

    That rule is not defensive programming for its own sake — both alternatives silently defeat the
    staleness guard this module advertises, and both were measured:

      * Stamping `fetched` with today's date after a failed fetch RE-CERTIFIES months-old data as fresh.
        Measured: with every fetch failing, a snapshot 1293 days old came back reporting ZERO staleness
        findings and exit 0. The >180-day warning is then permanently silenced on data nobody re-fetched.
      * Dropping a chain whose fetch SUCCEEDED but matched nothing — one renamed catalogue field is
        enough — deletes the comparison basis outright. Measured: all 68 feeds silently discarded, exit 0.
        The resulting "no declared heartbeat recorded" WARNs are indistinguishable from the ones this
        module documents as expected for RedStone/API3, so total loss of coverage reads as normal.

    An exit code of 0 from this function therefore means "the committed snapshot is complete and freshly
    fetched" and nothing else. allow_shrink=True (CLI: --allow-shrink) waives a genuine DELISTING — an
    address the provider dropped — but never a fetch failure, because no flag can make data that was
    never fetched fresh.
    """
    from datetime import date
    fetch = fetch or _fetch_directory
    prev_snap = load_snapshot() if SNAPSHOT.exists() else {}
    prev_chains = prev_snap.get("chains") or {}
    out = {"$comment": prev_snap.get("$comment", ""), "source": DIRECTORY_BASE,
           "fetched": date.today().isoformat(), "chains": {}}
    total = 0
    failures: list[tuple[str, str]] = []          # could not fetch at all
    carried: list[tuple[str, str]] = []           # entries in `out` that were NOT fetched this run
    regressions: list[tuple[str, list[str]]] = []  # addresses that stopped resolving / stopped being used
    for chain_id, fn in DIRECTORY_FILES.items():
        prev_ent = prev_chains.get(chain_id) or {}
        try:
            rows = registered_feeds(chain_id)
        except Exception as e:  # noqa: BLE001 - matches findings(); an unenumerable chain is not an empty one
            rows = [{"address": "-", "config_error": repr(e)}]
        # A config-error row carries a FILENAME in `address`, not a feed address. It must never reach
        # `refs` — and more importantly, a chain whose config cannot be read has an UNKNOWN reference set,
        # so refresh cannot tell a genuine delisting from an unreadable file. That is a non-waivable
        # failure, not a shrink: guessing here would delete entries that are still referenced.
        rows = [r for r in rows                                        # neither has an address to fetch
                if not r.get("unpaired_heartbeat") and not r.get("no_address")]
        cfg_errs = [r for r in rows if r.get("config_error")]
        if cfg_errs:
            failures.append((chain_id, f"config unreadable ({cfg_errs[0]['config_error']}) — the set of "
                                       f"referenced addresses is unknown"))
            if prev_ent:
                out["chains"][chain_id] = prev_ent
                total += len(prev_ent)
                carried.append((chain_id, "config unreadable"))
            continue
        refs = {str(r["address"]).lower() for r in rows}
        if not refs:
            # Config references nothing on this chain. Dropping its block is a legitimate, config-driven
            # shrink — but never a SILENT one: it is a deletion of committed data, so it needs the same
            # explicit acceptance as any other shrink.
            if prev_ent:
                regressions.append((chain_id, sorted(prev_ent)))
            continue
        try:
            cat = fetch(fn)
        except Exception as e:  # noqa: BLE001 - a fetch failure must not look like "no feeds"
            failures.append((chain_id, repr(e)))
            print(f"  chain {chain_id}: FETCH FAILED ({e}) — keeping any existing entries", file=sys.stderr)
            if prev_ent:
                out["chains"][chain_id] = prev_ent
                total += len(prev_ent)
                carried.append((chain_id, "fetch failed"))
            continue
        idx: dict[str, dict] = {}
        for rec in cat:
            # `secondaryProxyAddress` too: Chainlink lists some STANDARD feeds only there (Base BTC/USD
            # 0x64c9…848F, whose `proxyAddress` slot holds an SVR variant). `setdefault` keeps a primary
            # `proxyAddress` match first if an address ever appears in both roles.
            for k in ("proxyAddress", "contractAddress", "secondaryProxyAddress"):
                a = rec.get(k)
                if isinstance(a, str):
                    idx.setdefault(a.lower(), rec)
        ent = {}
        for a in sorted(refs):
            rec = idx.get(a)
            if rec is None:
                # Fall back to a recorded alias before concluding "not a Chainlink feed". Without this a
                # catalogue-key change silently converts a checkable feed into an unverifiable one.
                al = PROXY_ALIASES.get((chain_id, a))
                if al:
                    rec = idx.get(al["catalogued"])
            hb = rec.get("heartbeat") if rec else None
            # 0 is RECORDED, not dropped. A deviation-only feed genuinely declares no heartbeat cadence,
            # and `rh > 0` then makes the margin rule silent for it — the correct outcome. Dropping it
            # would instead report a catalogued Chainlink feed as "not a Chainlink feed", which is false.
            if isinstance(hb, (int, float)) and not isinstance(hb, bool):
                ent[a] = {"name": rec.get("name"), "declaredHeartbeat": int(hb),
                          "threshold": rec.get("threshold"), "feedCategory": rec.get("feedCategory")}
        # A REGRESSION is an address that resolved before, is STILL referenced by config, and resolves no
        # more. An address the config simply stopped referencing is a legitimate shrink, not a regression
        # — which is why this is keyed on `refs` and not on a bare count comparison.
        regressed = sorted(a for a in refs if a in prev_ent and a not in ent)
        if regressed:
            regressions.append((chain_id, regressed))
        if ent:
            out["chains"][chain_id] = ent
            total += len(ent)
        elif prev_ent:
            # Fetch succeeded, nothing matched (e.g. a renamed catalogue field). Keep the previous block
            # rather than deleting the chain's whole comparison basis — but mark it CARRIED, because it
            # was not fetched this run and must not be stamped with today's date.
            out["chains"][chain_id] = prev_ent
            total += len(prev_ent)
            carried.append((chain_id, "fetch matched no referenced address"))
        print(f"  chain {chain_id}: {len(ent)} of {len(refs)} referenced addresses have a declared heartbeat")

    # A chain the previous snapshot covers but DIRECTORY_FILES does not is never visited by the loop
    # above, so it would be dropped by a SUCCESSFUL refresh — same silent data loss as the empty-`ent`
    # case, reached by a different route, and invisible to the regression check because the chain is
    # never compared at all. Carry it forward if config still references it, and treat "cannot be
    # refreshed" as a failure: leaving it in under a today `fetched` stamp would re-certify data this
    # run never fetched. If config no longer references it, dropping it is a legitimate shrink.
    for cid in sorted(set(prev_chains) - set(DIRECTORY_FILES), key=str):
        try:
            _still_referenced = bool(registered_feeds(cid))
        except Exception:  # noqa: BLE001 - same containment the main loop uses; unknown != unreferenced
            _still_referenced = True   # cannot tell -> keep the data and block, never delete on a guess
        if _still_referenced:
            out["chains"][cid] = prev_chains[cid]
            total += len(prev_chains[cid])
            carried.append((cid, "no DIRECTORY_FILES entry — cannot be refreshed; add one"))
        elif prev_chains[cid]:
            regressions.append((cid, sorted(prev_chains[cid])))

    # THE RULE, stated once: `out` may contain ONLY entries fetched in this run. Anything CARRIED forward
    # was not, so stamping it with today's date would re-certify unfetched data — the laundering this
    # function exists to prevent. Failures and carries therefore always block and are NOT waivable; no
    # flag can make unfetched data fresh. `allow_shrink` waives only a SHRINK — addresses that genuinely
    # stopped resolving or stopped being referenced — which is a real editorial decision, not a lie
    # about freshness.
    if failures or carried or (regressions and not allow_shrink):
        print("\nREFUSING TO WRITE — the snapshot would be degraded, and a degraded snapshot stamped with "
              "today's date silently defeats the staleness guard:", file=sys.stderr)
        for cid, err in failures:
            print(f"  chain {cid}: fetch FAILED — {err}", file=sys.stderr)
        for cid, why in carried:
            print(f"  chain {cid}: entries would be CARRIED FORWARD unfetched ({why})", file=sys.stderr)
        for cid, addrs in regressions:
            shown = ", ".join(a[:10] + "…" for a in addrs[:5]) + (" …" if len(addrs) > 5 else "")
            print(f"  chain {cid}: {len(addrs)} address(es) would be dropped — {shown}", file=sys.stderr)
        print(f"\n{SNAPSHOT.name} left UNCHANGED, so its `fetched` date stays honest and staleness keeps "
              f"firing.", file=sys.stderr)
        if failures or carried:
            print("--allow-shrink does NOT bypass this: data that was never fetched cannot be stamped "
                  "fresh. Re-run when every source is reachable and the catalogue still matches.",
                  file=sys.stderr)
        else:
            print("Pass --allow-shrink to accept this as a genuine delisting.", file=sys.stderr)
        return 1

    if regressions:
        # Waived, not invisible. This is the only place that names WHICH addresses are being dropped, and
        # skipping it because the operator passed a flag would make --allow-shrink a silent delete.
        print("\n--allow-shrink: accepting these drops as genuine delistings:", file=sys.stderr)
        for cid, addrs in regressions:
            print(f"  chain {cid}: dropping {len(addrs)} address(es) — {', '.join(addrs)}", file=sys.stderr)
    SNAPSHOT.write_text(json.dumps(out, indent=2) + "\n")
    print(f"wrote {SNAPSHOT} ({total} feeds)")
    return 0


def self_test() -> int:
    """Prove each severity arm fires on synthetic input, then AUDIT the real allowlist against the real
    snapshot (read-only), then re-assert the signal-integrity properties found missing in review."""
    import contextlib
    import io
    import tempfile
    from datetime import date

    # Declared once, up front: several arms below rebind these module globals to drive synthetic input,
    # and Python requires the declaration to precede any use within this scope.
    global registered_feeds, REPO, SNAPSHOT

    ok = True

    def case(label, chain, snap, feeds, want_level, want_sub):
        nonlocal ok
        global registered_feeds
        orig = registered_feeds
        registered_feeds = lambda cid: feeds  # noqa: E731
        try:
            got = findings(chain, snap)
        finally:
            registered_feeds = orig
        hit = [m for lvl, m in got if lvl == want_level and want_sub in m]
        status = "PASS" if hit else "FAIL"
        if not hit:
            ok = False
        print(f"  [{status}] {label}")
        return got

    snap = {"fetched": "2026-07-31", "chains": {"1": {
        "0xaaa0000000000000000000000000000000000001": {"name": "T / USD", "declaredHeartbeat": 86400},
    }}}
    A = "0xAAA0000000000000000000000000000000000001"

    def case_silent(label, chain, snap, feeds):
        """Assert NOTHING is reported — the positive-margin arm must be quiet, not merely non-ERROR."""
        nonlocal ok
        global registered_feeds
        orig = registered_feeds
        registered_feeds = lambda cid: feeds  # noqa: E731
        try:
            got = findings(chain, snap)
        finally:
            registered_feeds = orig
        status = "PASS" if not got else "FAIL"
        if got:
            ok = False
        print(f"  [{status}] {label}" + ("" if not got else f" (unexpected: {got})"))

    # ADR 0025 INVERTED THESE FOUR. Under the old margin rule, above-declared was silent and equal was a
    # WARN candidate; under equality it is exactly the other way round. They are kept rather than deleted
    # because the inversion is the whole point of the rule change, and a rule with no test that it points
    # the RIGHT WAY is how the guard silently stopped enforcing anything (it did: an early `if rh > dh:
    # return []` made the equality check unreachable, and DAI at 7200 against a declared 3600 produced
    # zero findings until it was removed).
    case_silent("equality is SILENT", "1", snap,
                [{"asset": "T", "role": "priceFeeds[0]", "address": A, "heartbeat": 86400, "where": "x"}])
    case("ABOVE declared is an ERROR (the false-fresh window)", "1", snap,
         [{"asset": "T", "role": "priceFeeds[0]", "address": A, "heartbeat": 90000, "where": "x"}],
         ERROR, "ABOVE declared")
    case("BELOW declared is an ERROR (manufactured staleness)", "1", snap,
         [{"asset": "T", "role": "priceFeeds[0]", "address": A, "heartbeat": 3600, "where": "x"}],
         ERROR, "BELOW declared")
    # ADR 0029: a primary at or above the 7-day stale cap would go from fresh straight to unusable. Driven
    # through a SYNTHETIC nav-config (not a stubbed registered_feeds), because the cap must also reach the named
    # `Custom` primaries that registered_feeds deliberately omits — an earlier version checked only enumerated
    # rows and so missed every named custom-feed primary. Must NOT fire for a monitor, for the
    # `type(uint256).max` sentinel, or just below the cap.
    _real_repo_cap = REPO
    _cap_cfg = {
        "ADDR": {"priceFeeds": [{"address": "0xBBB0000000000000000000000000000000000002", "type": "Chainlink",
                                 "heartbeat": 604800}]},
        "NAMED": {"priceFeeds": [{"type": "Custom", "feed": "wstETH", "heartbeat": 604800}]},
        "STR": {"priceFeeds": [{"type": "Custom", "feed": "x", "heartbeat": "700000"}]},
        "MON": {"priceFeeds": [{"type": "Custom", "feed": "y", "heartbeat": 86400}],
                "monitorFeeds": [{"address": "0xBBB0000000000000000000000000000000000003", "type": "Chainlink",
                                  "heartbeat": 604800}]},
        "MAX": {"priceFeeds": [{"type": "Custom", "feed": "z", "heartbeat": 2**256 - 1}]},
        "BELOW": {"priceFeeds": [{"type": "Custom", "feed": "w", "heartbeat": 604799}]},
        "HEX": {"priceFeeds": [{"type": "Custom", "feed": "h", "heartbeat": "0x93a80"}]},
        "JUNK": {"priceFeeds": [{"type": "Custom", "feed": "j", "heartbeat": "7d"}]},
        "ZEROS": {"priceFeeds": [{"type": "Custom", "feed": "k", "heartbeat": "0700000"}]},
        "NEG": {"priceFeeds": [{"type": "Custom", "feed": "n", "heartbeat": "-1"}]},
        "NULL": {"priceFeeds": [{"type": "Custom", "feed": "u", "heartbeat": None}]},
        "ADDRJUNK": {"priceFeeds": [{"address": "0xBBB0000000000000000000000000000000000004",
                                     "type": "Chainlink", "heartbeat": "7d"}]},
        "$comment": "top-level note keys are skipped",
    }
    with tempfile.TemporaryDirectory() as _tdc:
        _dc = Path(_tdc) / "script/config/nav-config/assets-and-price-feeds"
        _dc.mkdir(parents=True)
        (_dc / "1.json").write_text(json.dumps(_cap_cfg))
        REPO = Path(_tdc)
        try:
            _cap_all = stale_cap_findings("1")
            _cap = [m for lvl, m in _cap_all if lvl == ERROR]
            _cap_warn = [m for lvl, m in _cap_all if lvl == WARN]
            _via_findings = [m for lvl, m in findings("1", snap) if lvl == ERROR and "MAX_STALE_PRICE_AGE" in m]
        finally:
            REPO = _real_repo_cap
    for label, want, sym in (
        ("an ADDRESSED primary at the 7-day cap is an ERROR (ADR 0029)", True, "'ADDR'"),
        ("a NAMED Custom primary at the cap is an ERROR (not skipped like the declared axis)", True, "'NAMED'"),
        ("a string-valued heartbeat above the cap is still caught", True, "'STR'"),
        ("a MONITOR at the cap is not a cap ERROR", False, "'MON'"),
        ("a uint256.max primary is exempt from the cap", False, "'MAX'"),
        ("a primary just below the cap is not a cap ERROR", False, "'BELOW'"),
        ("a hex-string heartbeat (0x93a80 = 604800) is caught like the deploy path parses it", True, "'HEX'"),
        ("a leading-zero decimal string (\"0700000\") is caught like vm.parseUint reads it", True, "'ZEROS'"),
    ):
        hit = any(f"asset {sym}" in m for m in _cap)
        good = hit == want
        ok = ok and good
        print(f"  [{'PASS' if good else 'FAIL'}] {label}")
    _junk = (sum("asset 'JUNK'" in m for m in _cap_warn) == 1 and sum("asset 'NEG'" in m for m in _cap_warn) == 1
             and sum("asset 'NULL'" in m for m in _cap_warn) == 1
             and not any("asset 'ADDRJUNK'" in m for m in _cap_warn))
    ok = ok and _junk
    print(f"  [{'PASS' if _junk else 'FAIL'}] an unparseable, negative or null named-Custom heartbeat is ONE cap WARN; "
          f"an addressed one is left to the existing row WARN (no double report)")
    _wired = len(_via_findings) == 5
    ok = ok and _wired
    print(f"  [{'PASS' if _wired else 'FAIL'}] findings() reports the cap verdicts exactly once each "
          f"(got {len(_via_findings)}, want 5)")
    # The hint used to advertise an allowlist entry as a second way to satisfy this finding. It is not:
    # an exemption answers the cadence question and does not waive equality, and the allowlist branch
    # ERRORs on a non-equal registration. The hint must say so rather than point at the silencing edit.
    case("the fix hint offers no exemption escape", "1", snap,
         [{"asset": "T", "role": "priceFeeds[0]", "address": A, "heartbeat": 90000, "where": "x"}],
         ERROR, "THERE IS NO SECOND EXIT")
    # unknown address -> WARN, not silent pass
    case("unrecorded address warns", "1", snap,
         [{"asset": "Z", "role": "priceFeeds[0]", "address": "0xdead00000000000000000000000000000000beef",
           "heartbeat": 10, "where": "x"}],
         WARN, "NO declared heartbeat")
    # These arms mutate the module-global ALLOWLIST, so they are wrapped: an arm that raises must not
    # leave a synthetic exemption behind to corrupt every arm after it (and the real-config audit below).
    key = ("1", A.lower())
    try:
        # THE MEASURED-FINE PATH MUST BE SILENT. This is the arm the entire severity design rests on —
        # an evidenced exemption is the only way a zero-margin feed is allowed to report nothing — and
        # nothing asserted it. If this ever regressed to a WARN, the allowlist would stop exempting and
        # the guard would cry wolf on six measured feeds; if it regressed the other way, a broken
        # exemption would go quiet. Both directions are covered by this arm plus the two ERROR arms.
        ALLOWLIST[key] = {"asset": "T", "registered": 86400, "breaches": 0, "intervals": 300,
                          "measured": date.today().isoformat()}
        case_silent("an EVIDENCED allowlist entry is SILENT (the measured-fine path)", "1", snap,
                    [{"asset": "T", "role": "priceFeeds[0]", "address": A, "heartbeat": 86400,
                      "where": "x"}])
        # allowlist with a breach is itself an error
        ALLOWLIST[key] = {"asset": "T", "registered": 86400, "breaches": 3, "measured": "2026-01-01"}
        case("allowlist entry WITH breaches errors", "1", snap,
             [{"asset": "T", "role": "priceFeeds[0]", "address": A, "heartbeat": 86400, "where": "x"}],
             ERROR, "must record 0 breaches")
        # allowlist measured against a different registered value is stale
        ALLOWLIST[key] = {"asset": "T", "registered": 82800, "breaches": 0, "measured": "2026-01-01"}
        case("stale allowlist (registered changed) errors", "1", snap,
             [{"asset": "T", "role": "priceFeeds[0]", "address": A, "heartbeat": 86400, "where": "x"}],
             ERROR, "stale exemption is not evidence")
    finally:
        ALLOWLIST.pop(key, None)

    # AUDIT of the real config (read-only — it mutates nothing): every real allowlist entry must currently
    # be at-or-below margin, otherwise the exemption is dead weight hiding nothing and should be deleted.
    real = load_snapshot()
    for (cid, addr), ev in ALLOWLIST.items():
        rec = (real.get("chains") or {}).get(cid, {}).get(addr)
        if not rec:
            print(f"  [WARN] allowlist ({cid},{addr[:10]}…) has no snapshot entry — cannot audit")
            continue
        reg = ev.get("registered")
        if reg is None:
            # Must FAIL, not print a reassuring PASS: `findings` already ERRORs on such an entry
            # (`allow.get("registered") != rh`), so a PASS here would be a vacuous arm contradicting the
            # implementation — the audit would bless exactly the entry the guard refuses to honour.
            print(f"  [FAIL] allowlist ({cid},{addr[:10]}…) records no `registered` value, so it cannot be "
                  f"audited and findings() will ERROR on it. Record the measured heartbeat.")
            ok = False
        elif reg > int(rec["declaredHeartbeat"]):
            print(f"  [WARN] allowlist ({cid},{addr[:10]}…) is unnecessary: registered {reg} already exceeds "
                  f"declared {rec['declaredHeartbeat']}. Delete the entry.")
        else:
            print(f"  [PASS] allowlist ({cid},{addr[:10]}…) {ev.get('asset')} genuinely needs the exemption "
                  f"(registered {reg} <= declared {rec['declaredHeartbeat']}), evidence "
                  f"{ev.get('breaches')} breaches / {ev.get('intervals')} intervals, measured {ev.get('measured')}")
            age = _measurement_age_days(ev.get("measured"))
            if age is None:
                print(f"  [WARN] allowlist ({cid},{addr[:10]}…) has an unparseable `measured` date "
                      f"({ev.get('measured')!r}) — the evidence cannot be aged.")
            elif age > MEASUREMENT_STALE_DAYS:
                print(f"  [WARN] allowlist ({cid},{addr[:10]}…) evidence is {age} days old "
                      f"(>{MEASUREMENT_STALE_DAYS}). Publisher cadence drifts; re-measure before "
                      f"continuing to rely on this exemption.")

    # ----------------------------------------------------------------------------------------------
    # REGRESSION ARMS for the defects found reviewing this PR. Each was verified to FAIL against the
    # code as originally written — an arm that passes both with and without its fix asserts nothing.
    # ----------------------------------------------------------------------------------------------
    print("  --- signal-integrity arms ---")

    # The staleness signal must reach the INTEGRATED path, not just this module's main().
    _reset_snapshot_findings_once()
    ancient = {"fetched": "2000-01-01", "chains": {}}
    st = snapshot_findings_once(ancient)
    hit = [m for lvl, m in st if "days old" in m]
    print(f"  [{'PASS' if hit else 'FAIL'}] staleness surfaces through snapshot_findings_once "
          f"(the entry point preflight_config uses)")
    ok = ok and bool(hit)
    # ...and exactly once per process, so a multi-chain run does not repeat it on every chain.
    second = snapshot_findings_once(ancient)
    print(f"  [{'PASS' if not second else 'FAIL'}] staleness is emitted once, not once per chain")
    ok = ok and not second
    _reset_snapshot_findings_once()

    # One malformed row must not destroy the other rows' verdicts — least of all a deploy-blocking ERROR.
    BAD = "0xBBB0000000000000000000000000000000000002"
    bad_snap = {"fetched": "2026-07-31", "chains": {"1": {
        A.lower(): {"name": "T / USD", "declaredHeartbeat": 86400},
        BAD.lower(): {"name": "BAD / USD"},          # no declaredHeartbeat -> KeyError on this row only
    }}}
    rows = [{"asset": "T", "role": "priceFeeds[0]", "address": A, "heartbeat": 86400, "where": "x"},
            {"asset": "BAD", "role": "priceFeeds[0]", "address": BAD, "heartbeat": 86400, "where": "x"}]
    try:
        ALLOWLIST[key] = {"asset": "T", "registered": 82800, "breaches": 0, "measured": "2026-01-01"}
        got = case("a malformed row does NOT discard a real ERROR on another row", "1", bad_snap, rows,
                   ERROR, "stale exemption is not evidence")
    finally:
        ALLOWLIST.pop(key, None)
    n_mal = len([m for lvl, m in got if lvl == ERROR and "could NOT evaluate" in m])
    print(f"  [{'PASS' if n_mal == 1 else 'FAIL'}] ...and the malformed row is itself reported as an ERROR")
    ok = ok and n_mal == 1

    # A config row whose `heartbeat` is not a usable int must be REPORTED, never silently dropped —
    # otherwise an unchecked feed is indistinguishable from a checked-and-clean one. Driven against a
    # synthetic config tree (tempdir) because the real config contains zero such rows, so an arm reading
    # the committed config would pass whether or not the fix is present.
    _real_repo = REPO
    with tempfile.TemporaryDirectory() as _td:
        _d = Path(_td) / "script/config/nav-config/assets-and-price-feeds"
        _d.mkdir(parents=True)
        # A numeric STRING ("86400") is coerced on purpose — the intent is unambiguous and checking it
        # beats dropping it. The unusable cases are a missing or non-numeric value, like this one.
        (_d / "1.json").write_text(json.dumps({"T": {"priceFeeds": [{"address": A}]}}))
        REPO = Path(_td)
        try:
            _rows = registered_feeds("1")
            _got = findings("1", snap)
        finally:
            REPO = _real_repo
    _reported = [m for lvl, m in _got if "NO usable integer" in m]
    print(f"  [{'PASS' if _rows and _reported else 'FAIL'}] a non-int `heartbeat` in config is REPORTED, "
          f"not silently skipped")
    ok = ok and bool(_rows) and bool(_reported)

    # Rate legs must be found BY SHAPE. Hard-coding `yToXFeed` missed nine enabled custom feeds whose
    # leg is named for the pair it prices, so the guard read as covering custom feeds while checking a
    # third of them.
    _legs = [r for cid in configured_chain_ids() for r in registered_feeds(cid)
             if "rate leg" in r.get("role", "")]
    _non_ytox = [r for r in _legs if "yToX" not in r["role"] and r.get("address", "-").startswith("0x")]
    print(f"  [{'PASS' if len(_non_ytox) >= 9 else 'FAIL'}] custom-feed rate legs are discovered by shape "
          f"({len(_legs)} legs, {len(_non_ytox)} of them NOT the yToXFeed spelling)")
    ok = ok and len(_non_ytox) >= 9

    # A nav-config `type: Custom` entry names its feed instead of carrying an address, and is covered
    # via that feed's rate leg. It must stay SILENT here. A draft of the no-address check flagged all 41
    # of them — cry-wolf on correct config, which is the failure this module's severity ladder exists to
    # avoid — so this arm pins both halves: named-custom silent, genuinely address-less reported.
    with tempfile.TemporaryDirectory() as _td5:
        _d5 = Path(_td5) / "script/config/nav-config/assets-and-price-feeds"
        _d5.mkdir(parents=True)
        (_d5 / "1.json").write_text(json.dumps({
            "NamedCustom": {"priceFeeds": [{"type": "Custom", "feed": "wstETH", "heartbeat": 86400}]},
            "Headless": {"priceFeeds": [{"type": "Chainlink", "heartbeat": 86400}]},
        }))
        REPO = Path(_td5)
        try:
            _na = findings("1", {"fetched": "2026-08-01", "chains": {"1": {}}})
        finally:
            REPO = _real_repo
    _named = [m for lvl, m in _na if "NamedCustom" in m]
    _headless = [m for lvl, m in _na if "Headless" in m and "nothing to look up" in m]
    print(f"  [{'PASS' if not _named and _headless else 'FAIL'}] a `type: Custom` entry naming its feed "
          f"is SILENT (covered via its rate leg); an address-less non-custom entry is reported")
    ok = ok and not _named and bool(_headless)

    # THE COVERAGE INVARIANT: enumerated rows + explicit exemptions == configured entries, per chain.
    # This is the single check that would have caught every silent-coverage defect this module has had —
    # the nine rate legs missed by a hard-coded key, the non-int-heartbeat drop, the non-dict-entry drop,
    # `if not refs: continue`, and a top-level `[]` config reading as zero feeds. Anything that vanishes
    # between config and enumeration shows up here as an inequality, whatever the mechanism.
    _cov_bad = []
    for _cid in configured_chain_ids():
        _c = coverage_census(_cid)
        _n = len(registered_feeds(_cid))
        if _n != _c["expectedRows"]:
            _cov_bad.append(f"chain {_cid}: enumerated {_n} != expected {_c['expectedRows']} "
                            f"({_c['navEntries']} configured - {_c['exemptNamedCustom']} exempt "
                            f"+ {_c['legKeys']} legs)")
    print(f"  [{'PASS' if not _cov_bad else 'FAIL'}] COVERAGE INVARIANT: every configured feed entry is "
          f"either enumerated or explicitly exempt, on all {len(configured_chain_ids())} chains")
    for _b in _cov_bad:
        print(f"           {_b}")
    ok = ok and not _cov_bad

    # ...and again over a SYNTHETIC tree that contains the shapes the committed config happens not to
    # have. Run only against the real tree, this invariant is bounded by what that tree exercises: a
    # mutation re-introducing the non-int-heartbeat drop passes, because there are zero such rows today.
    # The dimension has to be present in the input before a check can be sensitive to it — the same
    # under-dimensioned-input trap that let two wrong staleness placements look proved.
    with tempfile.TemporaryDirectory() as _td6:
        _n6 = Path(_td6) / "script/config/nav-config/assets-and-price-feeds"
        _n6.mkdir(parents=True)
        (_n6 / "1.json").write_text(json.dumps({
            "IntHb": {"priceFeeds": [{"address": "0x" + "aa" * 20, "heartbeat": 3600}]},
            "StrHb": {"priceFeeds": [{"address": "0x" + "bb" * 20, "heartbeat": "3600"}]},
            "NoHb": {"priceFeeds": [{"address": "0x" + "cc" * 20}]},
            "NotDict": {"priceFeeds": ["nonsense"]},
            "NamedCustom": {"priceFeeds": [{"type": "Custom", "feed": "x", "heartbeat": 86400}]},
            # An address-less entry that is NOT a named custom feed. Absent from both trees, the branch
            # that reports it could be disabled with this invariant still green — found by the
            # branch-space mutation matrix, and the same blind spot R2 named, one branch over.
            "Headless": {"priceFeeds": [{"type": "Chainlink", "heartbeat": 86400}]},
        }))
        _d6 = Path(_td6) / "script/config/contracts-deployment-config/custom-price-feeds"
        _d6.mkdir(parents=True)
        (_d6 / "1.json").write_text(json.dumps({
            "x": {"enabled": True, "constructor": {"aToBChainlink": "0x" + "dd" * 20,
                                                   "aToBHeartbeat": 3600}},
            # A rate leg with an ADDRESS and NO `*Heartbeat` key at all. This shape exists in no committed
            # config, so without it here the census's `or` fallback never evaluates and the enumerator
            # branch handling it — the one whose comment calls it "the silent drop this module exists to
            # prevent" — is invisible to every arm. Disabling that branch used to leave the suite green.
            # The invariant could not see the exact thing it was added to see, for want of one fixture.
            "legNoHeartbeat": {"enabled": True,
                               "constructor": {"yToXFeed": "0x" + "ee" * 20}},
            # ...and the same shape with a non-address `yToXFeed`, which must NOT be counted as a leg.
            "legBadAddress": {"enabled": True, "constructor": {"yToXFeed": "not-an-address"}}}))
        REPO = Path(_td6)
        try:
            _sc = coverage_census("1")
            _sn = len(registered_feeds("1"))
        finally:
            REPO = _real_repo
    _syn_ok = _sn == _sc["expectedRows"]
    print(f"  [{'PASS' if _syn_ok else 'FAIL'}] ...and over a synthetic tree carrying the shapes the real "
          f"config lacks (non-int heartbeat, missing heartbeat, non-dict entry): "
          f"{_sn} enumerated == {_sc['expectedRows']} expected")
    ok = ok and _syn_ok

    # The pairing heuristic must never GUESS an address. A bare "Heartbeat" key has an empty stem and
    # would prefix-match everything; two plausible siblings are ambiguous. Both must be reported, because
    # a confident verdict about the wrong feed is worse than admitting the shape was not recognised.
    with tempfile.TemporaryDirectory() as _td4:
        _d4 = Path(_td4) / "script/config/contracts-deployment-config/custom-price-feeds"
        _d4.mkdir(parents=True)
        (_d4 / "1.json").write_text(json.dumps({
            "BareKey": {"enabled": True,
                        "constructor": {"Heartbeat": 3600, "unrelated": "0x" + "55" * 20}},
            "Ambiguous": {"enabled": True,
                          "constructor": {"pToQAlpha": "0x" + "66" * 20, "pToQBeta": "0x" + "77" * 20,
                                          "pToQHeartbeat": 3600}},
        }))
        REPO = Path(_td4)
        try:
            _pair = registered_feeds("1")
        finally:
            REPO = _real_repo
    _guessed = [r for r in _pair if not r.get("unpaired_heartbeat") and r.get("address", "-") != "-"]
    print(f"  [{'PASS' if len(_pair) == 2 and not _guessed else 'FAIL'}] the rate-leg pairing reports an "
          f"empty stem and an ambiguous match instead of guessing an address")
    ok = ok and len(_pair) == 2 and not _guessed

    # An allowlist entry must carry re-runnable evidence, and that evidence must not be allowed to age
    # forever. Both are checked on the DEPLOY path (findings), not only in this self-test — aging it only
    # here would repeat this module's original defect exactly.
    _A2 = "0xAAA0000000000000000000000000000000000001"
    _snap2 = {"fetched": "2026-08-01", "chains": {"1": {_A2.lower(): {"name": "T / USD",
                                                                     "declaredHeartbeat": 86400}}}}
    _row = [{"asset": "T", "role": "priceFeeds[0]", "address": _A2, "heartbeat": 86400, "where": "x"}]
    try:
        ALLOWLIST[key] = {"asset": "T", "registered": 86400, "breaches": 0}          # no evidence at all
        case("an allowlist entry with NO measurement is an ERROR", "1", _snap2, _row,
             ERROR, "not evidence")
        ALLOWLIST[key] = {"asset": "T", "registered": 86400, "breaches": 0, "intervals": 300,
                          "measured": "2019-01-01"}                                  # ancient evidence
        case("an allowlist entry whose evidence is stale WARNS on the deploy path", "1", _snap2, _row,
             WARN, "days old")
    finally:
        ALLOWLIST.pop(key, None)

    # A provider-declared heartbeat of 0 means "no cadence". Silence would be indistinguishable from a
    # verified positive margin, so it must say which it is.
    case("a declared heartbeat of 0 is reported, not silent", "1",
         {"fetched": "2026-08-01", "chains": {"1": {_A2.lower(): {"name": "D / USD",
                                                                 "declaredHeartbeat": 0}}}},
         [{"asset": "D", "role": "priceFeeds[0]", "address": _A2, "heartbeat": 3600, "where": "x"}],
         WARN, "deviation-only feed with no heartbeat cadence")

    # A monitor feed does not price the asset, so it must not be told it will be valued $0 or flagged stale.
    # The heartbeat must DIFFER from declared for a finding to exist at all under the equality rule;
    # at 86400 == declared this row is silent and the assertion would pass vacuously.
    _mon = case("a monitorFeeds row states the MONITOR consequence, not the $0 one", "1", _snap2,
                [{"asset": "T", "role": "monitorFeeds[0]", "address": _A2, "heartbeat": 90000,
                  "where": "x"}],
                ERROR, "does not touch the valuation")
    print(f"  [{'PASS' if not [m for lvl, m in _mon if 'valued $0' in m] else 'FAIL'}] "
          f"...and does NOT claim the asset is valued $0")
    ok = ok and not [m for lvl, m in _mon if "valued $0" in m]

    # An unparseable config file must be an ERROR, not zero rows. Zero rows reads exactly like "this
    # chain has no feeds", so a corrupt config would report a clean chain.
    with tempfile.TemporaryDirectory() as _td3:
        _d3 = Path(_td3) / "script/config/nav-config/assets-and-price-feeds"
        _d3.mkdir(parents=True)
        (_d3 / "1.json").write_text("{ not valid json ")
        REPO = Path(_td3)
        try:
            _bad_cfg = findings("1", {"fetched": "2026-08-01", "chains": {"1": {}}})
        finally:
            REPO = _real_repo
    _cfg_err = [m for lvl, m in _bad_cfg if lvl == ERROR and "could not be parsed" in m]
    print(f"  [{'PASS' if _cfg_err else 'FAIL'}] an unparseable config file is an ERROR, not a clean chain")
    ok = ok and bool(_cfg_err)

    # Enumeration is contained: if registered_feeds raises, the chain must report NO COVERAGE, not vanish
    # through preflight_config's fail-soft handler.
    _rf_real = registered_feeds
    registered_feeds = lambda cid: (_ for _ in ()).throw(TypeError("malformed config shape"))  # noqa: E731
    try:
        _enum = findings("1", {"fetched": "2026-08-01", "chains": {}})
    except Exception:
        _enum = []
    finally:
        registered_feeds = _rf_real
    _enum_err = [m for lvl, m in _enum if lvl == ERROR and "could NOT enumerate" in m]
    print(f"  [{'PASS' if _enum_err else 'FAIL'}] a chain that cannot be ENUMERATED reports an ERROR "
          f"instead of raising out of findings()")
    ok = ok and bool(_enum_err)

    # The run's scope must come from CONFIG, so a degraded snapshot cannot shrink what gets audited.
    # Driven against a SYNTHETIC config tree whose chain set differs from the real snapshot's, so the arm
    # actually distinguishes the two sources. (A previous version of this arm asserted only that
    # configured_chain_ids() was non-empty, which passed with or without the fix — it proved nothing.)
    with tempfile.TemporaryDirectory() as _td2:
        _d2 = Path(_td2) / "script/config/nav-config/assets-and-price-feeds"
        _d2.mkdir(parents=True)
        for _c in ("42", "43"):
            (_d2 / f"{_c}.json").write_text("{}")
        REPO = Path(_td2)
        try:
            _scope = configured_chain_ids()
        finally:
            REPO = _real_repo
    _snap_chains = sorted(load_snapshot().get("chains") or {}, key=int)
    _differs = _scope == ["42", "43"] and _scope != _snap_chains
    print(f"  [{'PASS' if _differs else 'FAIL'}] chain scope is derived from the CONFIG tree ({_scope}), "
          f"not from the snapshot's own keys ({len(_snap_chains)} chains)")
    ok = ok and _differs

    # refresh() must never leave a degraded snapshot behind, and must say so in its exit code.
    # The refresh arms below WRITE the snapshot. They are pointed at a throwaway COPY in a tempdir
    # rather than the committed file, so no failure path — not an assertion, not a crash, not a
    # concurrent second run of this self-test — can leave the tracked file modified.
    _real_snapshot = SNAPSHOT
    _snap_dir = tempfile.TemporaryDirectory()
    _tmp_snap = Path(_snap_dir.name) / _real_snapshot.name
    _tmp_snap.write_text(_real_snapshot.read_text())
    SNAPSHOT = _tmp_snap
    before = SNAPSHOT.read_text()
    try:
        def _boom(fn):
            raise OSError("simulated network failure")

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            rc_fail = refresh(fetch=_boom)
            unchanged_fail = SNAPSHOT.read_text() == before
            # 200 OK, valid JSON, plausible records — but the `heartbeat` field is gone (schema change).
            rc_empty = refresh(fetch=lambda fn: [{"proxyAddress": "0x" + "11" * 20, "name": "X / USD"}])
            unchanged_empty = SNAPSHOT.read_text() == before
        print(f"  [{'PASS' if rc_fail else 'FAIL'}] refresh() returns non-zero when every fetch fails")
        print(f"  [{'PASS' if unchanged_fail else 'FAIL'}] ...leaving the snapshot untouched, so `fetched` "
              f"stays honest and staleness keeps firing")
        print(f"  [{'PASS' if rc_empty else 'FAIL'}] refresh() returns non-zero on a 200-OK-but-unmatching "
              f"catalogue")
        print(f"  [{'PASS' if unchanged_empty else 'FAIL'}] ...rather than silently discarding every "
              f"recorded feed")
        ok = ok and bool(rc_fail) and unchanged_fail and bool(rc_empty) and unchanged_empty

        # A chain the snapshot covers, config STILL references, and DIRECTORY_FILES cannot reach must
        # not vanish on a SUCCESSFUL refresh. The per-chain loop never visits such a chain, so the
        # regression check above is blind to it — this arm is the only thing covering that route.
        planted = json.loads(before)
        unmapped_id = next((c for c in ("130", "8217", "324") if c not in DIRECTORY_FILES), "130")
        planted["chains"][unmapped_id] = {"0x" + "cc" * 20: {"name": "P / USD", "declaredHeartbeat": 3600}}
        planted_text = json.dumps(planted, indent=2) + "\n"
        SNAPSHOT.write_text(planted_text)

        _real_rf = registered_feeds

        def _rf(cid):
            if str(cid) == unmapped_id:  # pretend config references a feed on the unmapped chain
                return [{"asset": "P", "role": "priceFeeds[0]", "address": "0x" + "cc" * 20,
                         "heartbeat": 86400, "where": "x"}]
            return _real_rf(cid)

        def _full(fn):
            return [{"proxyAddress": str(x["address"]), "name": "Y / USD", "heartbeat": 86400}
                    for c in DIRECTORY_FILES for x in _real_rf(c)]

        registered_feeds = _rf
        try:
            with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
                rc_unmapped = refresh(fetch=_full)
        finally:
            registered_feeds = _real_rf
        kept = SNAPSHOT.read_text() == planted_text   # refusal => the planted file is left as-is
        SNAPSHOT.write_text(before)
        print(f"  [{'PASS' if rc_unmapped else 'FAIL'}] refresh() returns non-zero for a still-referenced "
              f"chain DIRECTORY_FILES cannot reach")
        print(f"  [{'PASS' if kept else 'FAIL'}] ...instead of silently dropping it from the snapshot")
        ok = ok and bool(rc_unmapped) and kept

        # --allow-shrink must waive a DELISTING, never a failed fetch. Forcing a failure through would
        # write carried-over entries under a today `fetched` stamp — the laundering, behind a flag.
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            rc_forced = refresh(allow_shrink=True, fetch=_boom)
            unchanged_forced = SNAPSHOT.read_text() == before
        print(f"  [{'PASS' if rc_forced else 'FAIL'}] --allow-shrink does NOT bypass a failed fetch")
        print(f"  [{'PASS' if unchanged_forced else 'FAIL'}] ...so stale data cannot be stamped fresh "
              f"behind a flag")
        ok = ok and bool(rc_forced) and unchanged_forced

        # ...nor via the CARRY-FORWARD route: a fetch that succeeds but matches nothing also leaves
        # unfetched entries in the output, and --allow-shrink must not stamp those fresh either.
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            rc_carry = refresh(allow_shrink=True,
                               fetch=lambda fn: [{"proxyAddress": "0x" + "11" * 20, "name": "X / USD"}])
            unchanged_carry = SNAPSHOT.read_text() == before
        print(f"  [{'PASS' if rc_carry and unchanged_carry else 'FAIL'}] --allow-shrink does NOT launder "
              f"carried-forward entries when a fetch matches nothing")
        ok = ok and bool(rc_carry) and unchanged_carry

        # An UNREADABLE config must block refresh outright. Its reference set is unknown, so treating it
        # as "references nothing" would delete entries that are still in use — and the synthetic
        # config-error row carries a FILENAME in `address`, which must never be mistaken for a feed.
        def _rf_badcfg(cid):
            if str(cid) == "137":
                return [{"asset": "(config)", "role": "file", "address": "137.json",
                         "heartbeat": None, "config_error": "not valid JSON: simulated", "where": "x"}]
            return _real_rf(cid)

        registered_feeds = _rf_badcfg
        # A FRESH buffer, and the assertion is on the REASON, not merely on the exit code. Blocking for
        # some other reason would let this arm pass while the filename still leaked into `refs` — which
        # is exactly what happened to the first draft of this arm.
        cfgbuf = io.StringIO()
        try:
            with contextlib.redirect_stdout(cfgbuf), contextlib.redirect_stderr(cfgbuf):
                rc_badcfg = refresh(fetch=_full)
                unchanged_badcfg = SNAPSHOT.read_text() == before
        finally:
            registered_feeds = _real_rf
        said_why = "config unreadable" in cfgbuf.getvalue()
        leaked = "137.json" in cfgbuf.getvalue().replace("config unreadable", "")
        good = bool(rc_badcfg) and unchanged_badcfg and said_why and not leaked
        print(f"  [{'PASS' if good else 'FAIL'}] an unreadable config blocks refresh() AS a config error "
              f"(not as 'references nothing'), and its filename never reaches the address set")
        ok = ok and good

        # A mapped chain whose config yields no addresses must not be deleted SILENTLY.
        def _rf_noref(cid):
            return [] if str(cid) == "137" else _real_rf(cid)

        registered_feeds = _rf_noref
        try:
            with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
                rc_noref = refresh(fetch=_full)
                unchanged_noref = SNAPSHOT.read_text() == before
        finally:
            registered_feeds = _real_rf
        print(f"  [{'PASS' if rc_noref and unchanged_noref else 'FAIL'}] a mapped chain whose config "
              f"yields no addresses is not deleted silently (needs --allow-shrink)")
        ok = ok and bool(rc_noref) and unchanged_noref

    finally:
        # Restore the module global no matter what, and drop the tempdir. The committed file was never
        # a write target, so there is nothing in the working tree to repair.
        SNAPSHOT = _real_snapshot
        _snap_dir.cleanup()
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("chains", nargs="*",
                    help="chain ids (default: every chain the config registers feeds for — NOT the snapshot's own chain list, so a degraded snapshot cannot shrink the audit)")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--refresh", action="store_true")
    ap.add_argument("--allow-shrink", action="store_true",
                    help="with --refresh: accept a snapshot that loses still-referenced addresses")
    ap.add_argument("--json", metavar="PATH")
    a = ap.parse_args()
    if a.refresh:
        return refresh(allow_shrink=a.allow_shrink)
    if a.self_test:
        return self_test()
    snap = load_snapshot()
    # Scope from CONFIG, never from the snapshot's own keys — see configured_chain_ids. A chain the
    # snapshot has no entry for still gets checked, and reports every feed as "no declared heartbeat"
    # rather than vanishing from the run. There is deliberately NO snapshot-derived fallback: falling
    # back would restore the exact behaviour this scope rule exists to prevent, and it would do so
    # precisely when the config tree is unreadable — i.e. when the guard is least trustworthy.
    ids = a.chains or configured_chain_ids()
    if not ids:
        print("ERROR: no chain config found under script/config/{nav-config/assets-and-price-feeds,"
              "contracts-deployment-config/custom-price-feeds}. Refusing to fall back to the snapshot's "
              "own chain list, which would let a degraded snapshot choose its own scope and report a "
              "clean verdict over whatever it still contains.", file=sys.stderr)
        return 1
    report, errors = {}, 0
    # Same entry point the integrated path uses, so the two cannot report different things. Exported to
    # --json as well: a consumer that only reads the JSON would otherwise miss staleness entirely, which
    # is the same "signal present on one path, absent on another" defect in a different disguise.
    snap_f = snapshot_findings_once(snap)
    report["snapshot"] = [{"level": l, "message": m} for l, m in snap_f]
    errors += sum(1 for l, _ in snap_f if l == ERROR)
    for lvl, msg in snap_f:
        print(f"  {lvl}: {msg}")
    for cid in ids:
        fs = findings(str(cid), snap)
        report[str(cid)] = [{"level": l, "message": m} for l, m in fs]
        errs = [m for l, m in fs if l == ERROR]
        errors += len(errs)
        print(f"\n=== chain {cid}: {len(errs)} ERROR, {len(fs) - len(errs)} WARN ===")
        for l, m in fs:
            print(f"  {l}: {m}")
    if a.json:
        Path(a.json).write_text(json.dumps(report, indent=2) + "\n")
    print(f"\ntotal ERRORs: {errors}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
