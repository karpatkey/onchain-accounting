#!/usr/bin/env python3
"""Blockscout sweep — keyless, and notably lenient about CREATE2 libraries Etherscan rejects.

Only instances confirmed to answer /api/v2/smart-contracts/<addr> are targeted; the skill records
optimism.blockscout.com and hyperevm/hyperscan as endpoints that reject forge submissions.
"""
import json
import os
import subprocess
import time
import urllib.request

SP = os.path.dirname(os.path.abspath(__file__))
REPO = "/home/sgzerbo/github-projects/onchain-accounting-pr-151"
os.chdir(REPO)
env = dict(os.environ, PATH=os.path.expanduser("~/.foundry/bin") + ":" + os.environ["PATH"],
           ETHERSCAN_API_KEY="")

INSTANCES = {
    1: "https://eth.blockscout.com",
    100: "https://gnosis.blockscout.com",
    8453: "https://base.blockscout.com",
    42161: "https://arbitrum.blockscout.com",
    137: "https://polygon.blockscout.com",
    42220: "https://celo.blockscout.com",
    534352: "https://scroll.blockscout.com",
    130: "https://unichain.blockscout.com",
    57073: "https://explorer.inkonchain.com",
}

targets = [t for t in json.load(open(f"{SP}/targets.json")) if t["chain"] in INSTANCES]
paths = json.load(open(f"{SP}/paths.json"))
ctor = json.load(open(f"{SP}/ctorargs.json"))
out_path = f"{SP}/blockscout_results.json"
results = json.load(open(out_path)) if os.path.exists(out_path) else {}
UA = {"User-Agent": "Mozilla/5.0"}


def is_verified(inst, addr):
    try:
        req = urllib.request.Request(f"{inst}/api/v2/smart-contracts/{addr}", headers=UA)
        with urllib.request.urlopen(req, timeout=30) as r:
            return bool(json.load(r).get("is_verified"))
    except Exception:
        return False


for i, t in enumerate(targets):
    key = f"{t['chain']}:{t['addr']}"
    inst = INSTANCES[t["chain"]]
    if results.get(key, {}).get("status") == "verified":
        continue
    if is_verified(inst, t["addr"]):
        results[key] = dict(name=t["name"], status="verified", note="pre-existing")
        print(f"[{i+1}/{len(targets)}] {key} {t['name']} -> already verified", flush=True)
        json.dump(results, open(out_path, "w"), indent=1)
        continue

    cmd = ["forge", "verify-contract", t["addr"], f"{paths[t['name']]}:{t['name']}",
           "--verifier", "blockscout", "--verifier-url", f"{inst}/api/",
           "--compiler-version", "0.8.34"]
    if ctor.get(key):
        cmd += ["--constructor-args", "0x" + ctor[key]]
    p = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=300)
    time.sleep(8)   # async; give it a moment before the confirming read
    ok = is_verified(inst, t["addr"])
    results[key] = dict(name=t["name"], status="verified" if ok else "submitted_unconfirmed",
                        detail=(p.stdout + p.stderr)[-160:] if not ok else "")
    print(f"[{i+1}/{len(targets)}] {key} {t['name']} -> {results[key]['status']}", flush=True)
    json.dump(results, open(out_path, "w"), indent=1)

from collections import Counter  # noqa: E402
print("\nSUMMARY:", Counter(v["status"] for v in results.values()))
