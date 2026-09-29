#!/usr/bin/env python3
"""Snapshot the deployment record and surgically clear ONLY the meta-adapter keys, for the #338 swap.

WHY THIS EXISTS (and why `reset_deployment_records.py` is the wrong tool here)
-----------------------------------------------------------------------------
PR #338 gas-meters the shared `MetaBalanceAdapter` base (404cce13), so every meta adapter's CREATE2
address MOVES. The migration is an IN-PLACE upgrade: the NAVCalculator PROXY, its libraries and impl
are handled by `01_2` (the new impl/libs deploy at fresh CREATE2 addresses regardless of the record),
and only the meta ADAPTERS must be forced to redeploy. `04_DeployBalanceAdapters` is
skip-if-recorded (`_deployIfEnabled` early-returns when `deployments/<id>.json .balanceAdapters.<name>`
is non-zero), so a moved meta adapter must have its record key cleared or `04` silently keeps the OLD
address.

`reset_deployment_records.py` clears the WHOLE NAV stack (proxy, libs, impl, every adapter, every
feed) — correct for a from-scratch redeploy, WRONG for this in-place upgrade, where blanking
`NAVCalculatorProxy` et al. would be destructive. This tool is the surgical counterpart: it touches
ONLY the enabled meta-adapter keys.

IT ALSO PRODUCES `deployments/<id>.pre-swap.json`
-------------------------------------------------
`script/manage/SwapMetaAdapter.s.sol::plan()` reads the OLD (pre-redeploy) address of each meta
adapter from `deployments/<id>.pre-swap.json` and the NEW address from `deployments/<id>.json`. That
snapshot has no other producer in the repo, so `plan()` cannot run without this step. This tool writes
it — a full copy of the record taken BEFORE the keys are cleared — so the OLD addresses survive the
clear that `04` needs.

ORDER IN THE MIGRATION
----------------------
  1. this tool  --apply         # snapshot -> .pre-swap.json, clear enabled meta keys in the record
  2. 01_2_DeployNAVImplementation  (new impl + libs, fleet-wide CREATE2)
  3. 04_DeployBalanceAdapters      (redeploys the cleared meta adapters at their NEW addresses)
  4. SwapMetaAdapter.plan()        (reads OLD from .pre-swap.json, NEW from the record; emits the swap)

usage:
  python3 snapshot_and_clear_meta.py                     # DRY RUN over all asset chains with a meta config
  python3 snapshot_and_clear_meta.py --apply             # write .pre-swap.json + clear, all such chains
  python3 snapshot_and_clear_meta.py --apply 1 42161     # only these chains
"""
from __future__ import annotations

import argparse
import json
import sys
import time

import chainlib as c

META_CONFIG_DIR = c.CONTRACTS_CONFIG_DIR / "meta-balance-adapters"
ADAPTERS_SECTION = "balanceAdapters"


def enabled_meta_names(chain_id: int) -> list[str]:
    """Enabled meta-adapter config keys for a chain (the set `04` will redeploy), `$`-keys filtered."""
    cfg_path = META_CONFIG_DIR / f"{chain_id}.json"
    if not cfg_path.exists():
        return []
    cfg = json.loads(cfg_path.read_text())
    names = []
    for name, entry in cfg.items():
        if name.startswith("$"):
            continue  # $schema / $comment, never an adapter
        if not isinstance(entry, dict):
            raise RuntimeError(f"{cfg_path}: entry {name!r} is not an object")
        if entry.get("enabled", False):
            names.append(name)
    return names


def plan_for(chain_id: int) -> tuple[dict, list[str], list[str]]:
    """Return (new_record, cleared_lines, warnings) without writing anything."""
    rec = c.deployment(chain_id)
    out = json.loads(json.dumps(rec))  # deep copy, preserves key order
    block = out.get(ADAPTERS_SECTION)
    if not isinstance(block, dict):
        raise RuntimeError(f"deployments/{chain_id}.json has no {ADAPTERS_SECTION!r} object")

    cleared: list[str] = []
    warnings: list[str] = []
    for name in enabled_meta_names(chain_id):
        if name not in block:
            # `04` (via vm.writeJson) can create a missing key, but then there is no OLD address to
            # snapshot -> this adapter has no live predecessor to swap. Surface it rather than hide it.
            warnings.append(f"{name}: enabled in config but ABSENT from the record (no predecessor to swap)")
            continue
        addr = block[name]
        if addr in ("", None):
            warnings.append(f"{name}: already blank in the record (nothing to snapshot/clear)")
            continue
        cleared.append(f"{ADAPTERS_SECTION}.{name}: {addr} -> \"\"")
        block[name] = ""
    return out, cleared, warnings


# A preserved snapshot older than this is almost certainly left over from an earlier cycle or an aborted
# attempt (the file is untracked and nothing deletes it after a swap) — refuse rather than silently reuse it.
PRE_SWAP_MAX_AGE_S = 7 * 24 * 3600
PRE_SWAP_META_KEY = "$preSwap"


def check_preserved_snapshot(chain_id: int, snap: dict, record: dict, now: float | None = None) -> None:
    """Refuse to reuse a `.pre-swap.json` that is stale or does not belong to the current record.

    The snapshot is `plan()`'s ONLY source of OLD addresses, so a wrong one makes `plan()` skip real swaps
    ("predecessor not registered") or emit an incomplete batch. It must (a) carry this tool's capture stamp and be
    younger than PRE_SWAP_MAX_AGE_S, (b) name the same NAV proxy, and (c) agree with the current record on every
    NON-meta balance adapter (those do not move in this migration). Meta keys are expected to differ (cleared,
    then redeployed by 04). Raises RuntimeError — `raise`, not `assert`, so it survives `python3 -O`.
    """
    now = time.time() if now is None else now
    stamp = snap.get(PRE_SWAP_META_KEY) or {}
    at = stamp.get("capturedAtUnix")
    if not isinstance(at, (int, float)):
        raise RuntimeError(f"deployments/{chain_id}.pre-swap.json has no capture stamp ({PRE_SWAP_META_KEY}) — "
                           f"it was not written by this tool or predates the stamp; delete it and re-run --apply")
    if now - at > PRE_SWAP_MAX_AGE_S:
        raise RuntimeError(f"deployments/{chain_id}.pre-swap.json is {int((now - at) // 86400)} day(s) old — "
                           f"likely left over from an earlier cycle; delete it and re-run --apply")
    if (snap.get("NAVCalculatorProxy") or "").lower() != (record.get("NAVCalculatorProxy") or "").lower():
        raise RuntimeError(f"deployments/{chain_id}.pre-swap.json names a different NAVCalculatorProxy than the record")
    meta = set(enabled_meta_names(chain_id))
    sa, ra = snap.get(ADAPTERS_SECTION) or {}, record.get(ADAPTERS_SECTION) or {}
    drift = sorted(k for k in set(sa) | set(ra)
                   if k not in meta and (sa.get(k) or "").lower() != (ra.get(k) or "").lower())
    if drift:
        raise RuntimeError(f"deployments/{chain_id}.pre-swap.json disagrees with the record on non-meta adapter(s) "
                           f"{drift} — it is from a different state; delete it and re-run --apply")


def apply_chain(chain_id: int, new_record: dict) -> bool:
    """Write the surgically-cleared record, and the `.pre-swap.json` snapshot IFF one does not already exist.

    PRESERVING an existing snapshot is the whole point (Copilot). The snapshot is `plan()`'s only source for
    the OLD (pre-redeploy) addresses. A second `--apply` before the swap would otherwise re-snapshot the record
    that this very tool has already cleared (blank meta keys), destroying those OLD addresses and making `plan()`
    silently skip the swaps. So the first run captures them; every re-run leaves that snapshot untouched. To force
    a fresh snapshot (e.g. the first was taken from a wrong record), delete `<id>.pre-swap.json` by hand.

    Returns True if a new snapshot was written, False if an existing one was preserved.
    """
    src = c.DEPLOY_DIR / f"{chain_id}.json"
    pre_swap = c.DEPLOY_DIR / f"{chain_id}.pre-swap.json"
    snapshotted = False
    if not pre_swap.exists():
        # Full record, as-is, BEFORE the clear below — read fresh so it is the on-disk pre-clear state — plus a
        # capture stamp so a later re-run can tell a fresh snapshot from a stale leftover. SwapMetaAdapter.plan()
        # only reads `.balanceAdapters.<name>`, so the extra top-level key is inert for it.
        snap = c.deployment(chain_id)
        snap[PRE_SWAP_META_KEY] = {"capturedAtUnix": int(time.time()),
                                   "note": "written by snapshot_and_clear_meta.py; OLD addresses for SwapMetaAdapter.plan()"}
        pre_swap.write_text(json.dumps(snap, indent=2) + "\n")
        snapshotted = True
    else:
        check_preserved_snapshot(chain_id, json.loads(pre_swap.read_text()), c.deployment(chain_id))
    src.write_text(json.dumps(new_record, indent=2) + "\n")
    return snapshotted


def scope(explicit: list[int]) -> list[int]:
    """Explicit chain ids if given, else every deployed chain that has a meta-adapter config."""
    if explicit:
        return explicit
    return [cid for cid in c.deployed_chain_ids() if (META_CONFIG_DIR / f"{cid}.json").exists()]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true", help="write .pre-swap.json and clear the keys (default: dry run)")
    ap.add_argument("chains", nargs="*", type=int, help="chain ids (default: all deployed chains with a meta config)")
    args = ap.parse_args()

    chains = scope(args.chains)
    if not chains:
        print("No chains in scope (none deployed with a meta-adapter config).")
        return 0

    total_cleared = 0
    total_warn = 0
    for cid in chains:
        src = c.DEPLOY_DIR / f"{cid}.json"
        if not src.exists():
            print(f"  {cid:8} SKIP — no deployment record")
            continue
        new, cleared, warnings = plan_for(cid)
        total_cleared += len(cleared)
        total_warn += len(warnings)
        name = c.chain_config(cid).get("name", "?")
        print(f"  {cid:8} {name:16} {len(cleared):3} meta key(s) to clear"
              + ("" if cleared else "  (nothing to clear)"))
        for line in cleared:
            print(f"           {line}")
        for w in warnings:
            print(f"           WARN {w}")

        if args.apply:
            snapshotted = apply_chain(cid, new)
            if not snapshotted:
                print(f"           (kept existing {cid}.pre-swap.json — OLD addresses preserved)")

    if args.apply:
        print(f"\n.pre-swap.json snapshots written/validated; cleared {total_cleared} meta key(s) across "
              f"{len(chains)} chain(s).")
        print("NEXT: run 01_2 then 04 (PERSIST_DEPLOYMENTS=1), then SwapMetaAdapter.plan().")
    else:
        print(f"\nDRY RUN — {total_cleared} meta key(s) would be cleared across {len(chains)} chain(s) "
              f"({total_warn} warning(s)). Re-run with --apply to write.")
    return 0


if __name__ == "__main__":
    c.load_env()
    sys.exit(main())
