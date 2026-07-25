#!/usr/bin/env python3
"""Etherscan V2 sweep for the NAV implementation + custom price feeds (everything except PriceFeedLib).

Reads first (uncapped) and skips anything already verified — Sourcify propagates to Etherscan for
some targets but not reliably, so the read is what decides. Submissions are capped at 250/key/day.
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

SP = os.path.dirname(os.path.abspath(__file__))
KEY = sys.argv[1]
COMPILER = "v0.8.34+commit.80d5c536"
OFF_V2 = {196, 16661, 43111, 57073, 534352}

targets = [t for t in json.load(open(f"{SP}/targets.json"))
           if t["name"] != "PriceFeedLib" and t["chain"] not in OFF_V2]
paths = json.load(open(f"{SP}/paths.json"))
ctor = json.load(open(f"{SP}/ctorargs.json"))
out_path = f"{SP}/etherscan_results.json"
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


for i, t in enumerate(targets):
    key = f"{t['chain']}:{t['addr']}"
    if results.get(key, {}).get("status") == "verified":
        continue
    try:
        chk = api(t["chain"], query={"module": "contract", "action": "getsourcecode",
                                     "address": t["addr"], "apikey": KEY})
        if isinstance(chk.get("result"), list) and chk["result"][0].get("SourceCode"):
            results[key] = dict(name=t["name"], status="verified", note="pre-existing/propagated")
            print(f"[{i+1}/{len(targets)}] {key} {t['name']} -> already verified", flush=True)
            json.dump(results, open(out_path, "w"), indent=1)
            time.sleep(0.25)
            continue
    except Exception as e:
        results[key] = dict(name=t["name"], status="read_err", detail=str(e)[:80])

    body = {"module": "contract", "action": "verifysourcecode",
            "codeformat": "solidity-standard-json-input",
            "sourceCode": open(f"{SP}/std/{t['name']}.json").read(),
            "contractaddress": t["addr"], "contractname": f"{paths[t['name']]}:{t['name']}",
            "compilerversion": COMPILER, "apikey": KEY}
    if ctor.get(key):
        body["constructorArguements"] = ctor[key]   # Etherscan's documented misspelling
    try:
        r = api(t["chain"], data=body)
    except Exception as e:
        results[key] = dict(name=t["name"], status="submit_exc", detail=str(e)[:100])
        json.dump(results, open(out_path, "w"), indent=1)
        continue
    if r.get("status") != "1":
        detail = str(r.get("result"))[:160]
        results[key] = dict(name=t["name"], status="submit_failed", detail=detail)
        print(f"[{i+1}/{len(targets)}] {key} SUBMIT FAILED: {detail[:110]}", flush=True)
        json.dump(results, open(out_path, "w"), indent=1)
        if "Daily limit" in detail:
            print("!! DAILY CAP REACHED — stopping", flush=True)
            break
        continue

    guid, verdict = r["result"], "timeout"
    for _ in range(25):
        time.sleep(5)
        s = api(t["chain"], query={"module": "contract", "action": "checkverifystatus",
                                   "guid": guid, "apikey": KEY})
        res = str(s.get("result"))
        if "Pending" in res:
            continue
        verdict = "verified" if ("Pass" in res or "already verified" in res.lower()) else res[:140]
        break
    results[key] = dict(name=t["name"], status=verdict, guid=guid)
    print(f"[{i+1}/{len(targets)}] {key} {t['name']} -> {verdict}", flush=True)
    json.dump(results, open(out_path, "w"), indent=1)

from collections import Counter  # noqa: E402
print("\nSUMMARY:", Counter(v["status"] for v in results.values()))
