#!/usr/bin/env python3
"""Emit the PR #338 wallet-yield registrations as ONE Transaction-Builder batch for the ops Safe.

The swap batch comes from `SwapMetaAdapter.plan()`; the wallet-yield family's
`addMetaBalanceAdapter(walletAdapter, coords)` calls had no emitter (plan MEDIUM-3: do not let `06` do them).
This writes `safe-transactions/<chainId>-wallet-adds.json`, in the same format `plan()` writes, so
`ops_safe.py exec` runs all of a chain's wallet adds as one atomic MultiSend AFTER the swap batch.

Inputs, all from the tree: every ENABLED `*Wallet*` key in
`contracts-deployment-config/meta-balance-adapters/<id>.json`, its adapter address from
`deployments/<id>.json` (written by `04`), and its coordinates from
`nav-config/meta-balance-adapters/<id>.json .<key>.instances` (token addresses, widened to bytes32 — the
same encoding `06_Configure` uses). Refuses a key with no recorded address or no instances.

usage:
  emit_wallet_adds_batch.py <chainId> --safe 0x… [--out FILE]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

import chainlib as c

DEPLOY_CFG_DIR = c.CONTRACTS_CONFIG_DIR / "meta-balance-adapters"
NAV_CFG_DIR = c.NAV_CONFIG_DIR / "meta-balance-adapters"
ADD_SIG = "addMetaBalanceAdapter(address,bytes32[])"


def widen(addr: str) -> str:
    h = addr[2:] if addr.lower().startswith("0x") else addr
    if len(h) != 40:
        raise RuntimeError(f"not an address: {addr}")
    int(h, 16)
    return "0x" + "0" * 24 + h.lower()


def wallet_entries(deploy_cfg: dict, nav_cfg: dict, record: dict) -> list[tuple[str, str, list[str]]]:
    """(name, adapter, coords) for every enabled wallet key, in config order. Raises on any gap."""
    out = []
    adapters = record.get("balanceAdapters") or {}
    for name, entry in deploy_cfg.items():
        if name.startswith("$") or "Wallet" not in name or not isinstance(entry, dict) or not entry.get("enabled"):
            continue
        addr = adapters.get(name) or ""
        if not c.is_address(addr) or int(addr, 16) == 0:
            raise RuntimeError(f"{name}: no deployed address in the record — run 04 first")
        inst = (nav_cfg.get(name) or {}).get("instances") or []
        if not inst:
            raise RuntimeError(f"{name}: enabled but has no instances in the NAV meta config")
        out.append((name, addr, [widen(t) for t in inst]))
    return out


def calldata(adapter: str, coords: list[str]) -> str:
    r = subprocess.run(["cast", "calldata", ADD_SIG, adapter, "[" + ",".join(coords) + "]"],
                       capture_output=True, text=True, check=True)
    return r.stdout.strip()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("chain", type=int)
    ap.add_argument("--safe", required=True)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    dcfg_p, ncfg_p = DEPLOY_CFG_DIR / f"{a.chain}.json", NAV_CFG_DIR / f"{a.chain}.json"
    if not dcfg_p.exists():
        print(f"no meta deploy config for chain {a.chain} — nothing to emit")
        return 0
    record = c.deployment(a.chain)
    nav = record.get("NAVCalculatorProxy") or ""
    if not c.is_address(nav):
        raise RuntimeError(f"deployments/{a.chain}.json has no NAVCalculatorProxy")
    entries = wallet_entries(json.loads(dcfg_p.read_text()),
                             json.loads(ncfg_p.read_text()) if ncfg_p.exists() else {}, record)
    if not entries:
        print(f"chain {a.chain}: no enabled wallet-yield adapters — nothing to emit")
        return 0
    batch = {
        "version": "1.0",
        "chainId": str(a.chain),
        "createdAt": 0,
        "meta": {
            "name": "Register wallet-yield adapters (PR #338)",
            "description": "addMetaBalanceAdapter(walletAdapter, coords) per enabled wallet-yield adapter. Run "
                           "AFTER the swap batch, as one MultiSend via ops_safe.py exec.",
            "createdFromSafeAddress": a.safe,
            "createdFromOwnerAddress": "",
        },
        "transactions": [{"to": nav, "value": "0", "data": calldata(addr, coords), "operation": 0}
                         for _, addr, coords in entries],
    }
    out = Path(a.out) if a.out else c.REPO / "safe-transactions" / f"{a.chain}-wallet-adds.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(batch, indent=2) + "\n")
    n = sum(len(x[2]) for x in entries)
    print(f"chain {a.chain}: {len(entries)} wallet adapter(s), {n} coordinate(s) -> {out}")
    for name, addr, coords in entries:
        print(f"  {name:40} {addr}  {len(coords)} coord(s)")
    return 0


if __name__ == "__main__":
    c.load_env()
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.CalledProcessError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
