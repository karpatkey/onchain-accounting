#!/usr/bin/env python3
"""Tenderly public verification (settled policy: ALWAYS /public).

forge cannot drive this — it silently reroutes to Etherscan — so POST the Etherscan-compat API.
Unsupported chains and trivial/exact-match-hostile contracts answer NOTOK; that is structural,
not a gap. HyperEVM (999) is known-unsupported.
"""
import json
import os
import subprocess
import time
import urllib.parse

SP = os.path.dirname(os.path.abspath(__file__))
ENV = "/home/sgzerbo/github-projects/kpk-agents/.env"


def env(k):
    for line in open(ENV):
        if line.startswith(k + "="):
            return line.split("=", 1)[1].strip()
    return ""


ACC, PROJ, TOK = env("TENDERLY_ACCOUNT_ID"), env("TENDERLY_PROJECT"), env("TENDERLY_API_TOKEN")
COMPILER = "v0.8.34+commit.80d5c536"

targets = json.load(open(f"{SP}/targets.json"))
paths = json.load(open(f"{SP}/paths.json"))
ctor = json.load(open(f"{SP}/ctorargs.json"))
out_path = f"{SP}/tenderly_results.json"
results = json.load(open(out_path)) if os.path.exists(out_path) else {}

for i, t in enumerate(targets):
    key = f"{t['chain']}:{t['addr']}"
    if results.get(key, {}).get("status") == "verified":
        continue
    name = t["name"]
    if name == "PriceFeedLib":
        # The 2.6 MB full-scope payload consistently exceeds Tenderly's upstream timeout; record it
        # rather than burn 180s per chain re-proving the same failure.
        results[key] = dict(name=name, status="skipped_upstream_timeout")
        json.dump(results, open(out_path, "w"), indent=1)
        continue
    std_file = f"{SP}/std/{name}.json"
    form = {"apikey": TOK, "module": "contract", "action": "verifysourcecode",
            "codeformat": "solidity-standard-json-input", "sourceCode": open(std_file).read(),
            "contractaddress": t["addr"], "contractname": f"{paths[name]}:{name}",
            "compilerversion": COMPILER, "optimizationUsed": "1", "runs": "200"}
    if ctor.get(key):
        form["constructorArguements"] = ctor[key]
    with open(f"{SP}/_tform.txt", "w") as f:
        f.write(urllib.parse.urlencode(form))
    url = (f"https://api.tenderly.co/api/v1/account/{ACC}/project/{PROJ}"
           f"/etherscan/verify/network/{t['chain']}/public")
    p = subprocess.run(["curl", "-s", "-m", "180", "-X", "POST", url,
                        "-H", "Content-Type: application/x-www-form-urlencoded",
                        "-H", f"X-Access-Key: {TOK}", "--data-binary", f"@{SP}/_tform.txt"],
                       capture_output=True, text=True)
    try:
        r = json.loads(p.stdout)
        status = "verified" if str(r.get("status")) == "1" else str(r.get("result") or r.get("message"))[:110]
    except Exception:
        status = f"parse_err:{p.stdout[:90]}"
    results[key] = dict(name=name, status=status)
    print(f"[{i+1}/{len(targets)}] {key} {name} -> {status[:80]}", flush=True)
    json.dump(results, open(out_path, "w"), indent=1)
    time.sleep(1.5)

from collections import Counter  # noqa: E402
print("\nSUMMARY:", Counter(v["status"][:40] for v in results.values()))
