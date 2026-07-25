#!/usr/bin/env python3
"""OKLink sweep — keyless, but WAF-blocks non-browser user agents (use curl with a browser UA).

The submit route IS the status check and is safe to re-run:
  code 50026 -> ALREADY VERIFIED (not rate limiting)
  code 0     -> accepted, mints a guid to poll
check-verify-result returns `data` as a BARE LIST OF STRINGS, not dicts.
"""
import json
import os
import subprocess
import time

SP = os.path.dirname(os.path.abspath(__file__))
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36"
COMPILER = "v0.8.34+commit.80d5c536"

SHORT = {1: "ETH", 10: "OP", 42161: "ARBITRUM", 8453: "BASE", 56: "BSC", 137: "POLYGON",
         43114: "AVAXC", 59144: "LINEA", 534352: "SCROLL", 100: "GNOSIS", 196: "XLAYER",
         204: "OPBNB"}

targets = [t for t in json.load(open(f"{SP}/targets.json")) if t["chain"] in SHORT]
paths = json.load(open(f"{SP}/paths.json"))
ctor = json.load(open(f"{SP}/ctorargs.json"))
out_path = f"{SP}/oklink_results.json"
results = json.load(open(out_path)) if os.path.exists(out_path) else {}


def post(url, body):
    with open(f"{SP}/_ok_body.json", "w") as f:
        json.dump(body, f)
    p = subprocess.run(["curl", "-s", "-m", "180", "-X", "POST", url,
                        "-H", "Content-Type: application/json", "-H", f"User-Agent: {UA}",
                        "--data-binary", f"@{SP}/_ok_body.json"], capture_output=True, text=True)
    try:
        return json.loads(p.stdout)
    except Exception:
        return {"code": "parse_err", "raw": p.stdout[:120]}


for i, t in enumerate(targets):
    key = f"{t['chain']}:{t['addr']}"
    if results.get(key, {}).get("status") in ("verified", "already_verified"):
        continue
    name = t["name"]
    # PriceFeedLib needs the full-scope payload; everything else uses its own trimmed closure
    std_file = f"{SP}/std/PriceFeedLib_reduced.json" if name == "PriceFeedLib" else f"{SP}/std/{name}.json"
    body = {"chainShortName": SHORT[t["chain"]], "contractAddress": t["addr"],
            "contractName": f"{paths[name]}:{name}", "sourceCode": open(std_file).read(),
            "codeFormat": "solidity-standard-json-input", "compilerVersion": COMPILER,
            "optimization": "1", "optimizationRuns": "200"}
    if ctor.get(key):
        body["constructorArguments"] = ctor[key]

    r = post("https://www.oklink.com/api/v5/explorer/contract/verify-source-code", body)
    code = str(r.get("code"))
    if code == "50026":
        results[key] = dict(name=name, status="already_verified")
    elif code == "0":
        guid = (r.get("data") or [None])[0]
        verdict = "pending"
        for _ in range(20):
            time.sleep(6)
            s = post("https://www.oklink.com/api/v5/explorer/contract/check-verify-result",
                     {"chainShortName": SHORT[t["chain"]], "guid": guid})
            d = (s.get("data") or [None])[0]
            v = d.get("verifyResult") if isinstance(d, dict) else d   # BARE STRING, not dict
            if v and "pending" not in str(v).lower():
                verdict = str(v)
                break
        results[key] = dict(name=name, status="verified" if verdict.lower().startswith("success") else verdict,
                            guid=guid)
    else:
        results[key] = dict(name=name, status=f"code_{code}", detail=str(r.get("msg"))[:100])
    print(f"[{i+1}/{len(targets)}] {key} {name} -> {results[key]['status']}", flush=True)
    json.dump(results, open(out_path, "w"), indent=1)
    time.sleep(2)

from collections import Counter  # noqa: E402
print("\nSUMMARY:", Counter(v["status"] for v in results.values()))
