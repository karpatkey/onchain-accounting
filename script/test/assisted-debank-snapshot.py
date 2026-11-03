#!/usr/bin/env python3
"""Snapshot DeBank's view of assisted-adapter positions for real holders, for the previewPositions-vs-DeBank fork test.

DeBank has no historical-block parameter, so the comparison is only meaningful at the block this snapshot is taken:
it records the current block, every holder's live position coordinates at that block, and DeBank's amounts, into
`test/integration/assisted-preview-debank.json`. The fork test
(`AssistedPreviewVsDebank.fork.t.sol`) rolls to that block, runs `previewPositions` on freshly deployed adapters and
asserts the token amounts match DeBank within a tolerance.

Covered: ether.fi withdrawal queue (DeBank "Locked / Withdraw Request", pool = WithdrawRequestNFT) and Nexus Mutual
staking (DeBank "Staked": stake + rewards in NXM). NOT covered: StakeWise V3 exit queue — DeBank does not report exit
positions (a holder with a live exit request shows no exit position, only its remaining vault shares), so StakeWise stays verified against the vault's
own `calculateExitedAssets` in the per-adapter fork tests.

Needs DEBANK_API_KEY, ETHERSCAN_API_KEY and ALCHEMY_API_KEY (repo .env). Read-only.
usage: script/test/assisted-debank-snapshot.py [--etherfi 0xHolder ...] [--nexus 0xHolder ...]
"""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "test/integration/assisted-preview-debank.json"
WITHDRAW_REQUEST_NFT = "0x7d5706f6ef3f89b3951e23e557cdfbc3239d4e2c"
STAKING_NFT = "0xcafea508a477d94c502c253a58239fb8f948e97f"
NXM_TOKEN = "0xd7c49cee7e9188cca6ad8ff264c1da2e69d4cf3b"
TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
# Holders with pending ether.fi withdrawal requests (recent WithdrawRequestNFT mints); holders with nothing pending at
# snapshot time are skipped automatically.
DEFAULT_ETHERFI = ["0x27fae9d8f186651a0e6fe084cd4feaaf2533d9f1", "0xfa205c9a110a3e82bd8d223ccccb15c5b9e6434e",
                   "0x924cafec4f967be5df085ad94d8d50574f9a2bb0", "0x59abc0e437971d585c2bc4d69dc8b31f2f23e855"]
DEFAULT_NEXUS = ["0x8e53D04644E9ab0412a8c6bd228C84da7664cFE3"]  # Nexus Mutual Safe


def env(k):
    if os.environ.get(k):
        return os.environ[k].strip()
    for line in (ROOT / ".env").read_text().splitlines():
        if line.startswith(k + "="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    sys.exit(f"{k} not set")


def rpc_url():
    return f"https://eth-mainnet.g.alchemy.com/v2/{env('ALCHEMY_API_KEY')}"


def cast(*a):
    r = subprocess.run(["cast", *a, "--rpc-url", rpc_url()], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr.strip())  # full text: callers classify reverts by its content
    return r.stdout.strip()


def received_by(nft, holder, block):
    """Token ids ever transferred TO `holder` (mints and transfers in) up to `block`; `owned_now` keeps the held ones."""
    params = {"chainid": 1, "module": "logs", "action": "getLogs", "address": nft, "topic0": TRANSFER,
              "topic2": "0x" + "0" * 24 + holder[2:].lower(), "topic0_2_opr": "and", "fromBlock": 0, "toBlock": block,
              "page": 1, "offset": 1000, "apikey": env("ETHERSCAN_API_KEY")}
    r = requests.get("https://api.etherscan.io/v2/api", params=params, timeout=60).json()
    res = r.get("result")
    if not isinstance(res, list):
        raise RuntimeError(f"getLogs: {r.get('message')} {str(res)[:120]}")
    if len(res) >= 1000:
        raise RuntimeError("more than 1000 transfers — paginate")
    return sorted({int(lg["topics"][3], 16) for lg in res})


def owned_now(nft, ids, holder, block, owner_sig):
    out = []
    for i in ids:
        try:
            o = cast("call", nft, owner_sig, str(i), "--block", str(block))
        except RuntimeError as e:
            # Only an execution REVERT means the token is gone (ether.fi burns a claimed request). A timeout, rate
            # limit or any other RPC failure must stop the snapshot: skipping it would drop a live NFT while keeping
            # DeBank's full amount.
            if "execution reverted" in str(e).lower():
                continue
            raise RuntimeError(f"ownership read for token {i} failed (not a revert): {e}") from e
        if holder.lower() in o.lower():
            out.append(i)
    return out


def debank(holder):
    r = requests.get("https://pro-openapi.debank.com/v1/user/all_complex_protocol_list",
                     params={"id": holder, "chain_ids": "eth"}, headers={"AccessKey": env("DEBANK_API_KEY")},
                     timeout=60).json()
    if not isinstance(r, list):
        raise RuntimeError(f"DeBank: {str(r)[:150]}")
    return r


def debank_amount(protos, proto_id, pool_id, names, token_id):
    """Sum of `token_id` amounts in `proto_id` items named in `names` on pool `pool_id` (supply + rewards)."""
    total = 0.0
    for p in protos:
        if p["id"] != proto_id:
            continue
        for it in p.get("portfolio_item_list", []):
            if it.get("name") not in names or it.get("pool", {}).get("id", "").lower() != pool_id:
                continue
            det = it.get("detail", {})
            for tok in det.get("supply_token_list", []) + det.get("reward_token_list", []):
                if tok.get("id", "").lower() != token_id:
                    raise RuntimeError(f"{proto_id}: unexpected token {tok.get('id')} in a {it.get('name')} item")
                total += tok.get("amount", 0)
    return total


def add_case(cases, member, holder, ids, amt):
    """Both sides must agree a position exists: one-sided cases mean our discovery or DeBank missed something."""
    if ids and amt > 0:
        cases.append({"member": member, "holder": holder, "ids": ids, "debankWei": str(round(amt * 1e18))})
    elif ids or amt > 0:
        sys.exit(f"asymmetric {member} case for {holder}: ids={ids} DeBank={amt} — investigate before snapshotting")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--etherfi", nargs="*", default=DEFAULT_ETHERFI)
    ap.add_argument("--nexus", nargs="*", default=DEFAULT_NEXUS)
    a = ap.parse_args()

    # DeBank first, block right after: both describe (almost) the same moment.
    snap_debank = {h: debank(h) for h in a.etherfi + a.nexus}
    debank_read_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    block = int(cast("block-number"))
    cases = []
    for h in a.etherfi:
        ids = owned_now(WITHDRAW_REQUEST_NFT, received_by(WITHDRAW_REQUEST_NFT, h, block), h, block,
                        "ownerOf(uint256)(address)")
        amt = debank_amount(snap_debank[h], "etherfi", WITHDRAW_REQUEST_NFT, {"Locked"}, "eth")
        add_case(cases, "etherfi", h, ids, amt)
    for h in a.nexus:
        ids = owned_now(STAKING_NFT, received_by(STAKING_NFT, h, block), h, block, "tokenInfo(uint256)(uint256,address)")
        amt = debank_amount(snap_debank[h], "nexus", STAKING_NFT, {"Staked"}, NXM_TOKEN)
        add_case(cases, "nexus", h, ids, amt)
    for m in ("etherfi", "nexus"):
        if not any(c["member"] == m for c in cases):
            sys.exit(f"no {m} case — pass holders with live positions")
    doc = {"$comment": "Generated by script/test/assisted-debank-snapshot.py — DeBank live amounts (wei) and the "
                       "holders' live coordinates at `block`. Regenerate; do not hand-edit.",
           "debankReadAt": debank_read_at, "block": block, "cases": cases}
    OUT.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
    for c in cases:
        print(c["member"], c["holder"], "ids", len(c["ids"]), "debank", int(c["debankWei"]) / 1e18)
    print("block", block, "→", OUT.relative_to(ROOT))


if __name__ == "__main__":
    main()
