#!/usr/bin/env python3
"""Verify PriceFeedLib on Blockscout using the full-deploy-scope standard-JSON.

forge submits its own trimmed import closure, which under via_ir compiles to different bytecode —
so the library fails there just as it does on Etherscan. Post the validated full-scope payload to
Blockscout's Etherscan-compatible endpoint instead.
"""
import json
import os
import time
import urllib.parse
import urllib.request

SP = os.path.dirname(os.path.abspath(__file__))
ADDR = "0x450421a334DE63F75e1d47399d9713f755aaEfF2"
NAME = "src/prices/PriceFeedLib.sol:PriceFeedLib"
COMPILER = "v0.8.34+commit.80d5c536"
UA = {"User-Agent": "Mozilla/5.0"}

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

src = open(f"{SP}/std/PriceFeedLib_reduced.json").read()
out_path = f"{SP}/blockscout_lib_results.json"
results = json.load(open(out_path)) if os.path.exists(out_path) else {}


def is_verified(inst):
    try:
        req = urllib.request.Request(f"{inst}/api/v2/smart-contracts/{ADDR}", headers=UA)
        with urllib.request.urlopen(req, timeout=30) as r:
            return bool(json.load(r).get("is_verified"))
    except Exception:
        return False


for cid, inst in INSTANCES.items():
    if results.get(str(cid), {}).get("status") == "verified":
        continue
    if is_verified(inst):
        results[str(cid)] = dict(status="verified", note="pre-existing")
        print(f"{cid}: already verified", flush=True)
        continue
    body = urllib.parse.urlencode({
        "module": "contract", "action": "verifysourcecode",
        "codeformat": "solidity-standard-json-input", "sourceCode": src,
        "contractaddress": ADDR, "contractname": NAME, "compilerversion": COMPILER,
    }).encode()
    try:
        req = urllib.request.Request(f"{inst}/api?module=contract&action=verifysourcecode",
                                     data=body, headers=UA, method="POST")
        with urllib.request.urlopen(req, timeout=180) as r:
            resp = json.load(r)
        submitted = str(resp)[:120]
    except Exception as e:
        submitted = f"exc:{str(e)[:100]}"
    time.sleep(25)   # Blockscout recompiles the full via_ir project server-side
    ok = is_verified(inst)
    results[str(cid)] = dict(status="verified" if ok else "unconfirmed", submit=submitted)
    print(f"{cid}: {results[str(cid)]['status']} | {submitted[:90]}", flush=True)
    json.dump(results, open(out_path, "w"), indent=1)

from collections import Counter  # noqa: E402
print("\nSUMMARY:", Counter(v["status"] for v in results.values()))
