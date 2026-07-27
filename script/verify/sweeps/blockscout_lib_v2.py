#!/usr/bin/env python3
"""Verify PriceFeedLib on Blockscout via the NATIVE v2 endpoint.

Blockscout's Etherscan-compatible `verifysourcecode` route answers "Fail - Unable to verify" for
this via_ir CREATE2 library, but the native
    POST /api/v2/smart-contracts/<addr>/verification/via/standard-input
route — which takes the standard-JSON as a multipart file upload — accepts the very same payload.
Verified on eth.blockscout.com first, then rolled out here.
"""
import json
import os
import subprocess
import time
import urllib.request

SP = os.path.dirname(os.path.abspath(__file__))
ADDR = "0x450421a334DE63F75e1d47399d9713f755aaEfF2"
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36"
STD = f"{SP}/std/PriceFeedLib_full.json"

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

out_path = f"{SP}/blockscout_lib_v2_results.json"
results = json.load(open(out_path)) if os.path.exists(out_path) else {}


def is_verified(inst):
    try:
        req = urllib.request.Request(f"{inst}/api/v2/smart-contracts/{ADDR}",
                                     headers={"User-Agent": UA})
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
        json.dump(results, open(out_path, "w"), indent=1)
        continue

    p = subprocess.run([
        "curl", "-s", "-m", "300", "-X", "POST",
        f"{inst}/api/v2/smart-contracts/{ADDR}/verification/via/standard-input",
        "-H", f"User-Agent: {UA}",
        "-F", "compiler_version=v0.8.34+commit.80d5c536",
        "-F", "license_type=bsl_1_1",
        "-F", "autodetect_constructor_args=true",
        "-F", f"files[0]=@{STD};type=application/json",
    ], capture_output=True, text=True)
    submit = p.stdout[:120]

    ok = False
    for _ in range(15):          # Blockscout recompiles the full via_ir project server-side
        time.sleep(20)
        if is_verified(inst):
            ok = True
            break
    results[str(cid)] = dict(status="verified" if ok else "unconfirmed", submit=submit)
    print(f"{cid}: {results[str(cid)]['status']} | {submit[:70]}", flush=True)
    json.dump(results, open(out_path, "w"), indent=1)

from collections import Counter  # noqa: E402
print("\nSUMMARY:", Counter(v["status"] for v in results.values()))
