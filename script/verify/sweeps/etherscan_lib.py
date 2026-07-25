#!/usr/bin/env python3
"""Verify PriceFeedLib on Etherscan V2 across every on-V2 chain (gotcha 9 + gotcha 10).

Uses the full-deploy-scope, whitespace-reduced standard-JSON (forge cannot submit a hand-built
one). chainid goes in the URL QUERY — in the body alone it silently defaults to chain 1.
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

SP = os.path.dirname(os.path.abspath(__file__))
KEY = sys.argv[1]
ADDR = "0x450421a334DE63F75e1d47399d9713f755aaEfF2"
NAME = "src/prices/PriceFeedLib.sol:PriceFeedLib"
COMPILER = "v0.8.34+commit.80d5c536"
ON_V2 = [1, 10, 56, 100, 130, 137, 143, 146, 204, 480, 999, 5000, 8453, 9745, 42161, 42220, 43114, 59144, 80094]

src = open(f"{SP}/std/PriceFeedLib_reduced.json").read()
out_path = f"{SP}/etherscan_lib_results.json"
results = json.load(open(out_path)) if os.path.exists(out_path) else {}


def api(chainid, data=None, query=None):
    url = f"https://api.etherscan.io/v2/api?chainid={chainid}"
    if query:
        url += "&" + urllib.parse.urlencode(query)
    if data is None:
        with urllib.request.urlopen(url, timeout=60) as r:
            return json.load(r)
    req = urllib.request.Request(url, data=urllib.parse.urlencode(data).encode(), method="POST")
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)


for cid in ON_V2:
    if results.get(str(cid), {}).get("status") == "verified":
        continue
    chk = api(cid, query={"module": "contract", "action": "getsourcecode", "address": ADDR, "apikey": KEY})
    if isinstance(chk.get("result"), list) and chk["result"][0].get("SourceCode"):
        results[str(cid)] = dict(status="verified", note="pre-existing")
        print(f"{cid}: already verified", flush=True)
        json.dump(results, open(out_path, "w"), indent=1)
        continue

    r = api(cid, data={"module": "contract", "action": "verifysourcecode",
                       "codeformat": "solidity-standard-json-input", "sourceCode": src,
                       "contractaddress": ADDR, "contractname": NAME,
                       "compilerversion": COMPILER, "apikey": KEY})
    if r.get("status") != "1":
        results[str(cid)] = dict(status="submit_failed", detail=str(r.get("result"))[:160])
        print(f"{cid}: SUBMIT FAILED {str(r.get('result'))[:120]}", flush=True)
        json.dump(results, open(out_path, "w"), indent=1)
        continue

    guid = r["result"]
    verdict = "timeout"
    for _ in range(30):
        time.sleep(6)
        s = api(cid, query={"module": "contract", "action": "checkverifystatus",
                            "guid": guid, "apikey": KEY})
        res = str(s.get("result"))
        if "Pending" in res:
            continue
        verdict = "verified" if ("Pass" in res or "already verified" in res.lower()) else res[:140]
        break
    results[str(cid)] = dict(status=verdict, guid=guid)
    print(f"{cid}: {verdict}", flush=True)
    json.dump(results, open(out_path, "w"), indent=1)

from collections import Counter  # noqa: E402
print("\nSUMMARY:", Counter(v["status"] for v in results.values()))
