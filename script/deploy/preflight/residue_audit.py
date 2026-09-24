#!/usr/bin/env python3
"""Find dormant `_metaInstances` arrays on adapters the NAV no longer has registered.

WHY THIS EXISTS
---------------
A deregistered meta adapter can still carry coordinates. `removeBalanceAdapter` did not clear
`_metaInstances` before the fix in this PR, and that fix is not retroactive: the array written by the
PRE-upgrade implementation is still there. Such an array is inert while the adapter is deregistered —
nothing queries it — but `addMetaBalanceAdapter` is one MANAGER call, and re-registering a superseded
address revives the coordinate alongside the live adapter. NAV then sums both readings with no health
flag, because both are well-formed: the +$11,375.92 shape (issue #335).

`_release`'s ownership gate removes the claim-theft consequence, and `addMetaBalanceAdapter` now WIPES
on registration, so no NEW residue can be created and a re-registration cannot revive one. What neither
fixes is the residue that already exists on chain. `ClearDormantMetaInstances` cleans exactly ONE such
array, found by hand. Nothing enumerates the rest — the backfill script and its duplicate precondition
both iterate `getAllAdapters()`, which by definition excludes a deregistered adapter.

WHAT IT CHECKS, AND WHAT IT CANNOT
----------------------------------
Candidate addresses come from the git history of `script/config/deployments/<chainId>.json` (every
`balanceAdapters` value in every revision) plus the addresses currently registered on chain. For each
candidate the script reads `getMetaInstances(address)` and reports any NON-EMPTY set whose adapter is
NOT currently registered.

This is a lower bound, and saying so is the point. An adapter deployed and deregistered without ever
being written to the record — or written in a revision that predates the file — is invisible here. The
deployment record has also been overwritten in place by swap scripts, so a predecessor can be absent
from every revision. Treat a clean run as "none found in the recorded history", never as "none exist".

usage:
  python3 script/deploy/preflight/residue_audit.py               # every configured chain
  python3 script/deploy/preflight/residue_audit.py --chain 1
  python3 script/deploy/preflight/residue_audit.py --self-test
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
DEPLOYMENTS = "script/config/deployments/{chain}.json"

SIG_META = "getMetaInstances(address)"
SIG_ALL = "getAllAdapters()"

# Selectors as LITERALS, not computed. The preflight CI job installs only `requests`, so importing a keccak
# backend here made this gate fail on the runner while passing locally — the gate's own dependency breaking
# the gate. They are constants of the ABI, so a literal is as correct as a derivation; `selector()` below
# still derives them WHEN a backend happens to be available, and the self-test cross-checks the two, so a
# typo cannot survive a local run.
SELECTORS = {
    SIG_META: "0x888f2262",
    SIG_ALL: "0xe31ada97",
}


def _keccak_or_none(data: bytes):
    """keccak256 if a backend is installed, else None. Never a hard dependency of this module."""
    try:
        from eth_hash.auto import keccak  # noqa: PLC0415 - optional, and deliberately lazy
    except Exception:  # noqa: BLE001 - any import failure means "unavailable", not "broken"
        return None
    return keccak(data)


def selector(sig: str) -> str:
    """The 4-byte selector. Literal by default; derived and cross-checked when a backend is present."""
    lit = SELECTORS.get(sig)
    got = _keccak_or_none(sig.encode())
    if got is not None:
        derived = "0x" + got.hex()[:8]
        if lit is not None and derived != lit:
            raise SystemExit(f"selector literal for {sig} is {lit} but keccak says {derived}")
        return derived
    if lit is None:
        raise SystemExit(f"no selector literal for {sig} and no keccak backend to derive one")
    return lit


def rpc(url: str, to: str, data: str) -> str:
    req = urllib.request.Request(
        url,
        method="POST",
        headers={"Content-Type": "application/json"},
        data=json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": "eth_call", "params": [{"to": to, "data": data}, "latest"]}
        ).encode(),
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.load(r)
    if "error" in out:
        raise RuntimeError(out["error"])
    return out["result"]


def decode_bytes32_array(hexstr: str) -> list[str]:
    """ABI-decode a `bytes32[]` return value."""
    b = bytes.fromhex(hexstr[2:])
    if len(b) < 64:
        return []
    n = int.from_bytes(b[32:64], "big")
    return ["0x" + b[64 + 32 * i : 96 + 32 * i].hex() for i in range(n)]


def decode_address_array(hexstr: str) -> list[str]:
    b = bytes.fromhex(hexstr[2:])
    if len(b) < 64:
        return []
    n = int.from_bytes(b[32:64], "big")
    return ["0x" + b[64 + 32 * i + 12 : 96 + 32 * i].hex() for i in range(n)]


def historical_adapters(chain: int) -> set[str]:
    """Every `balanceAdapters` value in every committed revision of the chain's deployment record."""
    path = DEPLOYMENTS.format(chain=chain)
    revs = subprocess.run(
        ["git", "log", "--format=%H", "--", path], cwd=REPO, capture_output=True, text=True
    ).stdout.split()
    found: set[str] = set()
    for rev in revs:
        blob = subprocess.run(
            ["git", "show", f"{rev}:{path}"], cwd=REPO, capture_output=True, text=True
        ).stdout
        if not blob.strip():
            continue
        try:
            d = json.loads(blob)
        except json.JSONDecodeError:
            continue
        for value in (d.get("balanceAdapters") or {}).values():
            if isinstance(value, str) and value.startswith("0x") and len(value) == 42:
                found.add(value.lower())
    return found


def audit_chain(chain: int, url: str, nav: str) -> list[tuple[str, int]]:
    sel_meta, sel_reg, sel_all = selector(SIG_META), selector(SIG_REG), selector(SIG_ALL)
    registered = {a.lower() for a in decode_address_array(rpc(url, nav, sel_all))}
    candidates = historical_adapters(chain) | registered
    print(f"  chain {chain}: {len(candidates)} candidate address(es), {len(registered)} currently registered")

    residue: list[tuple[str, int]] = []
    for addr in sorted(candidates):
        if addr in registered:
            continue  # a registered adapter's set is governed, not residue
        arg = sel_meta + "0" * 24 + addr[2:]
        try:
            coords = decode_bytes32_array(rpc(url, nav, arg))
        except Exception as exc:  # noqa: BLE001 - a failed probe must not look like a clean result
            print(f"    !! {addr}: probe FAILED ({exc}) - treat as UNKNOWN, not clean")
            continue
        if coords:
            residue.append((addr, len(coords)))
            print(f"    RESIDUE {addr} holds {len(coords)} coordinate(s): {', '.join(coords[:4])}")
    return residue


def self_test() -> int:
    """Pin the decoders, which are the only part that can be wrong without an RPC."""
    failures = []
    # Selector agreement is only checkable where a keccak backend exists; on the CI runner it does not, and
    # the literals are the point. Report which path ran so a green line cannot be mistaken for the stronger one.
    if _keccak_or_none(b"") is None:
        print("  (no keccak backend: selector literals used, derivation not cross-checked)")
    else:
        for sig, lit in SELECTORS.items():
            if selector(sig) != lit:
                failures.append(f"  selector literal disagrees with keccak for {sig}")
    empty = "0x" + "20".rjust(64, "0") + "0".rjust(64, "0")
    if decode_bytes32_array(empty) != []:
        failures.append("  an empty bytes32[] must decode to []")
    one = "0x" + "20".rjust(64, "0") + "1".rjust(64, "0") + "ab".ljust(64, "0")
    got = decode_bytes32_array(one)
    if got != ["0x" + "ab".ljust(64, "0")]:
        failures.append(f"  one-element bytes32[] decoded wrong: {got}")
    addr = "0x" + "20".rjust(64, "0") + "1".rjust(64, "0") + ("cd" * 20).rjust(64, "0")
    got_a = decode_address_array(addr)
    if got_a != ["0x" + "cd" * 20]:
        failures.append(f"  one-element address[] decoded wrong: {got_a}")
    if decode_bytes32_array("0x") != [] or decode_address_array("0x") != []:
        failures.append("  a short/empty return must decode to [] rather than raising")
    if failures:
        print("SELF-TEST FAILED:\n" + "\n".join(failures))
        return 1
    print("self-test OK: selector + 5 decoder cases")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--chain", type=int, action="append", help="chain id (repeatable); default: 1")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()

    chains = args.chain or [1]
    total = 0
    for chain in chains:
        record = json.loads((REPO / DEPLOYMENTS.format(chain=chain)).read_text())
        nav = record.get("NAVCalculatorProxy")
        if not nav:
            print(f"  chain {chain}: no NAVCalculatorProxy in the record, skipping")
            continue
        url = os.environ.get("MAINNET_URL") if chain == 1 else os.environ.get(f"CHAIN_{chain}_URL")
        if not url:
            print(f"  chain {chain}: no RPC in the environment, skipping")
            continue
        total += len(audit_chain(chain, url, nav))

    print(f"\n{total} dormant instance set(s) found on deregistered adapters.")
    print("A clean run means NONE FOUND IN THE RECORDED HISTORY - it is a lower bound, not a proof.")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
