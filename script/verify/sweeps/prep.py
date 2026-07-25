#!/usr/bin/env python3
"""Prepare verification payloads: std-JSON per contract type + ABI-encoded ctor args per instance.

Validates every std-JSON by recompiling locally and comparing to the forge artifact bytecode —
a mismatch here means the submission would fail "does NOT match" on every backend.
"""
import json
import os
import subprocess
import sys

SP = os.path.dirname(os.path.abspath(__file__))
REPO = "/home/sgzerbo/github-projects/onchain-accounting-pr-151"
SOLC = os.path.expanduser("~/.svm/0.8.34/solc-0.8.34")
os.chdir(REPO)

targets = json.load(open(f"{SP}/targets.json"))
paths = json.load(open(f"{SP}/paths.json"))
os.makedirs(f"{SP}/std", exist_ok=True)

env = dict(os.environ, ETHERSCAN_API_KEY="dummy", PATH=os.path.expanduser("~/.foundry/bin") + ":" + os.environ["PATH"])
names = sorted({t["name"] for t in targets})
report = {}

for n in names:
    p = paths[n]
    out = f"{SP}/std/{n}.json"
    if not os.path.exists(out) or os.path.getsize(out) == 0:
        with open(out, "w") as f:
            subprocess.run(["forge", "verify-contract", "0x" + "0" * 40, f"{p}:{n}",
                            "--show-standard-json-input"], stdout=f, stderr=subprocess.DEVNULL, env=env)
    size = os.path.getsize(out)
    # local recompile check
    with open(out) as f:
        res = subprocess.run([SOLC, "--standard-json"], stdin=f, capture_output=True, text=True)
    o = json.loads(res.stdout)
    errs = [e for e in o.get("errors", []) if e.get("severity") == "error"]
    art = json.load(open(f"out/{os.path.basename(p)}/{n}.json"))["bytecode"]["object"].removeprefix("0x")
    try:
        rc = o["contracts"][p][n]["evm"]["bytecode"]["object"]
        match = rc == art
    except Exception:
        match = False
    report[n] = dict(path=p, std_bytes=size, sources=len(json.load(open(out))["sources"]),
                     solc_errors=len(errs), bytecode_match=match)
    print(f"{n:40s} {size//1024:5d}KB  srcs={report[n]['sources']:3d}  errs={len(errs)}  match={match}")

json.dump(report, open(f"{SP}/prep_report.json", "w"), indent=1)

# ---- constructor args ----
enc = {}
for t in targets:
    if t["kind"] != "feed":
        enc[f"{t['chain']}:{t['addr']}"] = ""   # lib + impl take no ctor args
        continue
    n = t["name"]
    abi = json.load(open(f"out/{os.path.basename(paths[n])}/{n}.json"))["abi"]
    ctor = next((x for x in abi if x.get("type") == "constructor"), None)
    types = [i["type"] for i in ctor["inputs"]] if ctor else []
    args = t.get("args") or []
    if not types:
        enc[f"{t['chain']}:{t['addr']}"] = ""
        continue
    sig = f"constructor({','.join(types)})"
    r = subprocess.run(["cast", "abi-encode", sig] + [str(a) for a in args],
                       capture_output=True, text=True, env=env)
    enc[f"{t['chain']}:{t['addr']}"] = r.stdout.strip().removeprefix("0x")
    if r.returncode != 0:
        print("ENCODE FAIL", t["chain"], n, t["addr"], r.stderr[:100])

json.dump(enc, open(f"{SP}/ctorargs.json", "w"), indent=1)
bad = [k for k, v in enc.items() if v == "" and not any(
    t["kind"] != "feed" for t in targets if f"{t['chain']}:{t['addr']}" == k)]
print(f"\nencoded ctor args: {sum(1 for v in enc.values() if v)} non-empty / {len(enc)} targets; suspicious: {bad}")
