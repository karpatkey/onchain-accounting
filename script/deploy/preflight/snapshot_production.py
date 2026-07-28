#!/usr/bin/env python3
"""Snapshot the LIVE NAV state of every deployed chain, before the redeploy abandons it.

This is the pre-deploy half of the acceptance test: after the new proxy is configured, re-run with
`--out post` and diff, so "does the new stack reproduce the old one?" is a diff and not a judgement
call. Read-only — it only ever issues `eth_call`.

Per chain it records:
  proxy, impl (EIP-1967 slot), erc20DefaultBalanceAdapter, version, usdDecimals
  role holders (DEFAULT_ADMIN_ROLE / MANAGER) for the deployer EOA and the security council
  every registered asset (address, symbol, decimals)
  every price feed and monitor feed per asset, with PriceType and heartbeat
  per-asset divergence/peg tolerances
  every registered balance adapter, its AdapterType, and — for meta-adapters — its full instance set
  getAccountNavVerbose(account, USD) for every account in test/integration/accounts.json
    enabled on that chain

Snapshots are pinned to one block per chain (`eth_blockNumber` at start) so every call in a chain's
snapshot is internally consistent.

usage:
  python3 snapshot_production.py [--out pre|post|DIR] [--no-nav] [chainId ...]
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from eth_abi import decode as abi_decode
from eth_abi import encode as abi_encode
from eth_utils import keccak

import chainlib as c

# ---------------------------------------------------------------------------
# ABI type strings, transcribed from src/nav/INAVCalculator.sol + src/prices/IPrices.sol
# ---------------------------------------------------------------------------
ASSET = "(address,string,uint8)"
FEED_CONFIG = "(address,uint8,uint8,uint256)"  # priceFeed, decimals, PriceType, chainlinkHeartbeat
POSITION = (
    "(" + ASSET + ",address,uint256,bool," + ASSET +
    ",int256,int256,uint8,bool,bool,bytes32,bytes32,bytes32,bytes,uint8,bool,bytes32,bool,bool)"
)
VERBOSE_POSITION = "(" + POSITION + ",string,string[])"
NAV = "(int256," + ASSET + ",uint64," + ASSET + "[],bool,bool," + ASSET + "[],bool)"
VERBOSE_NAV = "(" + NAV + "," + VERBOSE_POSITION + "[])"

PRICE_TYPE = {0: "Chainlink", 1: "Redstone", 2: "API3", 3: "Custom"}
ADAPTER_TYPE = {0: "Default", 1: "Custom"}
POSITION_KIND = {
    0: "Wallet", 1: "Supplied", 2: "Borrowed", 3: "Collateral",
    4: "Staking", 5: "Rewards", 6: "Fees",
}
ZERO = "0x" + "0" * 40
# EIP-1967 implementation slot
IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
DEFAULT_ADMIN_ROLE = "0x" + "00" * 32
MANAGER_ROLE = "0x" + keccak(text="MANAGER").hex()


def selector(sig: str) -> str:
    return "0x" + keccak(text=sig)[:4].hex()


def call(url: str, to: str, sig: str, arg_types: list[str], args: list, ret_types: list[str],
         block: str):
    data = selector(sig)
    if arg_types:
        # eth_abi's AddressEncoder rejects mixed-case (EIP-55) addresses outright, and the repo's
        # JSON records are checksummed — normalise before encoding.
        args = [a.lower() if t == "address" and isinstance(a, str) else a
                for t, a in zip(arg_types, args)]
        data += abi_encode(arg_types, args).hex()
    raw = c.eth_call(url, to, data, block)
    return abi_decode(ret_types, bytes.fromhex(raw[2:]))


def hexs(b: bytes) -> str:
    return "0x" + b.hex()


def asset_obj(a) -> dict:
    return {"address": a[0], "symbol": a[1], "decimals": a[2]}


def position_obj(p) -> dict:
    return {
        "balanceAsset": asset_obj(p[0]),
        "balanceAdapter": p[1],
        "amount": str(p[2]),
        "isDebt": p[3],
        "quoteAsset": asset_obj(p[4]),
        "value": str(p[5]),
        "price": str(p[6]),
        "priceDecimals": p[7],
        "stale": p[8],
        "quoteAssetStale": p[9],
        "protocolBrand": hexs(p[10]),
        "protocolId": hexs(p[11]),
        "protocolSubId": hexs(p[12]),
        "positionId": hexs(p[13]),
        "positionKind": POSITION_KIND.get(p[14], p[14]),
        "isLocked": p[15],
        "positionInstanceId": hexs(p[16]),
        "irregular": p[17],
        "quoteAssetIrregular": p[18],
    }


def nav_obj(n) -> dict:
    return {
        "value": str(n[0]),
        "quoteAsset": asset_obj(n[1]),
        "timestamp": n[2],
        "stalePriceAssets": [asset_obj(a) for a in n[3]],
        "sequencerDown": n[4],
        "quoteAssetStale": n[5],
        "irregularPriceAssets": [asset_obj(a) for a in n[6]],
        "quoteAssetIrregular": n[7],
    }


def accounts_for_chain(chain_id: int) -> list[dict]:
    doc = json.loads((c.REPO / "test/integration/accounts.json").read_text())
    entries = doc["accounts"]
    if isinstance(entries, dict):  # tolerate either shape
        entries = [entries[k] for k in sorted(entries, key=int)]
    out = []
    for acct in entries:
        addr = acct.get("address", "")
        if not c.is_address(addr):
            continue
        if chain_id in acct.get("enabledChains", []):
            out.append({"address": addr, "label": acct.get("label", "")})
    return out


def snapshot_chain(chain_id: int, url: str, rpc_note: str, want_nav: bool) -> dict:
    rec = c.deployment(chain_id)
    proxy = rec["NAVCalculatorProxy"]
    blk = c.block_number(url)
    # Step back a few blocks: some providers serve `latest` from a node that has not yet indexed it.
    blk = max(blk - 3, 1)
    block = hex(blk)
    snap: dict = {
        "chainId": chain_id,
        "name": c.chain_config(chain_id).get("name", ""),
        "rpcSource": rpc_note,
        "block": blk,
        "capturedAtUnix": int(time.time()),
        "proxy": proxy,
        "errors": [],
    }

    def guard(label, fn, default=None):
        try:
            return fn()
        except Exception as e:  # noqa: BLE001 — a partial snapshot beats no snapshot
            snap["errors"].append(f"{label}: {e}")
            return default

    slot = guard("implSlot", lambda: c.rpc(url, "eth_getStorageAt", [proxy, IMPL_SLOT, block]))
    snap["implementation"] = ("0x" + slot[-40:]) if slot else None
    snap["implementationRecorded"] = rec.get("NAVCalculatorImplementation")

    snap["version"] = guard("version",
                            lambda: call(url, proxy, "version()", [], [], ["uint64"], block)[0])
    snap["usdDecimals"] = guard("usdDecimals",
                                lambda: call(url, proxy, "usdDecimals()", [], [], ["uint8"], block)[0])
    snap["erc20DefaultBalanceAdapter"] = guard(
        "erc20Default",
        lambda: call(url, proxy, "erc20DefaultBalanceAdapter()", [], [], ["address"], block)[0])
    snap["erc20DefaultRecorded"] = (rec.get("balanceAdapters") or {}).get("ERC20Default")

    # The ERC20Default inclusion set. `initialize()` seeds it with the native asset only; every later
    # `registerAsset` adds to it, and `excludeAssetFromDefaultAdapter` removes. That exclusion state is
    # the one piece of NAV configuration a fresh proxy does NOT reconstruct from config — RegisterAssets
    # re-includes everything — so it must be captured here and re-applied after the redeploy.
    default_adapter = snap["erc20DefaultBalanceAdapter"]
    snap["erc20DefaultSupportedAssets"] = guard(
        "underlyingAssetsSupported",
        lambda: list(call(url, default_adapter, "underlyingAssetsSupported()", [], [],
                          ["address[]"], block)[0])) if default_adapter else None

    # --- roles -------------------------------------------------------------
    addrs = c.chain_config(chain_id).get("addresses", {}) or {}
    roles = {}
    for who, addr in addrs.items():
        if not c.is_address(addr):
            continue
        entry = {"address": addr}
        for rname, rval in (("DEFAULT_ADMIN_ROLE", DEFAULT_ADMIN_ROLE), ("MANAGER", MANAGER_ROLE)):
            entry[rname] = guard(
                f"hasRole({who},{rname})",
                lambda rv=rval, a=addr: call(url, proxy, "hasRole(bytes32,address)",
                                             ["bytes32", "address"],
                                             [bytes.fromhex(rv[2:]), a], ["bool"], block)[0])
        roles[who] = entry
    snap["roles"] = roles

    # --- assets + feeds ----------------------------------------------------
    assets = guard("getRegisteredAssets",
                   lambda: call(url, proxy, "getRegisteredAssets()", [], [],
                                [f"{ASSET}[]"], block)[0], []) or []
    snap["assetCount"] = len(assets)
    default_set = {a.lower() for a in (snap.get("erc20DefaultSupportedAssets") or [])}
    # One batched round-trip for all three per-asset reads instead of 3 calls per asset.
    per_asset_sigs = [("getPriceFeeds(address)", f"{FEED_CONFIG}[]"),
                      ("getMonitorFeeds(address)", f"{FEED_CONFIG}[]"),
                      ("getAssetPricing(address)", "(uint32,uint32)")]
    targets = [(proxy, selector(sig) + abi_encode(["address"], [a[0].lower()]).hex())
               for a in assets for sig, _ in per_asset_sigs]
    raw = c.rpc_batch(url, [("eth_call", [{"to": to, "data": d}, block]) for to, d in targets]) \
        if targets else []

    def decode_at(i, ret_type, label, default):
        v = raw[i]
        if isinstance(v, Exception):
            snap["errors"].append(f"{label}: {v}")
            return default
        try:
            return abi_decode([ret_type], bytes.fromhex(v[2:]))[0]
        except Exception as e:  # noqa: BLE001
            snap["errors"].append(f"{label} decode: {e}")
            return default

    def feed_obj(f):
        return {"priceFeed": f[0], "decimals": f[1],
                "priceType": PRICE_TYPE.get(f[2], f[2]), "heartbeat": f[3]}

    asset_entries = []
    for ai, a in enumerate(assets):
        addr = a[0]
        e = asset_obj(a)
        base = ai * len(per_asset_sigs)
        feeds = decode_at(base, f"{FEED_CONFIG}[]", f"getPriceFeeds({addr})", []) or []
        mons = decode_at(base + 1, f"{FEED_CONFIG}[]", f"getMonitorFeeds({addr})", []) or []
        pricing = decode_at(base + 2, "(uint32,uint32)", f"getAssetPricing({addr})", (0, 0)) or (0, 0)
        e["priceFeeds"] = [feed_obj(f) for f in feeds]
        e["monitorFeeds"] = [feed_obj(f) for f in mons]
        e["divergenceToleranceBps"] = pricing[0]
        e["pegToleranceBps"] = pricing[1]
        e["includedInDefaultAdapter"] = (addr.lower() in default_set) if default_set else None
        asset_entries.append(e)
    snap["assets"] = asset_entries
    snap["excludedFromDefaultAdapter"] = [
        e["address"] for e in asset_entries if e["includedInDefaultAdapter"] is False
    ]

    # --- adapters ----------------------------------------------------------
    adapters = guard("getAllAdapters",
                     lambda: call(url, proxy, "getAllAdapters()", [], [], ["address[]"], block)[0],
                     []) or []
    snap["adapterCount"] = len(adapters)
    adapter_entries = []
    recorded = {v.lower(): k for k, v in (rec.get("balanceAdapters") or {}).items()}
    ad_sigs = [("getAdapterType(address)", "uint8"), ("getMetaInstances(address)", "bytes32[]")]
    ad_targets = [(proxy, selector(sig) + abi_encode(["address"], [ad.lower()]).hex())
                  for ad in adapters for sig, _ in ad_sigs]
    raw = c.rpc_batch(url, [("eth_call", [{"to": to, "data": d}, block])
                            for to, d in ad_targets]) if ad_targets else []
    for adi, ad in enumerate(adapters):
        base = adi * len(ad_sigs)
        atype = decode_at(base, "uint8", f"getAdapterType({ad})", None)
        insts = decode_at(base + 1, "bytes32[]", f"getMetaInstances({ad})", []) or []
        adapter_entries.append({
            "address": ad,
            "configKey": recorded.get(ad.lower()),
            "adapterType": ADAPTER_TYPE.get(atype, atype),
            "metaInstanceCount": len(insts),
            "metaInstances": [hexs(i) for i in insts],
        })
    snap["adapters"] = adapter_entries
    snap["metaInstanceTotal"] = sum(a["metaInstanceCount"] for a in adapter_entries)

    # --- account NAVs ------------------------------------------------------
    snap["accounts"] = []
    if want_nav:
        accts = accounts_for_chain(chain_id)
        sel = selector("getAccountNavVerbose(address,address)")
        raw = c.rpc_batch(
            url,
            [("eth_call", [{"to": proxy,
                            "data": sel + abi_encode(["address", "address"],
                                                     [a["address"].lower(), ZERO]).hex()}, block])
             for a in accts],
            chunk=4,  # these are the heaviest calls in the snapshot; keep batches small
        ) if accts else []
        for i, acct in enumerate(accts):
            res = decode_at(i, VERBOSE_NAV, f"getAccountNavVerbose({acct['label']})", None)
            entry = dict(acct)
            if res is None:
                entry["error"] = "call reverted or failed — see chain errors"
            else:
                entry["nav"] = nav_obj(res[0])
                entry["positions"] = [
                    {"position": position_obj(vp[0]), "protocolName": vp[1], "labels": list(vp[2])}
                    for vp in res[1]
                ]
                entry["positionCount"] = len(res[1])
            snap["accounts"].append(entry)
    return snap


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("chains", nargs="*", type=int)
    ap.add_argument("--out", default="pre",
                    help="'pre'/'post' (-> snapshots/<out>/) or an explicit directory")
    ap.add_argument("--jobs", type=int, default=6, help="chains snapshotted in parallel")
    ap.add_argument("--no-nav", action="store_true",
                    help="skip getAccountNavVerbose (fast structural-only snapshot)")
    args = ap.parse_args()

    c.load_env()
    out_dir = Path(args.out) if "/" in args.out else c.SNAPSHOT_DIR / args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    chains = args.chains or c.deployed_chain_ids()

    def one(cid: int):
        url, note, rejected = c.probe_rpc(cid)
        name = c.chain_config(cid).get("name", "?")
        if not url:
            return cid, name, None, note + " | " + " ; ".join(rejected)
        try:
            return cid, name, snapshot_chain(cid, url, note, not args.no_nav), None
        except Exception as e:  # noqa: BLE001
            return cid, name, None, str(e)

    index, failures = [], []
    # Chains are independent and each hits a different endpoint, so fan out — but keep the pool
    # small: mainnet/arbitrum/base issue hundreds of eth_calls and shared Alchemy quota is the limit.
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for cid, name, snap, err in pool.map(one, chains):
            if snap is None:
                print(f"  {cid:8} {name:16} SKIP/FAIL — {err}")
                failures.append({"chainId": cid, "name": name, "reason": err})
                continue
            (out_dir / f"{cid}.json").write_text(json.dumps(snap, indent=1) + "\n")
            nerr = len(snap["errors"])
            print(f"  {cid:8} {name:16} assets={snap['assetCount']:<3}"
                  f" adapters={snap['adapterCount']:<3}"
                  f" metaInstances={snap['metaInstanceTotal']:<4}"
                  f" accounts={len(snap['accounts'])}"
                  f" block={snap['block']}" + (f"  ERRORS={nerr}" if nerr else ""), flush=True)
            index.append({
                "chainId": cid, "name": snap["name"], "block": snap["block"],
                "proxy": snap["proxy"], "implementation": snap["implementation"],
                "erc20Default": snap["erc20DefaultBalanceAdapter"],
                "assetCount": snap["assetCount"], "adapterCount": snap["adapterCount"],
                "metaInstanceTotal": snap["metaInstanceTotal"],
                "excludedFromDefaultAdapter": snap.get("excludedFromDefaultAdapter"),
                "accountCount": len(snap["accounts"]), "errorCount": nerr,
            })
    index.sort(key=lambda r: r["chainId"])

    (out_dir / "index.json").write_text(
        json.dumps({"chains": index, "failures": failures}, indent=1) + "\n")
    print(f"\nwrote {len(index)} snapshots to {out_dir}"
          + (f"; {len(failures)} chain(s) not captured" if failures else ""))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
