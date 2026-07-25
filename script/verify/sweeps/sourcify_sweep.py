#!/usr/bin/env python3
"""Sourcify v2 sweep — keyless exact-match verification that also propagates to Etherscan + Routescan.

Skips PriceFeedLib: its trimmed import closure does not reproduce the deployed bytecode (via_ir
whole-scope optimization), so it needs the full-scope recipe instead.
"""
import json
import os
import time
import urllib.error
import urllib.request

SP = os.path.dirname(os.path.abspath(__file__))
BASE = "https://sourcify.dev/server"
SOLC = "0.8.34+commit.80d5c536"   # bare, no 'v' prefix for Sourcify

targets = [t for t in json.load(open(f"{SP}/targets.json")) if t["name"] != "PriceFeedLib"]
paths = json.load(open(f"{SP}/paths.json"))
out_path = f"{SP}/sourcify_results.json"
results = json.load(open(out_path)) if os.path.exists(out_path) else {}


def post(url, body):
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.status, json.load(r)


def get(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return json.load(r)


for i, t in enumerate(targets):
    key = f"{t['chain']}:{t['addr']}"
    if results.get(key, {}).get("status") in ("exact_match", "match"):
        continue
    # already verified?
    try:
        cur = get(f"{BASE}/v2/contract/{t['chain']}/{t['addr']}")
        if cur.get("match"):
            results[key] = dict(name=t["name"], status=cur["match"], note="pre-existing")
            continue
    except urllib.error.HTTPError as e:
        if e.code != 404:
            results[key] = dict(name=t["name"], status=f"lookup_http_{e.code}")
    except Exception as e:
        results[key] = dict(name=t["name"], status=f"lookup_err:{str(e)[:40]}")

    std = json.load(open(f"{SP}/std/{t['name']}.json"))
    body = {"stdJsonInput": std, "compilerVersion": SOLC,
            "contractIdentifier": f"{paths[t['name']]}:{t['name']}"}
    try:
        code, r = post(f"{BASE}/v2/verify/{t['chain']}/{t['addr']}", body)
        vid = r.get("verificationId")
        if not vid:
            results[key] = dict(name=t["name"], status="no_id", detail=str(r)[:120])
            continue
        for _ in range(40):
            time.sleep(3)
            j = get(f"{BASE}/v2/verify/{vid}")
            if j.get("isJobCompleted"):
                if j.get("contract", {}).get("match"):
                    ext = list((j.get("contract", {}).get("externalVerifications") or {}).keys())
                    results[key] = dict(name=t["name"], status=j["contract"]["match"], external=ext)
                else:
                    err = j.get("error", {})
                    results[key] = dict(name=t["name"], status="failed",
                                        detail=str(err.get("customCode") or err.get("message"))[:100])
                break
        else:
            results[key] = dict(name=t["name"], status="timeout", vid=vid)
    except urllib.error.HTTPError as e:
        results[key] = dict(name=t["name"], status=f"http_{e.code}", detail=e.read()[:150].decode("utf8", "replace"))
    except Exception as e:
        results[key] = dict(name=t["name"], status="exc", detail=str(e)[:120])

    json.dump(results, open(out_path, "w"), indent=1)
    print(f"[{i+1}/{len(targets)}] {key} {t['name']} -> {results[key]['status']}", flush=True)

from collections import Counter  # noqa: E402
print("\nSUMMARY:", Counter(v["status"] for v in results.values()))
