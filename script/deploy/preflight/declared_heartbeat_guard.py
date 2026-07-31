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
  python3 declared_heartbeat_guard.py                # check every chain with a snapshot entry
  python3 declared_heartbeat_guard.py 1 8453
  python3 declared_heartbeat_guard.py --self-test    # prove the guard, incl. by mutation
  python3 declared_heartbeat_guard.py --refresh      # re-fetch the declared-heartbeat snapshot (needs network)
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent.parent
SNAPSHOT = HERE / "chainlink_declared_heartbeats.json"

ERROR = "ERROR"
WARN = "WARN"

# Refuse to trust a snapshot older than this without saying so. Chainlink can re-tune a feed's heartbeat.
SNAPSHOT_STALE_DAYS = 180

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


def _fix_hint(chain_id: str, addr: str, name: str, registered: int, declared: int) -> str:
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


def load_snapshot() -> dict:
    if not SNAPSHOT.exists():
        raise SystemExit(f"missing snapshot {SNAPSHOT}; run: python3 {Path(__file__).name} --refresh")
    return json.loads(SNAPSHOT.read_text())


def registered_feeds(chain_id: str) -> list[dict]:
    """Every (address, heartbeat) this chain registers, from both config shapes.

    Custom feeds appear via their rate leg (`yToXFeed`/`yToXHeartbeat`) rather than their nav-config entry,
    because it is the RATE LEG that has a provider cadence — the custom wrapper has no provider of its own.
    """
    out: list[dict] = []
    nav = REPO / f"script/config/nav-config/assets-and-price-feeds/{chain_id}.json"
    if nav.exists():
        for sym, entry in json.loads(nav.read_text()).items():
            if not isinstance(entry, dict):
                continue
            for kind in ("priceFeeds", "monitorFeeds"):
                for i, fd in enumerate(entry.get(kind) or []):
                    if fd.get("address") and isinstance(fd.get("heartbeat"), int):
                        out.append({"asset": sym, "role": f"{kind}[{i}]",
                                    "address": fd["address"], "heartbeat": fd["heartbeat"],
                                    "where": f"nav-config/assets-and-price-feeds/{chain_id}.json"})
    dep = REPO / f"script/config/contracts-deployment-config/custom-price-feeds/{chain_id}.json"
    if dep.exists():
        try:
            feeds = json.loads(dep.read_text()) or {}
        except json.JSONDecodeError:
            feeds = {}
        for name, v in feeds.items():
            if not isinstance(v, dict):
                continue
            ctor = v.get("constructor") or {}
            addr, hb = ctor.get("yToXFeed"), ctor.get("yToXHeartbeat")
            if addr and hb is not None:
                out.append({"asset": name, "role": "rate leg (yToXFeed)", "address": addr,
                            "heartbeat": int(hb), "enabled": bool(v.get("enabled")),
                            "where": f"contracts-deployment-config/custom-price-feeds/{chain_id}.json"})
    return out


def findings(chain_id: str, snapshot: dict | None = None) -> list[tuple[str, str]]:
    """(level, message) for one chain. ERROR on zero/negative margin without an evidenced exemption."""
    snap = snapshot if snapshot is not None else load_snapshot()
    declared = (snap.get("chains") or {}).get(str(chain_id), {})
    f: list[tuple[str, str]] = []
    for r in registered_feeds(str(chain_id)):
        key = str(r["address"]).lower()
        rec = declared.get(key)
        if rec is None:
            # Not a Chainlink-catalogue feed (RedStone/API3), or the snapshot predates this address.
            # Reported as actionable rather than passing silently — the two cases look identical here.
            f.append((WARN, f"asset '{r['asset']}' {r['role']} {r['address']} has NO declared heartbeat "
                            f"recorded. Either it is not a Chainlink-catalogue feed (RedStone/API3 — expected, "
                            f"no action), or the snapshot is missing it: run --refresh to distinguish."))
            continue
        dh, rh = int(rec["declaredHeartbeat"]), int(r["heartbeat"])
        if rh > dh:
            continue
        allow = ALLOWLIST.get((str(chain_id), key))
        if allow:
            if allow.get("breaches", 1) != 0:
                f.append((ERROR, f"asset '{r['asset']}' {r['role']} is allowlisted but its recorded evidence "
                                 f"shows {allow['breaches']} breaches — an allowlist entry must have 0. "
                                 f"Fix the feed, do not exempt it."))
            elif allow.get("registered") != rh:
                f.append((ERROR, f"asset '{r['asset']}' {r['role']} allowlist entry was measured against "
                                 f"registered={allow.get('registered')} but the config now says {rh}. "
                                 f"Re-measure and update the entry; a stale exemption is not evidence."))
            continue
        # SEVERITY: WARN, not ERROR, and the distinction is load-bearing. At-or-below margin is a
        # *candidate*, not a defect — it only bites HEARTBEAT-DRIVEN feeds, and ~30 references on the
        # configured chains are deviation-active and genuinely fine. Erroring on all of them would block
        # every deploy on feeds nobody has shown to be broken, and a guard that cries wolf gets bypassed
        # rather than satisfied. So: unmeasured at-or-below margin is a WARN naming both exits (a
        # to-measure queue), and ERROR is reserved for an evidence CONTRADICTION — an allowlist entry
        # that records breaches, or one measured against a heartbeat the config has since changed.
        f.append((WARN,
                  f"declared-heartbeat margin UNMEASURED: asset '{r['asset']}' {r['role']} ({rec.get('name')}) is "
                  f"registered at {rh} but the provider declares {dh} — margin {rh - dh:+d}. A provider "
                  f"publishes tens of seconds PAST its declared heartbeat, so at-or-below margin means the "
                  f"asset goes stale (valued $0, listed in stalePriceAssets) at the end of essentially every "
                  f"publish cycle. Measured precedents: sUSDS 59/61 cycles (#211), OETH 29/29 (#236).\n"
                  f"        {_fix_hint(str(chain_id), r['address'], rec.get('name') or '?', rh, dh)}"))
    return f


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


def refresh() -> int:
    """Re-fetch declared heartbeats for every address config references. Needs network."""
    import urllib.request
    from datetime import date
    out = {"$comment": load_snapshot().get("$comment") if SNAPSHOT.exists() else "",
           "source": DIRECTORY_BASE, "fetched": date.today().isoformat(), "chains": {}}
    total = 0
    for chain_id, fn in DIRECTORY_FILES.items():
        refs = {str(r["address"]).lower() for r in registered_feeds(chain_id)}
        if not refs:
            continue
        try:
            with urllib.request.urlopen(DIRECTORY_BASE + fn, timeout=120) as resp:
                cat = json.load(resp)
        except Exception as e:  # noqa: BLE001 - a fetch failure must not look like "no feeds"
            print(f"  chain {chain_id}: FETCH FAILED ({e}) — keeping any existing entries", file=sys.stderr)
            prev = (load_snapshot().get("chains") or {}).get(chain_id) if SNAPSHOT.exists() else None
            if prev:
                out["chains"][chain_id] = prev
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
            if isinstance(hb, (int, float)) and hb:
                ent[a] = {"name": rec.get("name"), "declaredHeartbeat": int(hb),
                          "threshold": rec.get("threshold"), "feedCategory": rec.get("feedCategory")}
        if ent:
            out["chains"][chain_id] = ent
            total += len(ent)
        print(f"  chain {chain_id}: {len(ent)} of {len(refs)} referenced addresses have a declared heartbeat")
    SNAPSHOT.write_text(json.dumps(out, indent=2) + "\n")
    print(f"wrote {SNAPSHOT} ({total} feeds)")
    return 0


def self_test() -> int:
    """Prove each arm fires, then prove it by MUTATION against the real config."""
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
    # allowlist with a breach is itself an error
    key = ("1", A.lower())
    ALLOWLIST[key] = {"asset": "T", "registered": 86400, "breaches": 3, "measured": "2026-01-01"}
    case("allowlist entry WITH breaches errors", "1", snap,
         [{"asset": "T", "role": "priceFeeds[0]", "address": A, "heartbeat": 86400, "where": "x"}],
         ERROR, "must have 0")
    # allowlist measured against a different registered value is stale
    ALLOWLIST[key] = {"asset": "T", "registered": 82800, "breaches": 0, "measured": "2026-01-01"}
    case("stale allowlist (registered changed) errors", "1", snap,
         [{"asset": "T", "role": "priceFeeds[0]", "address": A, "heartbeat": 86400, "where": "x"}],
         ERROR, "stale exemption is not evidence")
    del ALLOWLIST[key]

    # MUTATION against the real config: every real allowlist entry must currently be at-or-below margin,
    # otherwise the exemption is dead weight hiding nothing and should be deleted.
    real = load_snapshot()
    for (cid, addr), ev in ALLOWLIST.items():
        rec = (real.get("chains") or {}).get(cid, {}).get(addr)
        if not rec:
            print(f"  [WARN] allowlist ({cid},{addr[:10]}…) has no snapshot entry — cannot audit")
            continue
        reg = ev.get("registered")
        if reg is not None and reg > int(rec["declaredHeartbeat"]):
            print(f"  [WARN] allowlist ({cid},{addr[:10]}…) is unnecessary: registered {reg} already exceeds "
                  f"declared {rec['declaredHeartbeat']}. Delete the entry.")
        else:
            print(f"  [PASS] allowlist ({cid},{addr[:10]}…) {ev.get('asset')} genuinely needs the exemption "
                  f"(registered {reg} <= declared {rec['declaredHeartbeat']}), evidence "
                  f"{ev.get('breaches')} breaches / {ev.get('intervals')} intervals, measured {ev.get('measured')}")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("chains", nargs="*", help="chain ids (default: all in the snapshot)")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--refresh", action="store_true")
    ap.add_argument("--json", metavar="PATH")
    a = ap.parse_args()
    if a.refresh:
        return refresh()
    if a.self_test:
        return self_test()
    snap = load_snapshot()
    ids = a.chains or sorted((snap.get("chains") or {}), key=int)
    report, errors = {}, 0
    for lvl, msg in snapshot_age_findings(snap):
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
