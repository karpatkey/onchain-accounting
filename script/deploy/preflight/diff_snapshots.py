#!/usr/bin/env python3
"""Diff two production snapshots — the "did the new stack reproduce the old one?" answer.

Compares structure (assets, feeds, adapters, meta-instance sets, roles, default-adapter inclusion)
exactly, and per-account NAV within a relative tolerance, since the two captures are at different
blocks and prices move.

Addresses that are EXPECTED to change on a from-scratch redeploy — the proxy, implementation,
ERC20Default, every feed and adapter address — are reported as informational moves, not failures.
What must NOT change is the shape: the same assets with the same feed types and heartbeats, the same
adapters registered, the same meta-instance coordinates, the same positions per account.

usage:
  python3 diff_snapshots.py pre post
  python3 diff_snapshots.py pre post --tolerance 0.02 --json diff.json
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import chainlib as c


def load(tag: str) -> dict[int, dict]:
    d = Path(tag) if "/" in tag else c.SNAPSHOT_DIR / tag
    out = {}
    for p in sorted(d.glob("*.json")):
        if p.name == "index.json":
            continue
        s = json.loads(p.read_text())
        out[s["chainId"]] = s
    if not out:
        raise SystemExit(f"no snapshots found in {d}")
    return out


def feed_shape(f: dict) -> tuple:
    """A feed's identity for diffing: everything except the address, which is expected to move."""
    return (f["priceType"], f["decimals"], f["heartbeat"])


def asset_shape(a: dict) -> dict:
    return {
        "symbol": a["symbol"],
        "decimals": a["decimals"],
        "priceFeeds": [feed_shape(f) for f in a["priceFeeds"]],
        "monitorFeeds": [feed_shape(f) for f in a["monitorFeeds"]],
        "divergenceToleranceBps": a["divergenceToleranceBps"],
        "pegToleranceBps": a["pegToleranceBps"],
        "includedInDefaultAdapter": a["includedInDefaultAdapter"],
    }


def position_key(p: dict) -> tuple:
    """Stable identity per docs/howto/position-identity-schema.md — deliberately excludes the
    ephemeral positionInstanceId and the adapter address (which moves on a redeploy)."""
    return (p["balanceAsset"]["address"].lower(), p["protocolBrand"], p["protocolId"],
            p["protocolSubId"], p["positionId"], p["positionKind"], p["isDebt"])


def diff_chain(a: dict, b: dict, tol: float) -> list[str]:
    out: list[str] = []

    def moved(label, x, y):
        if (x or "").lower() != (y or "").lower():
            out.append(f"INFO  {label} moved {x} -> {y}")

    moved("proxy", a["proxy"], b["proxy"])
    moved("implementation", a["implementation"], b["implementation"])
    moved("erc20DefaultBalanceAdapter",
          a["erc20DefaultBalanceAdapter"], b["erc20DefaultBalanceAdapter"])

    if a["version"] != b["version"]:
        out.append(f"INFO  version {a['version']} -> {b['version']}")
    if a["usdDecimals"] != b["usdDecimals"]:
        out.append(f"DIFF  usdDecimals {a['usdDecimals']} -> {b['usdDecimals']}")

    # --- roles: must be identical ------------------------------------------
    for who in sorted(set(a["roles"]) | set(b["roles"])):
        ra, rb = a["roles"].get(who, {}), b["roles"].get(who, {})
        for role in ("DEFAULT_ADMIN_ROLE", "MANAGER"):
            if ra.get(role) != rb.get(role):
                out.append(f"DIFF  role {who}.{role} {ra.get(role)} -> {rb.get(role)}")

    # --- assets -------------------------------------------------------------
    am = {x["address"].lower(): x for x in a["assets"]}
    bm = {x["address"].lower(): x for x in b["assets"]}
    for addr in sorted(set(am) - set(bm)):
        out.append(f"DIFF  asset MISSING in new: {am[addr]['symbol']} {addr}")
    for addr in sorted(set(bm) - set(am)):
        out.append(f"DIFF  asset ADDED in new:   {bm[addr]['symbol']} {addr}")
    for addr in sorted(set(am) & set(bm)):
        sa, sb = asset_shape(am[addr]), asset_shape(bm[addr])
        if sa != sb:
            for k in sa:
                if sa[k] != sb[k]:
                    out.append(f"DIFF  asset {am[addr]['symbol']} {k}: {sa[k]} -> {sb[k]}")

    # --- adapters + meta instances -----------------------------------------
    # Adapter addresses all move, so key on the deployment-record config key.
    aa = {x["configKey"] or x["address"].lower(): x for x in a["adapters"]}
    ba = {x["configKey"] or x["address"].lower(): x for x in b["adapters"]}
    for k in sorted(set(aa) - set(ba)):
        out.append(f"DIFF  adapter MISSING in new: {k} ({aa[k]['address']})")
    for k in sorted(set(ba) - set(aa)):
        out.append(f"DIFF  adapter ADDED in new:   {k} ({ba[k]['address']})")
    for k in sorted(set(aa) & set(ba)):
        if aa[k]["adapterType"] != ba[k]["adapterType"]:
            out.append(f"DIFF  adapter {k} type {aa[k]['adapterType']} -> {ba[k]['adapterType']}")
        ia, ib = set(aa[k]["metaInstances"]), set(ba[k]["metaInstances"])
        for x in sorted(ia - ib):
            out.append(f"DIFF  adapter {k} LOST meta instance {x}")
        for x in sorted(ib - ia):
            out.append(f"DIFF  adapter {k} GAINED meta instance {x}")

    if a["metaInstanceTotal"] != b["metaInstanceTotal"]:
        out.append(f"DIFF  metaInstanceTotal {a['metaInstanceTotal']} -> {b['metaInstanceTotal']}")

    # --- accounts -----------------------------------------------------------
    acc_a = {x["label"]: x for x in a["accounts"]}
    acc_b = {x["label"]: x for x in b["accounts"]}
    for label in sorted(set(acc_a) & set(acc_b)):
        xa, xb = acc_a[label], acc_b[label]
        if "nav" not in xa or "nav" not in xb:
            out.append(f"DIFF  account {label}: one side failed to read")
            continue
        va, vb = int(xa["nav"]["value"]), int(xb["nav"]["value"])
        if va == 0 and vb == 0:
            rel = 0.0
        elif va == 0:
            rel = 1.0
        else:
            rel = abs(vb - va) / abs(va)
        flag = "DIFF " if rel > tol else "ok   "
        out.append(f"{flag} account {label} nav {va} -> {vb} ({rel * 100:.2f}%)")

        pa = {position_key(p["position"]) for p in xa["positions"]}
        pb = {position_key(p["position"]) for p in xb["positions"]}
        for k in sorted(pa - pb):
            out.append(f"DIFF  account {label} LOST position {k}")
        for k in sorted(pb - pa):
            out.append(f"DIFF  account {label} GAINED position {k}")

        # Labels are display-only, so a change is expected from the label wave — report, don't fail.
        la = {position_key(p["position"]): (p["protocolName"], tuple(p["labels"]))
              for p in xa["positions"]}
        lb = {position_key(p["position"]): (p["protocolName"], tuple(p["labels"]))
              for p in xb["positions"]}
        for k in sorted(set(la) & set(lb)):
            if la[k] != lb[k]:
                out.append(f"INFO  account {label} label change {la[k]} -> {lb[k]}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("before")
    ap.add_argument("after")
    ap.add_argument("--tolerance", type=float, default=0.01,
                    help="max relative NAV drift treated as price movement (default 1%%)")
    ap.add_argument("--json")
    args = ap.parse_args()

    A, B = load(args.before), load(args.after)
    report, n_diff = {}, 0
    for cid in sorted(set(A) | set(B)):
        name = c.chain_config(cid).get("name", "?")
        if cid not in B:
            print(f"  {cid:8} {name:16} MISSING from '{args.after}'")
            n_diff += 1
            continue
        if cid not in A:
            print(f"  {cid:8} {name:16} MISSING from '{args.before}'")
            n_diff += 1
            continue
        lines = diff_chain(A[cid], B[cid], args.tolerance)
        diffs = [ln for ln in lines if ln.startswith("DIFF")]
        n_diff += len(diffs)
        report[str(cid)] = lines
        print(f"  {cid:8} {name:16} {len(diffs)} difference(s)")
        for ln in lines:
            if not ln.startswith("ok"):
                print(f"           {ln}")

    print(f"\n{n_diff} structural difference(s). "
          f"INFO lines (address moves, label changes) are expected on a redeploy.")
    if args.json:
        json.dump(report, open(args.json, "w"), indent=1)
        print(f"wrote {args.json}")
    return 1 if n_diff else 0


if __name__ == "__main__":
    sys.exit(main())
