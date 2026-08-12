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

CLEARING THE KEYS
-----------------
Clear the values to `""`. Do not delete the keys.

`vm.writeJson` creates a missing key unaided, so a brand-new adapter needs no seeded key — pinned by
`script/test/WriteJsonCreatesMissingKeys.t.sol`.

Gate 1.1's absence check does not cover every key it iterates — tracked in #299.

WHAT IS CLEARED, AND WHAT IS NOT
--------------------------------
Cleared (the NAV stack — everything the redeploy replaces):
  PriceFeedLib, NavRegistryLib, NAVCalculatorImplementation, NAVCalculatorProxy,
  AssetKindRegistry (see the note on CLEAR_TOP — `08` REUSES a recorded registry, and a reused one
  stays bound to the old NAV), every balanceAdapters.* entry (ERC20Default included — `02_2`
  rewrites it from the new `initialize()`), every customPriceFeeds.* entry, and the three
  `*Assistant` entries.
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
    # Must be cleared with the NAV, and for a sharper reason than "the redeploy replaces it".
    # `08_DeployAssetKindRegistry` branches on `readDeployedAddress("AssetKindRegistry")`: a non-zero
    # value makes it REUSE the recorded registry instead of deploying one. The registry's `NAV` is
    # IMMUTABLE while `NAVCalculatorProxy` is not, so reusing it after a NAV redeploy grants the NEW
    # NAV's MANAGER to a registry still bound to the OLD proxy — and the step completes GREEN, which
    # `08`'s own header calls out as the failure this guard causes. In a rehearsal, where a fresh
    # proxy is the entire point, that also means step `08` deploys nothing and the run reports
    # success for a step it never exercised. Omitting this key was harmless only while it was absent
    # from every deployment record; it stops being harmless the moment the redeploy writes one.
    "AssetKindRegistry",
    "NexusMutualStakingPoolsAssistant",
    "EtherFiWithdrawalQueueAssistant",
    "StakeWiseV3ExitQueueAssistant",
]
# Keys to CREATE (blank) when the record lacks them. Deliberately NOT all of CLEAR_TOP: for the
# three `*Assistant` keys, ABSENCE IS A SIGNAL that another tool reads. `deployer_balances.scope()`
# counts assistant keys by PRESENCE, not value, to decide whether a chain deploys assistants —
# 23 of 25 records have no assistant keys at all — so creating them would make every chain report
# three, inflating its gas estimate by 10.5M units and producing a false "TOP UP" on chains that
# deploy none. That module's own header calls a false alarm a failure mode in its own right.
#
# `AssetKindRegistry` carries no such signal: it is absent from ALL 25 records, so creating it
# removes no information, and it is the key this tool newly clears — without creating it, adding it
# to CLEAR_TOP breaks gate 1.1 everywhere.
CREATE_IF_ABSENT = {"AssetKindRegistry"}
CLEAR_SECTIONS = ["balanceAdapters", "customPriceFeeds"]
KEEP = {"BridgeEscrowImplementation", "BridgeEscrowProxy", "bridgeAdapters"}


def plan_for(chain_id: int) -> tuple[dict, list[str]]:
    rec = c.deployment(chain_id)
    out = json.loads(json.dumps(rec))  # deep copy, preserves key order
    changes: list[str] = []
    for k in CLEAR_TOP:
        if k not in out and k in CREATE_IF_ABSENT:
            # Created blank rather than left absent.
            changes.append(f"{k}: <absent> -> \"\" (created; verify_step fails on an absent key)")
            out[k] = ""
        elif k in out and out[k] not in ("", None):
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
    """Put archived records back. A PARTIAL restore is a failure, not a success.

    `deployments/<id>.json` is the only place deployed addresses live, so a chain that is asked for
    and not restored has lost its addresses — and silently skipping it (the previous behaviour: a
    bare `continue` and `return 0`) reports that loss as a clean rollback. Anything in the archive
    but outside the requested scope is also surfaced, since it is usually a scope mistake rather
    than an intentional omission.
    """
    archive = ARCHIVE_DIR / tag
    if not archive.is_dir():
        print(f"ERROR: no archive at {archive}")
        return 2
    restored, missing = [], []
    for cid in chains:
        src = archive / f"{cid}.json"
        if not src.exists():
            missing.append(cid)
            print(f"  {cid:8} MISSING — no {src.name} in this archive")
            continue
        shutil.copy2(src, c.DEPLOY_DIR / f"{cid}.json")
        print(f"  restored {cid}")
        restored.append(cid)

    held = sorted(int(p.stem) for p in archive.glob("*.json") if p.stem.isdigit())
    unrequested = [cid for cid in held if cid not in set(chains)]
    if unrequested:
        print(f"\nNOTE: {archive} also holds records for {unrequested}, which were not in scope. "
              f"Pass them explicitly if they should be restored too.")

    print(f"\nrestored {len(restored)} record(s) from {archive}")
    if missing:
        print(f"FAILED to restore {len(missing)} requested chain(s): {missing}. "
              f"Their deployments/<id>.json still holds whatever the deploy left there, and this "
              f"archive cannot recover it.")
        return 1
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

    # NOT `deployed_chain_ids()`: --apply blanks NAVCalculatorProxy, so a later `--restore` with no
    # explicit chains would resolve to zero chains and report success having restored nothing.
    chains, src = c.resolve_chains(args.chains)
    print(f"scope: {len(chains)} chain(s) from {src}")
    if args.restore:
        return do_restore(args.restore, chains)
    return do_clear(chains, args.tag, apply=args.apply and not args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
