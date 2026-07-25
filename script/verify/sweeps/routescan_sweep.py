#!/usr/bin/env python3
"""Routescan sweep — keyless Etherscan-compatible API (placeholder key "verifyContract").

Only 6 of our chains are supported, but one of them (43111 hemi) is OFF Etherscan V2, so Routescan
is that chain's primary "…scan"-style coverage. Sourcify propagates here, hence the read-first pass.
"""
import json
import os
import time
import urllib.parse
import urllib.request

SP = os.path.dirname(os.path.abspath(__file__))
CHAINS = [1, 43114, 5000, 9745, 80094, 43111]
COMPILER = "v0.8.34+commit.80d5c536"

targets = [t for t in json.load(open(f"{SP}/targets.json")) if t["chain"] in CHAINS]
paths = json.load(open(f"{SP}/paths.json"))
ctor = json.load(open(f"{SP}/ctorargs.json"))
out_path = f"{SP}/routescan_results.json"
results = json.load(open(out_path)) if os.path.exists(out_path) else {}


def base(cid):
    return f"https://api.routescan.io/v2/network/mainnet/evm/{cid}/etherscan/api"


def get(cid, q):
    with urllib.request.urlopen(f"{base(cid)}?" + urllib.parse.urlencode(q), timeout=60) as r:
        return json.load(r)


def post(cid, data):
    req = urllib.request.Request(base(cid), data=urllib.parse.urlencode(data).encode(), method="POST")
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.load(r)


for i, t in enumerate(targets):
    key = f"{t['chain']}:{t['addr']}"
    if results.get(key, {}).get("status") == "verified":
        continue
    name = t["name"]
    try:
        chk = get(t["chain"], {"module": "contract", "action": "getsourcecode", "address": t["addr"]})
        if isinstance(chk.get("result"), list) and chk["result"][0].get("SourceCode"):
            results[key] = dict(name=name, status="verified", note="pre-existing/propagated")
            print(f"[{i+1}/{len(targets)}] {key} {name} -> already verified", flush=True)
            json.dump(results, open(out_path, "w"), indent=1)
            continue
    except Exception as e:
        results[key] = dict(name=name, status="read_err", detail=str(e)[:80])

    std_file = f"{SP}/std/PriceFeedLib_reduced.json" if name == "PriceFeedLib" else f"{SP}/std/{name}.json"
    body = {"module": "contract", "action": "verifysourcecode", "apikey": "verifyContract",
            "codeformat": "solidity-standard-json-input", "sourceCode": open(std_file).read(),
            "contractaddress": t["addr"], "contractname": f"{paths[name]}:{name}",
            "compilerversion": COMPILER}
    if ctor.get(key):
        body["constructorArguements"] = ctor[key]
    try:
        r = post(t["chain"], body)
    except Exception as e:
        results[key] = dict(name=name, status="submit_exc", detail=str(e)[:100])
        json.dump(results, open(out_path, "w"), indent=1)
        continue
    if r.get("status") != "1":
        results[key] = dict(name=name, status="submit_failed", detail=str(r.get("result"))[:120])
    else:
        guid, verdict = r["result"], "timeout"
        for _ in range(20):
            time.sleep(6)
            s = get(t["chain"], {"module": "contract", "action": "checkverifystatus", "guid": guid})
            res = str(s.get("result"))
            if "Pending" in res:
                continue
            verdict = "verified" if ("Pass" in res or "already verified" in res.lower()) else res[:120]
            break
        results[key] = dict(name=name, status=verdict, guid=guid)
    print(f"[{i+1}/{len(targets)}] {key} {name} -> {results[key]['status'][:70]}", flush=True)
    json.dump(results, open(out_path, "w"), indent=1)

from collections import Counter  # noqa: E402
print("\nSUMMARY:", Counter(v["status"][:40] for v in results.values()))
