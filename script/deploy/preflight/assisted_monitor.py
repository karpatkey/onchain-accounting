#!/usr/bin/env python3
"""Free-slot + role monitor for the assisted balance adapters (ADR 0030 Rollout step 1, S13; Vigilo L-01).

READ-ONLY: eth_calls and Etherscan log reads only; it never sends a transaction.

Per chain, for every assisted adapter in `deployments/<chainId>.json` `balanceAdapters` (keys ending in `Assisted`):
  - cache limits read from the contract: the per-account cap (`MAX_TOKEN_IDS()` / `MAX_POSITIONS()`, the public constant
    each member's internal `_maxCoords()` returns) and `OWNER_RESERVE()`; keeper limit = cap - OWNER_RESERVE (0 when
    cap <= reserve, as `AssistedCoordCache._submitFor` does);
  - per `--accounts` account: `coordsOf(account)` length vs the keeper limit — WARN at >= 80 % of it, ALERT at >= it
    (the keeper path is then closed for the account and only `OWNER_RESERVE` - (used - keeper limit) owner slots are
    left; ADR 0030 S13 recovery is `evict`);
  - `SUBMITTER_ROLE` and `DEFAULT_ADMIN_ROLE` holders: candidates from `RoleGranted` logs (Etherscan V2), each
    confirmed live with `hasRole`. Admin must be exactly the expected set (default: the chain's `securityCouncil`);
    a submitter must be in `--expect-submitter` (default none — before the grant, any holder is unexpected);
  - whether the adapter is registered on the NAV proxy (`getAllAdapters`) — informational only.

Exit: 0 clean (WARNs allowed), 1 any ALERT or unexpected / missing role holder, 2 a read failed.

usage: assisted_monitor.py --accounts safes.txt [--chain 1 --chain 100] [--expect-submitter 0x…]
                           [--expect-admin 0x…] [--json out.json]
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import requests

import chainlib as c
import seed_assisted as s

SEL_OWNER_RESERVE = "ede6fade"  # OWNER_RESERVE()
SEL_CAP = ("696ef305", "f7b24e08")  # MAX_TOKEN_IDS() (ether.fi, Nexus) / MAX_POSITIONS() (StakeWise)
SEL_SUBMITTER_ROLE = "91712a0b"  # SUBMITTER_ROLE()
SEL_HAS_ROLE = "91d14854"  # hasRole(bytes32,address)
SEL_GET_ALL_ADAPTERS = "e31ada97"  # getAllAdapters()
TOPIC_ROLE_GRANTED = "0x2f8788117e7eff1d82e926ec794901d17c78024a50270940304540a733656f0d"
DEFAULT_ADMIN_ROLE = "0x" + "00" * 32
SUBMITTER_ROLE = "0x12b80c3c1a8f58857e0e80e1961585f574502e089ca974eb9fcf05cf904fe012"  # keccak256("SUBMITTER")
WARN_FRACTION = 0.8


class MonitorError(Exception):
    pass


# ---- ABI (hand-rolled, pinned against cast vectors in the tests) ----

def encode_has_role(role: str, account: str) -> str:
    r = role[2:] if role.startswith("0x") else role
    if len(r) != 64:
        raise MonitorError(f"not a bytes32 role: {role!r}")
    return "0x" + SEL_HAS_ROLE + r.lower() + s._addr_word(account)


def encode_coords_of(account: str) -> str:
    return "0x" + s.SEL_COORDS_OF + s._addr_word(account)


def decode_uint(ret: str) -> int:
    h = (ret or "")[2:] if (ret or "").startswith("0x") else (ret or "")
    if len(h) < 64:
        raise MonitorError(f"malformed uint reply {str(ret)[:66]}")
    return int(h[0:64], 16)


def decode_bool(ret: str) -> bool:
    v = decode_uint(ret)
    if v > 1:
        raise MonitorError(f"malformed bool reply {str(ret)[:66]}")
    return v == 1


def decode_address_array(ret: str) -> list[str]:
    if not s.is_abi_array_reply(ret):
        raise MonitorError(f"malformed address[] reply {str(ret)[:66]}")
    h = ret[2:] if ret.startswith("0x") else ret
    n = int(h[64:128], 16)
    if len(h) < 128 + 64 * n:
        raise MonitorError("truncated address[] reply")
    return ["0x" + h[128 + 64 * i + 24:128 + 64 * (i + 1)].lower() for i in range(n)]


def coords_count(ret: str) -> int:
    if not s.is_abi_array_reply(ret):
        raise MonitorError(f"coordsOf answered {str(ret)[:66]} — not an assisted adapter")
    return s.array_len(ret)


# ---- Pure evaluation ----

def keeper_limit(cap: int, reserve: int) -> int:
    """Mirrors `AssistedCoordCache._submitFor`: cap - OWNER_RESERVE, or 0 (keeper path disabled)."""
    return cap - reserve if cap > reserve else 0


def slot_status(used: int, klimit: int) -> str:
    if used >= klimit:
        return "ALERT"
    if used >= WARN_FRACTION * klimit:
        return "WARN"
    return "OK"


def role_findings(kind: str, holders: list[str], expected: set[str], must_hold: bool) -> list[str]:
    """Problems with a role's live holder set: anyone outside `expected`, and (when `must_hold`) an expected holder
    that does not hold it."""
    h = {x.lower() for x in holders}
    e = {x.lower() for x in expected}
    out = [f"unexpected {kind} holder {x}" for x in sorted(h - e)]
    if must_hold:
        out += [f"expected {kind} holder {x} does not hold the role" for x in sorted(e - h)]
    return out


# ---- Reads (callables injected so tests stub them) ----

def read_cap(call, adapter: str) -> int:
    for sel in SEL_CAP:
        try:
            return decode_uint(call(adapter, "0x" + sel))
        except c.RpcError as e:
            if "revert" not in str(e).lower():
                raise
    raise MonitorError(f"{adapter}: neither MAX_TOKEN_IDS() nor MAX_POSITIONS() answered")


def role_holders(call, logs, chain: int, adapter: str, role: str) -> list[str]:
    """Every address a `RoleGranted(role, account, …)` log names that still `hasRole` (a revoke drops it)."""
    found = logs(chain, adapter, {"topic0": TOPIC_ROLE_GRANTED, "topic1": role.lower(), "topic0_1_opr": "and"}, 0)
    candidates = sorted({"0x" + lg["topics"][2][-40:].lower() for lg in found})
    return [a for a in candidates if decode_bool(call(adapter, encode_has_role(role, a)))]


def check_adapter(call, logs, chain: int, name: str, adapter: str, accounts: list[str], nav_adapters: set[str] | None,
                  expect_admin: set[str], expect_submitter: set[str]) -> dict:
    cap = read_cap(call, adapter)
    reserve = decode_uint(call(adapter, "0x" + SEL_OWNER_RESERVE))
    klimit = keeper_limit(cap, reserve)
    role = "0x" + call(adapter, "0x" + SEL_SUBMITTER_ROLE)[2:66].lower()
    problems = []
    if role != SUBMITTER_ROLE:
        problems.append(f"SUBMITTER_ROLE() is {role}, expected keccak256('SUBMITTER')")
    rows = []
    for a in accounts:
        used = coords_count(call(adapter, encode_coords_of(a)))
        rows.append({"account": a, "used": used, "keeperLimit": klimit, "cap": cap,
                     "keeperFree": max(klimit - used, 0), "ownerFree": max(cap - used, 0),
                     "status": slot_status(used, klimit)})
    admins = role_holders(call, logs, chain, adapter, DEFAULT_ADMIN_ROLE)
    submitters = role_holders(call, logs, chain, adapter, role)
    problems += role_findings("DEFAULT_ADMIN_ROLE", admins, expect_admin, must_hold=True)
    problems += role_findings("SUBMITTER_ROLE", submitters, expect_submitter, must_hold=False)
    return {"chain": chain, "name": name, "adapter": adapter, "cap": cap, "ownerReserve": reserve,
            "keeperLimit": klimit, "accounts": rows, "admins": admins, "submitters": submitters,
            "registeredOnNav": None if nav_adapters is None else adapter.lower() in nav_adapters,
            "problems": problems}


def assisted_adapters(record: dict) -> list[tuple[str, str]]:
    return sorted((k, v) for k, v in (record.get("balanceAdapters") or {}).items()
                  if k.endswith("Assisted") and c.is_address(v))


def run_chain(chain: int, call, logs, record: dict, accounts: list[str], expect_admin: set[str],
              expect_submitter: set[str]) -> dict:
    nav = record.get("NAVCalculatorProxy")
    nav_adapters = {x for x in decode_address_array(call(nav, "0x" + SEL_GET_ALL_ADAPTERS))} if c.is_address(nav) else None
    adapters = [check_adapter(call, logs, chain, n, a, accounts, nav_adapters, expect_admin, expect_submitter)
                for n, a in assisted_adapters(record)]
    return {"chain": chain, "nav": nav, "adapters": adapters}


def verdict(chains: list[dict]) -> int:
    for ch in chains:
        if ch.get("error"):
            return 2
    for ch in chains:
        for ad in ch["adapters"]:
            if ad["problems"] or any(r["status"] == "ALERT" for r in ad["accounts"]):
                return 1
    return 0


def render(chains: list[dict]) -> str:
    out = []
    for ch in chains:
        out.append(f"== chain {ch['chain']}  NAV {ch.get('nav')}")
        if ch.get("error"):
            out.append(f"  ERROR {ch['error']}")
            continue
        if not ch["adapters"]:
            out.append("  (no assisted adapters recorded)")
        for ad in ch["adapters"]:
            reg = {True: "yes", False: "no", None: "n/a"}[ad["registeredOnNav"]]
            out.append(f"  {ad['name']} {ad['adapter']}  cap {ad['cap']}  reserve {ad['ownerReserve']}  "
                       f"keeper limit {ad['keeperLimit']}  on NAV: {reg}")
            out.append(f"    {'account':<44}{'used':>6}{'keeper':>8}{'cap':>6}  status")
            for r in ad["accounts"]:
                out.append(f"    {r['account']:<44}{r['used']:>6}{r['keeperLimit']:>8}{r['cap']:>6}  {r['status']}")
            out.append(f"    admins:     {', '.join(ad['admins']) or '(none)'}")
            out.append(f"    submitters: {', '.join(ad['submitters']) or '(none)'}")
            for p in ad["problems"]:
                out.append(f"    PROBLEM {p}")
    return "\n".join(out)


def redact(msg: str, secrets: list[str]) -> str:
    for x in secrets:
        if x:
            msg = msg.replace(x, "***")
    return msg


def read_accounts(path: str) -> list[str]:
    out = []
    for ln in open(path):
        x = ln.split("#", 1)[0].strip()
        if not x:
            continue
        if not c.is_address(x):
            raise MonitorError(f"bad account in {path}: {x}")
        out.append(x.lower())
    return list(dict.fromkeys(out))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--accounts", required=True, help="one account per line (# comments allowed)")
    ap.add_argument("--chain", type=int, action="append", help="repeatable; default 1 and 100")
    ap.add_argument("--expect-submitter", action="append", default=[],
                    help="allowed SUBMITTER_ROLE holder (repeatable); any other holder is a problem")
    ap.add_argument("--expect-admin", action="append", default=[],
                    help="expected DEFAULT_ADMIN_ROLE holder (repeatable); default the chain's securityCouncil")
    ap.add_argument("--json", help="write the full report here")
    a = ap.parse_args(argv)
    for x in a.expect_submitter + a.expect_admin:
        if not c.is_address(x):
            raise MonitorError(f"not an address: {x}")
    accounts = read_accounts(a.accounts)
    c.load_env()
    chains = []
    for chain in a.chain or [1, 100]:
        url, note = c.resolve_rpc(chain)
        secrets = [url or "", os.environ.get("ETHERSCAN_API_KEY", ""), os.environ.get("ALCHEMY_API_KEY", "")]
        if not url:
            chains.append({"chain": chain, "error": f"no RPC: {note}", "adapters": []})
            continue
        council = (c.chain_config(chain).get("addresses") or {}).get("securityCouncil")
        expect_admin = {x.lower() for x in a.expect_admin} or ({council.lower()} if c.is_address(council) else set())
        if not expect_admin:
            chains.append({"chain": chain, "error": "no expected admin (no securityCouncil, no --expect-admin)",
                           "adapters": []})
            continue
        try:
            chains.append(run_chain(chain, lambda to, d: c.eth_call(url, to, d), s.etherscan_logs, c.deployment(chain),
                                    accounts, expect_admin, {x.lower() for x in a.expect_submitter}))
        except (c.RpcError, s.SeedError, MonitorError, requests.RequestException, OSError, ValueError, KeyError) as e:
            chains.append({"chain": chain, "error": redact(f"{type(e).__name__}: {e}", secrets)[:240], "adapters": []})
    print(render(chains))
    code = verdict(chains)
    if a.json:
        json.dump({"exit": code, "chains": chains}, open(a.json, "w"), indent=2)
    print({0: "OK", 1: "ALERT / unexpected role holder", 2: "READ FAILURE"}[code], file=sys.stderr)
    return code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except MonitorError as e:
        print(f"assisted_monitor: {e}", file=sys.stderr)
        sys.exit(2)
