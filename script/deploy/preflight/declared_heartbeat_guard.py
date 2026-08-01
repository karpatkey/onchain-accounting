#!/usr/bin/env python3
"""The DECLARED-heartbeat margin guard: registered heartbeat must EXCEED the provider's declared heartbeat.

This is a SECOND, independent axis from `preflight_config.heartbeat_findings`, which checks the
*derived-vs-base* pairing (ADR 0019 / finding #8). Both are heartbeat guards; neither subsumes the other:

  * derived-vs-base  — a NAV-sourced feed must not be gated TIGHTER than the base whose timestamp it inherits.
  * declared-margin  — ANY feed must not be gated at-or-below the timestamp cadence its PROVIDER actually publishes at.

WHY AT-OR-BELOW IS A DEFECT, measured not assumed. A provider's declared heartbeat is a *target*; publication
lands tens of seconds PAST it (block granularity + trigger latency). So a feed registered at EXACTLY the declared
value has zero margin and goes stale at the end of essentially every publish cycle — the asset is valued $0 and
listed in `stalePriceAssets`. Two independent proofs:

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

usage:
  python3 declared_heartbeat_guard.py                # check every chain the CONFIG registers feeds for
  python3 declared_heartbeat_guard.py 1 8453
  python3 declared_heartbeat_guard.py --self-test    # prove the guard, incl. by mutation
  python3 declared_heartbeat_guard.py --refresh      # re-fetch the declared-heartbeat snapshot (needs network)
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent.parent
SNAPSHOT = HERE / "chainlink_declared_heartbeats.json"

ERROR = "ERROR"
WARN = "WARN"

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
}
DIRECTORY_BASE = "https://reference-data-directory.vercel.app/"

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


def _fix_hint(chain_id: str, name: str, declared: int) -> str:
    """Name BOTH legitimate exits. A guard that fires without saying how to satisfy it gets bypassed."""
    suggested = ((declared + 3600) // 3600) * 3600
    return (
        f"FIX — pick one:\n"
        f"        (1) RAISE the registered heartbeat above the declared value, with real margin. For "
        f"'{name}' declared {declared}, use >= {suggested} (declared + 1 h). Edit the `heartbeat` in "
        f"nav-config/assets-and-price-feeds/{chain_id}.json (or `yToXHeartbeat` in "
        f"contracts-deployment-config/custom-price-feeds/{chain_id}.json for a custom feed's rate leg).\n"
        f"        (2) EXEMPT it WITH A MEASUREMENT, if the feed is deviation-active. Measure the "
        f"aggregator's AnswerUpdated gaps over >= 14 days and add an ALLOWLIST entry in "
        f"declared_heartbeat_guard.py recording intervals/breaches/max_gap_s/measured. `breaches` must be 0.\n"
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
    return sorted(ids, key=int)


def load_snapshot() -> dict:
    if not SNAPSHOT.exists():
        raise SystemExit(f"missing snapshot {SNAPSHOT}; run: python3 {Path(__file__).name} --refresh")
    return json.loads(SNAPSHOT.read_text())


def registered_feeds(chain_id: str) -> list[dict]:
    """Every (address, heartbeat) this chain registers, from both config shapes.

    Custom feeds appear via their rate leg (`yToXFeed`/`yToXHeartbeat`) rather than their nav-config entry,
    because it is the RATE LEG that has a provider cadence — the custom wrapper has no provider of its own.
    """
    def _is_address(v):
        return isinstance(v, str) and v.startswith("0x") and len(v) == 42

    def _int_or_none(v):
        """Never raise while ENUMERATING. A row this cannot parse is emitted with heartbeat=None and
        reported by `_row_findings`; raising here would lose the whole chain's rows at once, which is
        the same failure `findings` contains per row."""
        if isinstance(v, bool) or v is None:
            return None
        try:
            return int(v)
        except (TypeError, ValueError):
            return None

    out: list[dict] = []
    nav = REPO / f"script/config/nav-config/assets-and-price-feeds/{chain_id}.json"
    if nav.exists():
        try:
            assets = json.loads(nav.read_text()) or {}
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
                    if fd.get("address"):
                        out.append({"asset": sym, "role": f"{kind}[{i}]",
                                    "address": fd["address"],
                                    "heartbeat": _int_or_none(fd.get("heartbeat")),
                                    "heartbeat_raw": fd.get("heartbeat"),
                                    "where": f"nav-config/assets-and-price-feeds/{chain_id}.json"})
    dep = REPO / f"script/config/contracts-deployment-config/custom-price-feeds/{chain_id}.json"
    if dep.exists():
        try:
            feeds = json.loads(dep.read_text()) or {}
        except json.JSONDecodeError as e:
            feeds = {}
            out.append({"asset": "(config)", "role": "file", "address": str(dep.name),
                        "heartbeat": None, "config_error": f"not valid JSON: {e}",
                        "where": f"contracts-deployment-config/custom-price-feeds/{chain_id}.json"})
        for name, v in feeds.items():
            if not isinstance(v, dict):
                continue
            ctor = v.get("constructor") or {}
            # RATE LEGS ARE FOUND BY SHAPE, NOT BY ONE HARD-CODED KEY NAME. Matching only
            # `yToXFeed`/`yToXHeartbeat` silently missed nine ENABLED custom feeds whose leg is named for
            # the pair it prices — `wstEthToEthChainlink`/`wstEthToEthHeartbeat`,
            # `ldoToEthChainlinkAddress`/`ldoToEthChainlinkHeartbeat`, and so on. Those are exactly the
            # LST-rate feeds this audit targeted, so the guard read as covering custom feeds while
            # checking a third of them. Every `<stem>Heartbeat` is paired with the address-valued key
            # that shares its stem; a heartbeat with no such partner is REPORTED, never dropped.
            for hb_key in sorted(k for k in ctor if k.endswith("Heartbeat")):
                stem = hb_key[: -len("Heartbeat")]
                addr = next((ctor[k] for k in sorted(ctor)
                             if k != hb_key and k.startswith(stem) and _is_address(ctor.get(k))), None)
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


def _consequence(role: str) -> str:
    """The consequence of going stale is NOT the same for a pricing feed and a monitor feed.

    A PRIMARY feed going stale values the asset at $0 and lists it in `stalePriceAssets`. A MONITOR feed
    never prices — `getPriceDataNoDivergence` selects over the primary mapping only — so its staleness
    surfaces as an unhealthy-monitor signal instead. Stating the pricing consequence for a monitor row
    would overstate the impact, and overstated findings are how a guard loses its credibility.
    """
    if role.startswith("monitorFeeds"):
        return (" This is a MONITOR feed, so it does not price the asset: staleness here does not zero "
                "the valuation, it degrades the divergence check and surfaces as an unhealthy monitor.")
    return " The asset is valued $0 and listed in `stalePriceAssets`."


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
    if rh > dh:
        return []
    allow = ALLOWLIST.get((str(chain_id), key))
    if allow:
        if allow.get("breaches", 1) != 0:
            return [(ERROR, f"asset '{r['asset']}' {r['role']} is allowlisted but its recorded evidence "
                            f"shows {allow['breaches']} breaches — an allowlist entry must have 0. "
                            f"Fix the feed, do not exempt it.")]
        if allow.get("registered") != rh:
            return [(ERROR, f"asset '{r['asset']}' {r['role']} allowlist entry was measured against "
                            f"registered={allow.get('registered')} but the config now says {rh}. "
                            f"Re-measure and update the entry; a stale exemption is not evidence.")]
        # THE EVIDENCE MUST ACTUALLY BE THERE. `breaches: 0` alone is not a measurement — an entry with
        # no interval count and no date asserts a conclusion while recording nothing that can be re-run,
        # which is precisely the "place to hide a real defect" the allowlist's own comment warns about.
        if not isinstance(allow.get("intervals"), int) or allow["intervals"] <= 0:
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
        return []
    # SEVERITY: WARN, not ERROR, and the distinction is load-bearing. At-or-below margin is a
    # *candidate*, not a defect — it only bites HEARTBEAT-DRIVEN feeds, and ~30 references on the
    # configured chains are deviation-active and genuinely fine. Erroring on all of them would block
    # every deploy on feeds nobody has shown to be broken, and a guard that cries wolf gets bypassed
    # rather than satisfied. So: unmeasured at-or-below margin is a WARN naming both exits (a
    # to-measure queue), and ERROR is reserved for an evidence CONTRADICTION — an allowlist entry
    # that records breaches, or one measured against a heartbeat the config has since changed.
    return [(WARN,
             f"declared-heartbeat margin UNMEASURED: asset '{r['asset']}' {r['role']} ({rec.get('name')}) is "
             f"registered at {rh} but the provider declares {dh} — margin {rh - dh:+d}. A provider "
             f"publishes tens of seconds PAST its declared heartbeat, so at-or-below margin means the "
             f"feed goes stale at the end of essentially every "
             f"publish cycle.{_consequence(r['role'])} Measured precedents: sUSDS 59/61 cycles (#211), "
             f"OETH 29/29 (#236).{off}\n"
             f"        {_fix_hint(str(chain_id), rec.get('name') or '?', dh)}")]


def findings(chain_id: str, snapshot: dict | None = None) -> list[tuple[str, str]]:
    """(level, message) for one chain — the per-feed declared-margin verdicts.

    Severity follows the three-state ladder in the module docstring: SILENT for positive margin or an
    evidenced allowlist entry, WARN for an UNMEASURED at-or-below-margin feed (a to-measure queue, not a
    blocker), and ERROR only for an evidence CONTRADICTION — an allowlist entry recording breaches, or one
    measured against a heartbeat the config has since changed. It deliberately does NOT error on an
    unmeasured feed; the module docstring explains why that split is load-bearing.

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
    return f


_SNAPSHOT_FINDINGS_EMITTED = False


def _reset_snapshot_findings_once() -> None:
    """Test seam: re-arm `snapshot_findings_once` so an arm can assert both the emit AND the dedupe."""
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
        rows = [r for r in rows if not r.get("unpaired_heartbeat")]   # no address to fetch
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
            for k in ("proxyAddress", "contractAddress"):
                a = rec.get(k)
                if isinstance(a, str):
                    idx.setdefault(a.lower(), rec)
        ent = {}
        for a in sorted(refs):
            rec = idx.get(a)
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
        if registered_feeds(cid):
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

    case_silent("positive margin is SILENT", "1", snap,
                [{"asset": "T", "role": "priceFeeds[0]", "address": A, "heartbeat": 90000, "where": "x"}])
    case("zero margin warns (candidate, not blocker)", "1", snap,
         [{"asset": "T", "role": "priceFeeds[0]", "address": A, "heartbeat": 86400, "where": "x"}],
         WARN, "declared-heartbeat margin UNMEASURED")
    case("negative margin warns", "1", snap,
         [{"asset": "T", "role": "priceFeeds[0]", "address": A, "heartbeat": 3600, "where": "x"}],
         WARN, "declared-heartbeat margin UNMEASURED")
    case("finding names BOTH exits", "1", snap,
         [{"asset": "T", "role": "priceFeeds[0]", "address": A, "heartbeat": 86400, "where": "x"}],
         WARN, "EXEMPT it WITH A MEASUREMENT")
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
             ERROR, "must have 0")
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

    # A monitor feed does not price the asset, so it must not be told it will be valued $0.
    _mon = case("a monitorFeeds row states the MONITOR consequence, not the $0 one", "1", _snap2,
                [{"asset": "T", "role": "monitorFeeds[0]", "address": _A2, "heartbeat": 86400,
                  "where": "x"}],
                WARN, "does not zero the valuation")
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
