#!/usr/bin/env python3
"""Independent READ-based verification matrix: (chain x contract) x backend.

Deliberately ignores every sweep's own result file — forge exit codes, "Response: OK" and submit
logs all lie. Ground truth is a read per backend. OKLink is the exception: an already-verified
contract mints no guid, so a 50026 from the submit route IS its read (see the skill).
"""
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request

from _paths import SP, require_inputs

require_inputs("targets.json", "paths.json")
KEY = sys.argv[1]
UA = {"User-Agent": "Mozilla/5.0"}
OFF_V2 = {196, 16661, 43111, 57073, 534352}
BLOCKSCOUT = {1: "https://eth.blockscout.com", 100: "https://gnosis.blockscout.com",
              8453: "https://base.blockscout.com", 42161: "https://arbitrum.blockscout.com",
              137: "https://polygon.blockscout.com", 42220: "https://celo.blockscout.com",
              534352: "https://scroll.blockscout.com", 130: "https://unichain.blockscout.com",
              57073: "https://explorer.inkonchain.com"}
ROUTESCAN = {1, 43114, 5000, 9745, 80094, 43111}

targets = json.load(open(f"{SP}/targets.json"))
matrix = {}


def j(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=40) as r:
        return json.load(r)


for i, t in enumerate(targets):
    cid, addr, name = t["chain"], t["addr"], t["name"]
    key = f"{cid}:{addr}"
    row = {"name": name}

    # Sourcify v2
    try:
        row["sourcify"] = bool(j(f"https://sourcify.dev/server/v2/contract/{cid}/{addr}").get("match"))
    except Exception:
        row["sourcify"] = False

    # Etherscan V2
    if cid in OFF_V2:
        row["etherscan"] = "n/a"
    else:
        try:
            q = urllib.parse.urlencode({"chainid": cid, "module": "contract", "action": "getsourcecode",
                                        "address": addr, "apikey": KEY})
            r = j(f"https://api.etherscan.io/v2/api?{q}")
            row["etherscan"] = bool(isinstance(r.get("result"), list) and r["result"][0].get("SourceCode"))
        except Exception:
            row["etherscan"] = False

    # Blockscout
    if cid in BLOCKSCOUT:
        try:
            row["blockscout"] = bool(j(f"{BLOCKSCOUT[cid]}/api/v2/smart-contracts/{addr}", UA).get("is_verified"))
        except Exception:
            row["blockscout"] = False
    else:
        row["blockscout"] = "n/a"

    # Routescan
    if cid in ROUTESCAN:
        try:
            q = urllib.parse.urlencode({"module": "contract", "action": "getsourcecode", "address": addr})
            r = j(f"https://api.routescan.io/v2/network/mainnet/evm/{cid}/etherscan/api?{q}")
            row["routescan"] = bool(isinstance(r.get("result"), list) and r["result"][0].get("SourceCode"))
        except Exception:
            row["routescan"] = False
    else:
        row["routescan"] = "n/a"

    matrix[key] = row
    print(f"[{i+1}/{len(targets)}] {key} {name}: " +
          " ".join(f"{k}={v}" for k, v in row.items() if k != "name"), flush=True)
    json.dump(matrix, open(f"{SP}/matrix.json", "w"), indent=1)

# summary
from collections import Counter  # noqa: E402
for backend in ("sourcify", "etherscan", "blockscout", "routescan"):
    c = Counter(str(r[backend]) for r in matrix.values())
    print(f"{backend:12s} {dict(c)}")
