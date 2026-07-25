#!/usr/bin/env python3
"""Generate the sweeps' two inputs: targets.json and paths.json.

  targets.json  [{chain, addr, name, kind, args?}]  — every (chain, address) to verify
  paths.json    {ContractName: "src/…/File.sol"}    — source path per contract name

Both are derived from the repo, so they are regenerated rather than committed:
  - the canonical layer (PriceFeedLib + NAVCalculator implementation) from
    script/config/deployments/<chainId>.json
  - the custom price feeds, with their constructor arguments, from the recorded broadcasts
    broadcast/03_DeployPriceFeeds.s.sol/<chainId>/run-latest.json
  - source paths by grepping src/ for the contract/library declaration

Broadcast logs are NOT committed, so run this on the machine that performed the deploy (or after a
`--resume`-able broadcast exists). Without them the feed instances are simply omitted, and the
canonical layer is still emitted — the script says so rather than failing silently.

usage: python3 make_targets.py [chainId ...]      (default: every deployments/<id>.json)
"""
import json
import os
import re
import subprocess
import sys

from _paths import REPO, SP

os.chdir(REPO)

DEPLOY_DIR = "script/config/deployments"
FEED_BROADCAST = "broadcast/03_DeployPriceFeeds.s.sol/{chain}/run-latest.json"


def chains(argv):
    if argv:
        return [int(a) for a in argv]
    return sorted(int(f[:-5]) for f in os.listdir(DEPLOY_DIR) if f.endswith(".json"))


def main() -> int:
    targets, skipped = [], []
    for cid in chains(sys.argv[1:]):
        record = json.load(open(f"{DEPLOY_DIR}/{cid}.json"))
        lib = record.get("PriceFeedLib")
        impl = record.get("NAVCalculatorImplementation")
        if not (lib and impl):
            skipped.append(f"{cid} (no canonical layer deployed)")
            continue
        targets.append(dict(chain=cid, addr=lib, name="PriceFeedLib", kind="lib"))
        targets.append(dict(chain=cid, addr=impl, name="NAVCalculator", kind="impl"))

        bpath = FEED_BROADCAST.format(chain=cid)
        if not record.get("customPriceFeeds"):
            continue
        if not os.path.exists(bpath):
            skipped.append(f"{cid} feeds (no {bpath})")
            continue
        for tx in json.load(open(bpath))["transactions"]:
            if tx.get("transactionType") == "CREATE" and tx.get("contractName"):
                targets.append(dict(chain=cid, addr=tx["contractAddress"], name=tx["contractName"],
                                    kind="feed", args=tx.get("arguments")))

    # source path per contract name
    paths, unresolved = {}, []
    for name in sorted({t["name"] for t in targets}):
        hit = ""
        for kw in ("contract", "library"):
            out = subprocess.run(["grep", "-rln", rf"^\s*{kw} {name}\b", "src/"],
                                 capture_output=True, text=True).stdout.split()
            if out:
                hit = out[0]
                break
        if hit:
            paths[name] = hit
        else:
            unresolved.append(name)

    json.dump(targets, open(f"{SP}/targets.json", "w"), indent=1)
    json.dump(paths, open(f"{SP}/paths.json", "w"), indent=1)

    kinds = {}
    for t in targets:
        kinds[t["kind"]] = kinds.get(t["kind"], 0) + 1
    print(f"wrote targets.json: {len(targets)} instances {kinds}")
    print(f"wrote paths.json:   {len(paths)} contract types")
    for s in skipped:
        print(f"  skipped: {s}")
    if unresolved:
        print(f"  WARNING unresolved source path for: {', '.join(unresolved)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
