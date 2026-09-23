#!/usr/bin/env python3
"""Diff two production snapshots — the "did the new stack reproduce the old one?" answer.

Compares structure (assets, feeds, adapters, meta-instance sets, roles, default-adapter inclusion)
exactly, and per-account NAV within a relative tolerance, since the two captures are at different
blocks and prices move.

Addresses that are EXPECTED to change on a from-scratch redeploy — the proxy, implementation,
ERC20Default, every feed and adapter address — are reported as informational moves, not failures.
What must NOT change is the shape: the same assets with the same feed types and heartbeats, the same
adapters registered, the same meta-instance coordinates, the same positions per account.

RECLASSIFICATION. The wallet-yield adapter family moves 35 holdings from the generic wallet identity
to their protocol's, without changing a single amount. To this script that is 35 assets flipping
`includedInDefaultAdapter`, 17 adapters appearing, and 70 position lines — indistinguishable from real
breakage. `reclassification.json` names the intended moves so they report as INFO instead.

It is deliberately hard for that manifest to hide a real problem. A LOST/GAINED pair is collapsed only
when the asset, the `isDebt` flag AND the EXACT amount all match, the LOST side is `positionKind`
Wallet, and the GAINED side carries the kind the manifest names for that asset. A pair failing any one
of those stays a DIFF, so a reclassification that also moved value still fails the gate.

usage:
  python3 diff_snapshots.py pre post
  python3 diff_snapshots.py pre post --tolerance 0.02 --json diff.json
  python3 diff_snapshots.py --self-test
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import chainlib as c


MANIFEST = Path(__file__).resolve().parent / "reclassification.json"


def coord_to_address(coord: str) -> str:
    """A bytes32 meta-instance coordinate narrowed to its low 20 bytes, lowercased.

    Coordinates are stored as full bytes32 (`0x` + 64 hex). For the address-keyed families the address sits in
    the low 20 bytes; for Morpho marketIds / Balancer poolIds the whole word is meaningful and this produces a
    value that simply will not be in the manifest, which is the correct outcome."""
    h = coord.lower()
    return "0x" + h[-40:] if h.startswith("0x") and len(h) == 66 else h


def load_reclassifications(path: Path = MANIFEST) -> dict[int, dict[str, dict]]:
    """{chainId: {asset_lower: row}}. Absent file means no reclassification is expected."""
    if not path.exists():
        return {}
    raw = json.loads(path.read_text())
    return {int(cid): {r["asset"].lower(): r for r in rows}
            for cid, rows in raw.get("reclassifications", {}).items()}


def split_reclassified(lost: list[dict], gained: list[dict], expect: dict[str, dict]):
    """Collapse intended wallet -> protocol moves. Returns (still_lost, still_gained, info_lines).

    Value-preserving by construction: a pair is only collapsed when asset, isDebt and the exact
    amount all match. Amount is compared as a STRING because the snapshot stores it as one — the
    values exceed 2^53 and float would silently equate different balances."""
    info, used = [], set()
    remaining_lost = []
    for lp in lost:
        addr = lp["balanceAsset"]["address"].lower()
        row = expect.get(addr)
        if row is None or lp["positionKind"] != "Wallet":
            remaining_lost.append(lp)
            continue
        match = None
        for j, gp in enumerate(gained):
            if j in used:
                continue
            if (gp["balanceAsset"]["address"].lower() == addr
                    and gp["isDebt"] == lp["isDebt"]
                    and str(gp["amount"]) == str(lp["amount"])
                    and gp["positionKind"] == row["toPositionKind"]):
                match = j
                break
        if match is None:
            remaining_lost.append(lp)
            continue
        used.add(match)
        info.append(f"INFO  RECLASSIFIED {row['symbol']} {lp['amount']} "
                    f"Wallet -> {row['toPositionKind']} ({row['adapter']})")
    remaining_gained = [g for j, g in enumerate(gained) if j not in used]
    return remaining_lost, remaining_gained, info


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


def diff_chain(a: dict, b: dict, tol: float, expect: dict[str, dict] | None = None) -> list[str]:
    out: list[str] = []
    expect = expect or {}

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
                if sa[k] == sb[k]:
                    continue
                # A reclassified asset is EXPECTED to stop being armed on the default adapter — that is
                # precisely what stops it being reported twice. Only True -> False is downgraded; the
                # reverse would mean a meta adapter lost a coordinate and the wallet leg came back.
                if (k == "includedInDefaultAdapter" and sa[k] is True and sb[k] is False
                        and addr in expect):
                    out.append(f"INFO  asset {am[addr]['symbol']} disarmed on the default adapter"
                               f" (reclassified to {expect[addr]['adapter']})")
                    continue
                out.append(f"DIFF  asset {am[addr]['symbol']} {k}: {sa[k]} -> {sb[k]}")

    # --- adapters + meta instances -----------------------------------------
    # Adapter addresses all move, so key on the deployment-record config key.
    aa = {x["configKey"] or x["address"].lower(): x for x in a["adapters"]}
    ba = {x["configKey"] or x["address"].lower(): x for x in b["adapters"]}
    for k in sorted(set(aa) - set(ba)):
        out.append(f"DIFF  adapter MISSING in new: {k} ({aa[k]['address']})")
    expected_adapters = {r["adapter"] for r in expect.values()}
    for k in sorted(set(ba) - set(aa)):
        if k in expected_adapters:
            out.append(f"INFO  adapter ADDED in new:   {k} ({ba[k]['address']}) - reclassification")
            continue
        out.append(f"DIFF  adapter ADDED in new:   {k} ({ba[k]['address']})")
    for k in sorted(set(aa) & set(ba)):
        if aa[k]["adapterType"] != ba[k]["adapterType"]:
            out.append(f"DIFF  adapter {k} type {aa[k]['adapterType']} -> {ba[k]['adapterType']}")
        ia, ib = set(aa[k]["metaInstances"]), set(ba[k]["metaInstances"])
        for x in sorted(ia - ib):
            out.append(f"DIFF  adapter {k} LOST meta instance {x}")
        for x in sorted(ib - ia):
            # A coordinate is a bytes32 in the snapshot (66 chars, address left-padded), while the manifest is
            # keyed on the 42-char address — comparing them directly made this branch DEAD, which is why the
            # first version of this gate downgraded nothing here. Narrow to the low 20 bytes.
            if k in expected_adapters and coord_to_address(x) in expect:
                out.append(f"INFO  adapter {k} GAINED meta instance {x} - reclassification")
                continue
            out.append(f"DIFF  adapter {k} GAINED meta instance {x}")

    if a["metaInstanceTotal"] != b["metaInstanceTotal"]:
        # Not read from the contract — `snapshot_production.py` derives it as sum(metaInstanceCount). A
        # reclassification therefore RAISES it by exactly the number of coordinates the manifest names for this
        # chain, so that exact delta is expected and anything else is not. Without this the gate failed on the
        # very change the manifest exists to whitelist.
        delta = b["metaInstanceTotal"] - a["metaInstanceTotal"]
        if expect and delta == len(expect):
            out.append(f"INFO  metaInstanceTotal {a['metaInstanceTotal']} -> {b['metaInstanceTotal']}"
                       f" (+{delta}, matches the {len(expect)} reclassified coordinate(s))")
        else:
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

        by_key_a = {position_key(p["position"]): p["position"] for p in xa["positions"]}
        by_key_b = {position_key(p["position"]): p["position"] for p in xb["positions"]}
        lost = [by_key_a[k] for k in sorted(set(by_key_a) - set(by_key_b))]
        gained = [by_key_b[k] for k in sorted(set(by_key_b) - set(by_key_a))]
        lost, gained, recl = split_reclassified(lost, gained, expect)
        out.extend(f"{ln} [{label}]" for ln in recl)
        for p in lost:
            out.append(f"DIFF  account {label} LOST position {position_key(p)}")
        for p in gained:
            out.append(f"DIFF  account {label} GAINED position {position_key(p)}")

        # Labels are display-only, so a change is expected from the label wave — report, don't fail.
        la = {position_key(p["position"]): (p["protocolName"], tuple(p["labels"]))
              for p in xa["positions"]}
        lb = {position_key(p["position"]): (p["protocolName"], tuple(p["labels"]))
              for p in xb["positions"]}
        for k in sorted(set(la) & set(lb)):
            if la[k] != lb[k]:
                out.append(f"INFO  account {label} label change {la[k]} -> {lb[k]}")
    return out


def self_test() -> int:
    """Pin the pairing logic. The manifest's whole safety claim is that it downgrades identity churn and
    NEVER value churn, so the cases that must STAY a DIFF matter more than the one that collapses."""
    expect = {"0xaaa": {"asset": "0xAAA", "symbol": "wstETH",
                        "adapter": "LidoStakedEthWalletMeta", "toPositionKind": "Staking"}}

    def pos(kind, amount="100", debt=False, asset="0xAAA"):
        return {"balanceAsset": {"address": asset}, "amount": amount,
                "positionKind": kind, "isDebt": debt}

    cases = [
        ("the intended move collapses",
         [pos("Wallet")], [pos("Staking")], 0, 0, 1),
        ("a DIFFERENT AMOUNT stays a diff",
         [pos("Wallet", "100")], [pos("Staking", "101")], 1, 1, 0),
        ("a flipped isDebt stays a diff",
         [pos("Wallet", "100", False)], [pos("Staking", "100", True)], 1, 1, 0),
        ("the wrong target kind stays a diff",
         [pos("Wallet")], [pos("Supplied")], 1, 1, 0),
        ("an asset absent from the manifest stays a diff",
         [pos("Wallet", "100", False, "0xBBB")], [pos("Staking", "100", False, "0xBBB")], 1, 1, 0),
        ("a LOST leg that was not a Wallet leg stays a diff",
         [pos("Supplied")], [pos("Staking")], 1, 1, 0),
        ("a genuinely vanished holding stays a diff",
         [pos("Wallet")], [], 1, 0, 0),
        ("a genuinely new holding stays a diff",
         [], [pos("Staking")], 0, 1, 0),
        ("two identical holdings collapse one-for-one, not many-for-one",
         [pos("Wallet"), pos("Wallet")], [pos("Staking")], 1, 0, 1),
    ]
    failures = []
    for why, lost, gained, want_l, want_g, want_i in cases:
        l, g, i = split_reclassified(lost, gained, expect)
        if (len(l), len(g), len(i)) != (want_l, want_g, want_i):
            failures.append(f"  {why}: expected lost/gained/info {want_l}/{want_g}/{want_i}, "
                            f"got {len(l)}/{len(g)}/{len(i)}")

    # The coordinate narrowing, which the first version of this gate got wrong: the manifest is keyed on
    # 42-char addresses while snapshots store 66-char bytes32, so a missing narrowing silently made the
    # gained-meta-instance downgrade unreachable. The self-test did not cover that branch, which is why the
    # dead code shipped — these cases exist so it cannot happen again.
    coord_cases = [
        ("0x" + "0" * 24 + "a" * 40, "0x" + "a" * 40, "a bytes32 coordinate narrows to its address"),
        ("0x" + "0" * 24 + "A" * 40, "0x" + "a" * 40, "and lowercases"),
        ("0x" + "b" * 40, "0x" + "b" * 40, "an address is already narrow"),
        ("0x" + "c" * 64, "0x" + "c" * 40, "a raw bytes32 marketId narrows to something not in any manifest"),
    ]
    for given, want, why in coord_cases:
        got = coord_to_address(given)
        if got != want:
            failures.append(f"  coord narrowing: expected {want} got {got} - {why}")

    # THROUGH diff_chain, not just the helper: the helper cases above stay green if the CALL SITE forgets to
    # narrow, which is precisely the defect that shipped. This one fails unless the production path narrows.
    coord32 = "0x" + "0" * 24 + "d" * 40
    exp_one = {"0x" + "d" * 40: {"symbol": "wstETH", "adapter": "LidoStakedEthWalletMeta",
                                 "toPositionKind": "Staking"}}
    base = {"assets": [], "accounts": [], "proxy": "", "implementation": "",
            "erc20DefaultBalanceAdapter": "", "roles": {}, "version": 1, "usdDecimals": 8,
            "metaInstanceTotal": 0}
    a_one = dict(base, adapters=[{"configKey": "LidoStakedEthWalletMeta", "address": "0x1",
                                  "adapterType": "Custom", "metaInstances": []}])
    b_one = dict(base, adapters=[{"configKey": "LidoStakedEthWalletMeta", "address": "0x1",
                                  "adapterType": "Custom", "metaInstances": [coord32]}])
    gained = [ln for ln in diff_chain(a_one, b_one, 0.01, exp_one) if "GAINED meta instance" in ln]
    if not gained or not gained[0].startswith("INFO"):
        failures.append("  gained-instance downgrade did not fire through diff_chain "
                        f"(got {gained or 'no line'}) - the call site must narrow the bytes32 coordinate")

    # And the metaInstanceTotal downgrade: only the EXACT manifest count is expected.
    total_cases = [(3, 3, True, "the exact manifest count is expected"),
                   (3, 4, False, "one more than the manifest is not"),
                   (3, 2, False, "one fewer is not"),
                   (3, 0, False, "no change with a non-empty manifest is not reached")]
    for manifest_n, delta, want_info, why in total_cases:
        exp = {f"0x{i:040x}": {"symbol": "T", "adapter": "A", "toPositionKind": "Staking"}
               for i in range(manifest_n)}
        a = {"metaInstanceTotal": 10, "assets": [], "adapters": [], "accounts": [],
             "proxy": "", "implementation": "", "erc20DefaultBalanceAdapter": "",
             "roles": {}, "version": 1, "usdDecimals": 8}
        b = dict(a, metaInstanceTotal=10 + delta)
        if delta == 0:
            continue  # no line is emitted at all when the totals match
        lines = [ln for ln in diff_chain(a, b, 0.01, exp) if "metaInstanceTotal" in ln]
        is_info = bool(lines) and lines[0].startswith("INFO")
        if is_info != want_info:
            failures.append(f"  metaInstanceTotal: expected {'INFO' if want_info else 'DIFF'} - {why}")

    # The committed manifest must be loadable and internally consistent.
    recl = load_reclassifications()
    for cid, rows in recl.items():
        for addr, r in rows.items():
            if not addr.startswith("0x") or len(addr) != 42:
                failures.append(f"  chain {cid}: bad asset address {addr!r}")
            if r["toPositionKind"] not in ("Staking", "Supplied"):
                failures.append(f"  chain {cid} {r['symbol']}: unexpected kind {r['toPositionKind']!r}")

    if failures:
        print("SELF-TEST FAILED:\n" + "\n".join(failures))
        return 1
    print(f"self-test OK: {len(cases)} pairing + {len(coord_cases)} narrowing + {len(total_cases)} total cases; manifest has "
          f"{sum(len(v) for v in recl.values())} row(s) across {len(recl)} chain(s)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("before", nargs="?")
    ap.add_argument("after", nargs="?")
    ap.add_argument("--tolerance", type=float, default=0.01,
                    help="max relative NAV drift treated as price movement (default 1%%)")
    ap.add_argument("--json")
    ap.add_argument("--no-reclassification", action="store_true",
                    help="ignore reclassification.json and report every move as a DIFF")
    ap.add_argument("--self-test", action="store_true", help="pin the reclassification pairing logic")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if not args.before or not args.after:
        ap.error("before and after are required unless --self-test is given")

    recl = {} if args.no_reclassification else load_reclassifications()
    if recl:
        print(f"reclassification manifest: {sum(len(v) for v in recl.values())} expected move(s) "
              f"across {len(recl)} chain(s)")

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
        lines = diff_chain(A[cid], B[cid], args.tolerance, recl.get(cid))
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
