#!/usr/bin/env python3
"""Deployer-EOA balance and gas-price check across every chain in the redeploy scope.

Produces a top-up list. It does NOT move funds and has no key material.

Per-chain cost is estimated as (gas units for that chain's script set) x (current baseFee + tip
headroom). Gas units come from `--gas-units` (the rehearsal's measured numbers) or, absent that, from
the built-in per-step estimates below, which are deliberately generous — running out of gas midway
through a 24-chain deploy is far more expensive than over-funding.

Two chain-specific workarounds are recorded here because they are easy to forget and both have
already cost a deploy:
  * hyperevm (999): the NAV impl deploy is ~12.5M gas but HyperEVM's small blocks cap at ~3M. The
    deployer must switch the account to "big blocks" (~30M) via the Hyperliquid `evmUserModify` L1
    action before deploying, and switch back after.
  * hemi (43111): the chain enforces a fee floor; a tx priced off a naive `eth_gasPrice` is rejected,
    so `--with-gas-price` must be raised.

usage:
  python3 deployer_balances.py
  python3 deployer_balances.py --gas-units rehearsal-gas.json --json topup.json
"""
from __future__ import annotations

import argparse
import json
import sys
from concurrent.futures import ThreadPoolExecutor

import chainlib as c

# Gas units per chain role, from the deploy scripts' work. Refine with --gas-units once the fork
# rehearsal has measured the real numbers.
GAS_SHELL = 14_000_000        # 01 + 01_2 (2 libs + impl) + 02_2 (proxy + initialize + ERC20Default)
GAS_PER_FEED = 1_200_000      # one custom price feed deploy
GAS_PER_ADAPTER = 3_500_000   # one balance/meta adapter deploy (meta adapters are large)
GAS_PER_ASSET = 350_000       # registerAsset / addPriceFeed
GAS_PER_META_INSTANCE = 120_000
GAS_CONFIG_BASE = 800_000

WORKAROUNDS = {
    999: "big blocks: enable via Hyperliquid evmUserModify (usingBigBlocks=true) before 01_2/02_2, "
         "disable after — the ~12.5M-gas impl deploy does not fit HyperEVM's ~3M small blocks",
    43111: "fee floor: raise --with-gas-price; a naive eth_gasPrice quote is rejected",
}


def scope(chain_id: int) -> dict:
    """What actually gets deployed on this chain."""
    nav_meta = json.loads((c.NAV_CONFIG_DIR / "meta-balance-adapters" / f"{chain_id}.json").read_text()) \
        if (c.NAV_CONFIG_DIR / "meta-balance-adapters" / f"{chain_id}.json").exists() else {}
    nav_plain = json.loads((c.NAV_CONFIG_DIR / "balance-adapters" / f"{chain_id}.json").read_text()) \
        if (c.NAV_CONFIG_DIR / "balance-adapters" / f"{chain_id}.json").exists() else {}
    feeds = json.loads((c.CONTRACTS_CONFIG_DIR / "custom-price-feeds" / f"{chain_id}.json").read_text()) \
        if (c.CONTRACTS_CONFIG_DIR / "custom-price-feeds" / f"{chain_id}.json").exists() else {}
    assets = json.loads((c.NAV_CONFIG_DIR / "assets-and-price-feeds" / f"{chain_id}.json").read_text()) \
        if (c.NAV_CONFIG_DIR / "assets-and-price-feeds" / f"{chain_id}.json").exists() else {}

    def on(d):
        return [k for k, v in d.items() if isinstance(v, dict) and v.get("enabled") is True]

    metas = on(nav_meta)
    assistants = len([k for k in c.deployment(chain_id) if k.endswith("Assistant")])
    return {
        "metaAdapters": len(metas),
        "plainAdapters": len(on(nav_plain)),
        "assistants": assistants,
        "feeds": len(on(feeds)),
        "assets": len([k for k in assets if not k.startswith("$")]),
        "metaInstances": sum(len(nav_meta[m].get("instances", []) or [])
                             + len(nav_meta[m].get("instancesRaw", []) or []) for m in metas),
    }


def gas_estimate(s: dict, override: dict | None) -> int:
    if override:
        return int(override.get("total", 0))
    return (GAS_SHELL
            + s["feeds"] * GAS_PER_FEED
            + (s["metaAdapters"] + s["plainAdapters"] + s["assistants"]) * GAS_PER_ADAPTER
            + s["assets"] * GAS_PER_ASSET
            + s["metaInstances"] * GAS_PER_META_INSTANCE
            + (GAS_CONFIG_BASE if (s["metaAdapters"] or s["plainAdapters"]) else 0))


def one(chain_id: int, gas_units: dict) -> dict:
    name = c.chain_config(chain_id).get("name", "?")
    deployer = (c.chain_config(chain_id).get("addresses") or {}).get("admin")
    s = scope(chain_id)
    gas = gas_estimate(s, gas_units.get(str(chain_id)))
    row = {"chainId": chain_id, "name": name, "deployer": deployer, "scope": s,
           "gasUnits": gas, "workaround": WORKAROUNDS.get(chain_id)}
    url, note, rejected = c.probe_rpc(chain_id)
    row["rpc"] = note
    if not url:
        row["error"] = "; ".join(rejected) or note
        return row
    try:
        bal = int(c.rpc(url, "eth_getBalance", [deployer.lower(), "latest"]), 16)
        price = int(c.rpc(url, "eth_gasPrice", []), 16)
    except Exception as e:  # noqa: BLE001
        row["error"] = str(e)
        return row
    # 2x headroom on gas price: these deploys span many blocks and base fee moves.
    need = gas * price * 2
    row.update(balanceWei=bal, gasPriceWei=price, needWei=need,
               balanceEth=bal / 1e18, needEth=need / 1e18,
               shortfallEth=max(0.0, (need - bal) / 1e18),
               sufficient=bal >= need)
    return row


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("chains", nargs="*", type=int)
    ap.add_argument("--gas-units", help="JSON {chainId: {total: <gas>}} from the fork rehearsal")
    ap.add_argument("--json", help="write the full report here")
    args = ap.parse_args()
    c.load_env()

    gas_units = json.load(open(args.gas_units)) if args.gas_units else {}
    chains = args.chains or c.deployed_chain_ids()
    with ThreadPoolExecutor(max_workers=6) as pool:
        rows = list(pool.map(lambda cid: one(cid, gas_units), chains))
    rows.sort(key=lambda r: r["chainId"])

    print(f"{'chain':>8} {'name':16} {'native':>12} {'need':>12} {'shortfall':>11}  status")
    topup = []
    for r in rows:
        if r.get("error"):
            print(f"{r['chainId']:>8} {r['name']:16} {'—':>12} {'—':>12} {'—':>11}  "
                  f"RPC ERROR: {r['error'][:70]}")
            continue
        sym = c.chain_config(r["chainId"]).get("nativeTokenSymbol", "")
        status = "OK" if r["sufficient"] else "TOP UP"
        print(f"{r['chainId']:>8} {r['name']:16} {r['balanceEth']:>12.5f} {r['needEth']:>12.5f} "
              f"{r['shortfallEth']:>11.5f}  {status} ({sym})")
        if not r["sufficient"]:
            topup.append({"chainId": r["chainId"], "name": r["name"],
                          "nativeSymbol": sym, "deployer": r["deployer"],
                          "shortfallEth": round(r["shortfallEth"], 6),
                          "haveEth": round(r["balanceEth"], 6),
                          "needEth": round(r["needEth"], 6)})

    print("\n--- top-up list (NO funds moved by this script) ---")
    if topup:
        for t in topup:
            print(f"  {t['name']:16} send >= {t['shortfallEth']:.5f} {t['nativeSymbol']} "
                  f"to {t['deployer']}")
    else:
        print("  none — every chain is funded for the estimated gas")

    print("\n--- chain-specific workarounds ---")
    for cid, note in WORKAROUNDS.items():
        print(f"  {cid} {c.chain_config(cid).get('name','?')}: {note}")

    if args.json:
        json.dump({"rows": rows, "topup": topup}, open(args.json, "w"), indent=1)
        print(f"\nwrote {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
