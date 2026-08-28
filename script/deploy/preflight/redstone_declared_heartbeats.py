#!/usr/bin/env python3
"""Redstone declared-heartbeat guard — the ADR 0025 equality rule for RedStone feeds.

WHY THIS EXISTS. `declared_heartbeat_guard.py` resolves Chainlink feeds only. Every RedStone
registration therefore came back as `has NO declared heartbeat recorded`, and the guard's own advice —
"a WARN that survives a SUCCESSFUL refresh means 'not a Chainlink feed' and needs no action" — is true
but was being read as "verified". It is not: it means UNCHECKED. 31 monitor registrations sat in that
state, and when they were finally checked against RedStone's own manifests, SEVEN were wrong:

    chain 1  wstETH               86400 vs declared 21600
    chain 56 ETH/USDC/USDT/CAKE   86400 vs declared 21600
    chain 56 BNB/WBNB             86400 vs declared 60      (a 86,340 s false-fresh window)

All were registered ABOVE declared — the direction ADR 0025 treats as critical, because every second
above declared is a window in which a dead feed still reads fresh. On a MONITOR feed that does not zero
an asset; it silently degrades the divergence check, which is exactly the kind of failure that goes
unnoticed without a guard.

THE SOURCE. RedStone publishes its relayer manifests in redstone-oracles-monorepo. Each entry carries
`priceFeedAddress` and an `updateTriggers`/`updateTriggersOverrides` pair whose
`timeSinceLastUpdateInMilliseconds` IS the declared heartbeat. `main/` is authoritative; `fallback/`
is the standby copy and the two agreed on every value checked on 2026-08-28.

A feed can live in a product-specific manifest rather than the chain's main one — BNB on chain 56 is in
`bnbListaDaoMultiFeed`, not `bnbMultiFeed` — so a miss in the primary manifest is NOT evidence that a
feed is uncatalogued. That mistake is what would have left BNB at 86400.
"""
from __future__ import annotations

import json
import sys
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SNAPSHOT = Path(__file__).with_name("redstone_declared_heartbeats.json")
BASE = ("https://raw.githubusercontent.com/redstone-finance/redstone-oracles-monorepo/main/"
        "packages/relayer-remote-config")

# Manifests searched per chain, in order. Product-specific manifests are listed alongside the chain's
# main one because a feed may only appear in the former (see the module docstring).
MANIFESTS: dict[str, list[str]] = {
    "1": ["main/relayer-manifests-multi-feed/ethereumMultiFeed.json",
          "main/relayer-manifests-multi-feed/ethereumAlphaGrowthMultiFeed.json",
          "main/relayer-manifests/ethereumEtherfiWeeth.json"],
    "10": ["main/relayer-manifests-multi-feed/optimismMultiFeed.json"],
    "56": ["main/relayer-manifests-multi-feed/bnbMultiFeed.json",
           "main/relayer-manifests-multi-feed/bnbListaDaoMultiFeed.json"],
    "8453": ["main/relayer-manifests-multi-feed/baseMultiFeed.json"],
    "42161": ["main/relayer-manifests-multi-feed/arbitrumOneMultiFeed.json"],
}

ERROR, WARN = "ERROR", "WARN"

# Feeds knowingly exempt from the "must resolve to a declared cadence" rule. An entry here is a RECORDED
# DECISION, not a silence: without it an unresolved address is an ERROR and fails the build.
#
# The alternative — reporting "UNCHECKED" as a WARN — is what this guard exists to end. WARNs do not fail
# CI, so an uncatalogued feed would be reported as unverified and permitted in the same breath, which is
# indistinguishable from not checking at all. That is precisely how 31 RedStone registrations sat
# unverified while seven of them were wrong.
UNCATALOGUED_EXCEPTIONS: dict[tuple[str, str], str] = {
    ("1", "0xddb6f90ffb4d3257dd666b69178e5b3c5bf41136"): (
        "weETH monitor feed. Live and answering (age ~3 h when checked 2026-08-28, description "
        "'Redstone Price Feed'), but present in NONE of the 116 manifests under "
        "relayer-remote-config/main — searched exhaustively, not just the chain's primary manifest. "
        "So its declared cadence is genuinely unknown rather than merely unlooked-for. It is a MONITOR "
        "feed, so a wrong heartbeat degrades the divergence check and cannot zero an asset. "
        "TO CLOSE: ask RedStone which manifest publishes it, add that manifest to MANIFESTS, and delete "
        "this entry."
    ),
}


def _fetch(path: str) -> dict:
    with urllib.request.urlopen(f"{BASE}/{path}", timeout=60) as r:  # noqa: S310
        return json.loads(r.read().decode())


def declared_map(chain: str, fetch=_fetch) -> tuple[dict[str, int], list[str]]:
    """address(lower) -> declared heartbeat seconds, plus the manifests that could NOT be fetched.

    THE FAILURES ARE RETURNED, NOT LOGGED AND SWALLOWED. This module is a BLOCKING CI gate, and an
    unreachable manifest degrades every feed it covers into "no declared cadence" — which is a WARN, and
    WARNs do not fail the build. A network outage would therefore turn the gate green while checking
    nothing, which is the precise failure mode this guard exists to end.
    """
    out: dict[str, int] = {}
    failures: list[str] = []
    for path in MANIFESTS.get(chain, []):
        try:
            m = fetch(path)
        except Exception as e:  # noqa: BLE001 - a fetch failure must not read as "feed not found"
            print(f"  chain {chain}: FETCH FAILED {path} ({e})", file=sys.stderr)
            failures.append(f"{path} ({e!r})")
            continue
        default = (m.get("updateTriggers") or {}).get("timeSinceLastUpdateInMilliseconds")
        for _, v in (m.get("priceFeeds") or {}).items():
            if not isinstance(v, dict):
                continue
            addr = (v.get("priceFeedAddress") or "").lower()
            ms = (v.get("updateTriggersOverrides") or {}).get("timeSinceLastUpdateInMilliseconds", default)
            if addr and isinstance(ms, (int, float)) and not isinstance(ms, bool):
                out.setdefault(addr, int(ms) // 1000)
    return out, failures


def registered_redstone(chain: str) -> list[dict]:
    """Every RedStone registration in this chain's nav-config, primary and monitor alike."""
    p = REPO / f"script/config/nav-config/assets-and-price-feeds/{chain}.json"
    cfg = json.loads(p.read_text())
    rows = []
    for asset, v in cfg.items():
        if not isinstance(v, dict):
            continue
        for arr in ("priceFeeds", "monitorFeeds"):
            for i, f in enumerate(v.get(arr) or []):
                if not isinstance(f, dict) or f.get("type") != "Redstone":
                    continue
                rows.append({"asset": asset, "role": f"{arr}[{i}]",
                             "address": f.get("address"), "heartbeat": f.get("heartbeat")})
    return rows


def findings(chain: str, fetch=_fetch) -> list[tuple[str, str]]:
    decl, fetch_failures = declared_map(chain, fetch)
    out: list[tuple[str, str]] = []
    for f in fetch_failures:
        # ERROR, not WARN: an unfetched manifest means this chain was NOT checked, and "not checked" must
        # never be reported with the same severity as "checked and fine".
        out.append((ERROR, f"chain {chain}: manifest {f} could NOT be fetched, so its feeds were not "
                           f"verified against RedStone's declared cadences. Failing closed — re-run, or "
                           f"snapshot the manifests if this endpoint is unreliable."))
    for r in registered_redstone(chain):
        addr = (r["address"] or "").lower()
        rh, dh = r["heartbeat"], decl.get(addr)
        if dh is None:
            note = UNCATALOGUED_EXCEPTIONS.get((chain, addr))
            if note:
                out.append((WARN, f"asset '{r['asset']}' {r['role']} {r['address']} has no declared "
                                  f"cadence and is a RECORDED EXCEPTION: {note}"))
                continue
            out.append((ERROR, f"asset '{r['asset']}' {r['role']} {r['address']} is a RedStone feed with "
                               f"NO declared cadence found in any manifest for chain {chain}. That is "
                               f"UNCHECKED, not verified, and unchecked must not pass — add the product "
                               f"manifest that carries it to MANIFESTS, or record it in "
                               f"UNCATALOGUED_EXCEPTIONS with the evidence."))
            continue
        if not isinstance(rh, int) or rh != dh:
            out.append((ERROR, f"declared-heartbeat MISMATCH: asset '{r['asset']}' {r['role']} "
                               f"({r['address']}) is registered at {rh} but RedStone declares {dh} "
                               f"({(rh - dh):+d}s). ADR 0025 requires exact equality; above declared is a "
                               f"window in which a dead feed still reads fresh."))
    return out


def main(argv: list[str]) -> int:
    chains = [a for a in argv[1:] if a.isdigit()] or list(MANIFESTS)
    total = 0
    for c in chains:
        f = findings(c)
        errs = [m for lvl, m in f if lvl == ERROR]
        print(f"=== chain {c}: {len(errs)} ERROR, {len(f) - len(errs)} WARN ===")
        for lvl, m in f:
            print(f"  {lvl}: {m}")
        total += len(errs)
    print(f"total ERRORs: {total}")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
