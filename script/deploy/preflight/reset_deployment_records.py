#!/usr/bin/env python3
"""Clear the deployment records so a from-scratch redeploy actually redeploys.

THE TRAP THIS EXISTS FOR
------------------------
`03_DeployPriceFeeds` and `04_DeployBalanceAdapters` are skip-if-already-deployed. Every feed's
`_deploy*` helper and `04`'s `_deployIfEnabled` (04:229-234) start with

    address deployed = _readAdapterDeployed(<section>, <name>);
    if (deployed != address(0)) { console2.log("  Already deployed at:", deployed); return; }

so re-running them against a populated `deployments/<chainId>.json` is a **silent no-op** — the run
"succeeds", logs "Already deployed", writes nothing, and `06_Configure` then registers the OLD
contracts on the NEW proxy. Nothing fails; the deploy is simply wrong.

WHY WRITE "" RATHER THAN DELETE THE KEY
---------------------------------------
`ConfigReader._readAddrOrZero` (ConfigReader.sol:216) treats a key as "not deployed" when the value
is the empty string, a `YOUR_…` placeholder, or the zero address — but it first requires
`vm.keyExists`. Writing `""` therefore reads as address(0) while keeping the key present, so
`vm.writeJson(..., ".balanceAdapters.<name>")` in `ConfigReader.writeAdapterAddress` writes back into
an existing JSON pointer. Deleting keys would rely on forge inserting missing pointers, which is not
a guarantee worth betting a 24-chain deploy on. Key order is preserved, so the diff stays readable.

WHAT IS CLEARED, AND WHAT IS NOT
--------------------------------
Cleared (the NAV stack — everything the redeploy replaces):
  PriceFeedLib, NavRegistryLib, NAVCalculatorImplementation, NAVCalculatorProxy,
  every balanceAdapters.* entry (ERC20Default included — `02_2` rewrites it from the new
  `initialize()`), every customPriceFeeds.* entry, and the three `*Assistant` entries.
NOT cleared (the bridge stack is deferred and decoupled from the NAV):
  BridgeEscrowImplementation, BridgeEscrowProxy, every bridgeAdapters.* entry.

The pre-clear record is archived to `script/deploy/preflight/archive/<tag>/<chainId>.json` first —
that copy is the "old addresses" input for the before/after bytecode and NAV audits, so clearing is
never destructive.

usage:
  python3 reset_deployment_records.py --dry-run              # show what would change (default)
  python3 reset_deployment_records.py --apply                # archive + clear all 24 deployed chains
  python3 reset_deployment_records.py --apply --tag pre-wave 1 42161
  python3 reset_deployment_records.py --restore <tag>        # put an archived record back
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

import chainlib as c

ARCHIVE_DIR = c.PREFLIGHT_DIR / "archive"

# Top-level keys the redeploy replaces. Bridge keys are deliberately absent.
CLEAR_TOP = [
    "PriceFeedLib",
    "NavRegistryLib",
    "NAVCalculatorImplementation",
    "NAVCalculatorProxy",
    "NexusMutualStakingPoolsAssistant",
    "EtherFiWithdrawalQueueAssistant",
    "StakeWiseV3ExitQueueAssistant",
]
CLEAR_SECTIONS = ["balanceAdapters", "customPriceFeeds"]
KEEP = {"BridgeEscrowImplementation", "BridgeEscrowProxy", "bridgeAdapters"}


def plan_for(chain_id: int) -> tuple[dict, list[str]]:
    rec = c.deployment(chain_id)
    out = json.loads(json.dumps(rec))  # deep copy, preserves key order
    changes: list[str] = []
    for k in CLEAR_TOP:
        if k in out and out[k] not in ("", None):
            changes.append(f"{k}: {out[k]} -> \"\"")
            out[k] = ""
    for sec in CLEAR_SECTIONS:
        block = out.get(sec)
        if not isinstance(block, dict):
            continue
        for name, addr in block.items():
            if addr not in ("", None):
                changes.append(f"{sec}.{name}: {addr} -> \"\"")
                block[name] = ""
    return out, changes


def do_clear(chains: list[int], tag: str, apply: bool) -> int:
    archive = ARCHIVE_DIR / tag
    if apply:
        if archive.exists() and any(archive.iterdir()):
            print(f"ERROR: archive {archive} already exists and is non-empty — pick another --tag "
                  f"rather than overwriting a record you may still need.")
            return 2
        archive.mkdir(parents=True, exist_ok=True)

    total = 0
    for cid in chains:
        src = c.DEPLOY_DIR / f"{cid}.json"
        if not src.exists():
            print(f"  {cid:8} SKIP — no deployment record")
            continue
        new, changes = plan_for(cid)
        total += len(changes)
        name = c.chain_config(cid).get("name", "?")
        print(f"  {cid:8} {name:16} {len(changes):3} address(es) to clear"
              + ("" if changes else "  (already clear)"))
        for ch in changes:
            print(f"           {ch}")
        if apply:
            shutil.copy2(src, archive / f"{cid}.json")
            src.write_text(json.dumps(new, indent=2) + "\n")

    if apply:
        print(f"\nArchived pre-clear records to {archive}")
        print(f"Cleared {total} address(es) across {len(chains)} chain(s).")
        print("REMINDER: 01/01_2/02_2 only persist addresses when PERSIST_DEPLOYMENTS=1 "
              "(BaseDeployScript.sol:33). Without it the records stay empty and 03/04/06 "
              "will read address(0) and fail.")
    else:
        print(f"\nDRY RUN — {total} address(es) would be cleared across {len(chains)} chain(s). "
              f"Re-run with --apply to write.")
    return 0


def do_restore(tag: str, chains: list[int]) -> int:
    archive = ARCHIVE_DIR / tag
    if not archive.is_dir():
        print(f"ERROR: no archive at {archive}")
        return 2
    n = 0
    for cid in chains:
        src = archive / f"{cid}.json"
        if not src.exists():
            continue
        shutil.copy2(src, c.DEPLOY_DIR / f"{cid}.json")
        print(f"  restored {cid}")
        n += 1
    print(f"restored {n} record(s) from {archive}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("chains", nargs="*", type=int)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--tag", default="pre-redeploy",
                    help="archive subdirectory name (default: pre-redeploy)")
    ap.add_argument("--restore", metavar="TAG",
                    help="restore records from archive/<TAG> instead of clearing")
    args = ap.parse_args()

    chains = args.chains or c.deployed_chain_ids()
    if args.restore:
        return do_restore(args.restore, chains)
    return do_clear(chains, args.tag, apply=args.apply and not args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
