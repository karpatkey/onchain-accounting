#!/usr/bin/env python3
"""Build Celestia share proofs for Derive v3 subaccount records (DeriveCelestiaAttestedBalanceAdapter), plus the
signed Derive oracle feeds that price their options (DeriveOptionPricer).

Reads the newest Derive batch the way the adapter does: VAPP.getCelestiaAnchor() gives the Celestia height and
blob commitment; the Derive-namespace blob at that height must recompute to that commitment. The subaccount
section is decoded (Rust bincode varints, 12-decimal zigzag amounts) and the shares holding a record are proven
against the commitment.

Usage:
  derive-celestia-proof.py --subaccount ID [--subaccount ID ...]   prove these records (same owner)
  derive-celestia-proof.py --pick-collateral-only                   pick one record holding only mapped collateral
  derive-celestia-proof.py --pick-options                           pick one USDC + options record in the batch
  derive-celestia-proof.py --preflight SAFE                         settlement check: exit 0 only if nothing is in
                                                                    flight between SAFE and Derive (see "preflight")
    [--hyperevm-rpc URL --since-eth N --since-hyperevm M]           ... and over LayerZero to/from HyperEVM, since the
                                                                    previous settlement's pins (see "Bridge legs")
  options: --out FILE (default stdout), --eth-rpc URL, --celestia-rpc URL, --derive-api URL,
           --block N (read VAPP at block N instead of the newest; rebuilds a fixture for a pinned fork block)

ETH RPC: --eth-rpc, else $MAINNET_URL, else Alchemy with $ALCHEMY_API_KEY. Output JSON (hex strings) is read by
test/balances/AttestedBalanceAdapters/fork/DeriveCelestiaAttestedBalanceAdapter.fork.t.sol and, for option
records, by DeriveCelestiaAttestedBalanceAdapter.t.sol. It carries the blob's share 0 (`firstShare`, which fixes
the share count) and each record's shares, each with its blob index; the adapter derives every share's place in
the tree from those. The proof is only valid until Derive posts the next batch (about 10 minutes); fork tests pin
`forkBlock` instead.

When a record holds options or a negative balance, the adapter values it as equity, and the output also carries
`feeds`: the signed items that price it, from Derive's public/get_latest_signed_feeds, as 1e18 fixed-point decimal
strings (the mark_feeds.json shape: `spots`, and per (currency, expiry) a `forward`, plus `rate` and `vol` for a live
expiry). A spot is included for each currency with a live option and for each non-cash collateral asset of such a
record (COLLATERAL_SPOTS). They are fetched at run time, not at --block, and `valuationTime` is the fetch time: the
pricer takes live-option and spot items for 5 minutes, so fetch and submit together. An expired expiry needs Derive's
settlement item (forward timestamp == expiry). `expected` then mirrors the adapter's equity booking, with options at
an independent float reference of the pricer's formulas, which the adapter matches to 1 micro-USDC
(test/balances/AttestedBalanceAdapters/DeriveCelestiaAttestedBalanceAdapter.t.sol).

Format and evidence: docs/decisions/0031-derive-celestia-attested-adapter.md.
"""
import argparse
import base64
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import time
from decimal import Decimal

VAPP = "0xd330145C17fB6EF2a21ACf1275Ce683A305F58BB"
NAMESPACE = bytes.fromhex("0000000000000000000000000000000000000046023b2bfb8ba6dc6fdc")
GET_ANCHOR = "0xa2704470"  # getCelestiaAnchor()
SHARE = 512
FIRST_DATA = SHARE - 34
CONT_DATA = SHARE - 30
SCALE = 10**12
# Derive protocol asset id -> (symbol, Ethereum token, decimals), from WithdrawalOutbox.resolveAsset.
ASSETS = {
    "0x57b03e14d409adc7fab6cfc44b5886cad2d5f02b": ("USDC", "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", 6),
    "0x5e72430ec945ccc183c34e2860ffc2b5bac712c2": ("USDT", "0xdAC17F958D2ee523a2206206994597C13D831ec7", 6),
    # Derive's HYPE label; its third resolveAsset word is the LayerZero HYPE OFT hype-split bridges in.
    "0x2dd469db6ee0dbf0277f0f3021fd8a6486a751ce": ("HYPE", "0x0762365e088Fb8D285b295d782BB7b23690713e2", 18),
}
CASH_ASSET = "0x57b03e14d409adc7fab6cfc44b5886cad2d5f02b"  # options settle in Derive's USDC
# Derive option asset id -> feed currency, from public/get_instrument `base_asset_address` (2026-11-20).
OPTION_MARKETS = {
    "0x4bb4c3cdc7562f08e9910a0c7d8bb7e108861eb4": "ETH",
    "0xd0711b9ebe84b778483709cde62bacfdbae13623": "BTC",
    "0x7344bf2afff9afcd6d024865fc0ca53bf03464d9": "HYPE",
}
# Derive collateral asset id -> feed currency whose signed spot prices it: the pricer's CollateralSpot table
# (DeriveCelestiaAttestedBalanceAdapter.t.sol `_realCollateralSpots`).
COLLATERAL_SPOTS = {"0x2dd469db6ee0dbf0277f0f3021fd8a6486a751ce": "HYPE"}
# Derive-chain (957) feed contracts: each signed item's EIP-712 verifyingContract (DeriveOptionPricer).
FEED_CONTRACTS = {
    "ETH": {"spot": "0x727aD65db6aE99DB5Dbee8F202846DD6009bf6D5", "forward": "0x791A570F5785FBdb02EA5C7a794c43111ae2f948",
            "rate": "0x14062Edef4E2b7bd5399929E014a271A22dF77E3", "vol": "0xb27cb6b08e6c298C8634D73D5F6649665e90d160"},
    "BTC": {"spot": "0x5Eb59391e7870807aD2C8792E8c5e75838E0fdb0", "forward": "0x958c54bFACc0E2dee586564B31Bf3F171f256279",
            "rate": "0x37D299d9D83186B6043E68c00D58b1F59C965461", "vol": "0x388341d9E5A7D7d5accD738B2a31b0622E0c1b87"},
    "HYPE": {"spot": "0x4fdeC4F8cfA5bddedbc60338516F3cb6ba03b143", "forward": "0x0f79fA7bD5C098b99743a9714bcD11f219C9b695",
             "rate": "0x18522e5D09F3a6964Fc094C230bFcB1AB27e0f17", "vol": "0x481916590863053eA2d8F21B64Ee9429820512d1"},
}
FEED_SIGNERS = ["0xe92024520e22adc1b93e2084e8846122ef1b4f18", "0xee688353d3faf5eb7253dfb8824b6c764d98e763"]
DERIVE_API = "https://api.derive.xyz/v3"
MAX_FEED_AGE = 300  # DeriveOptionPricer.MAX_FEED_AGE
SETTLEMENT_SAMPLES = 1800
SECONDS_PER_YEAR = 365 * 86400


# ------------------------------------------------------------------------------------------------ transport

def _curl(args):
    return subprocess.run(["curl", "-s", "-m", "120", *args], capture_output=True, check=True).stdout


def eth(url, method, params):
    out = json.loads(_curl(["-X", "POST", url, "-H", "content-type: application/json",
                            "-d", json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})]))
    if "error" in out:
        raise RuntimeError(f"{method}: {out['error']}")
    return out["result"]


def celestia_block(url, height):
    for _ in range(4):  # the public node times out on large blocks now and then
        try:
            out = json.loads(_curl([f"{url}/block?height={height}"]))
        except (ValueError, subprocess.CalledProcessError):  # bad JSON, or curl's timeout / transport error
            continue
        if "result" in out:
            return out["result"]
    raise RuntimeError(f"celestia block {height} unavailable")


# ------------------------------------------------------------------------------------------------ celestia

def _pb_varint(b, i):
    v = s = 0
    while True:
        c = b[i]
        i += 1
        v |= (c & 0x7F) << s
        if not c & 0x80:
            return v, i
        s += 7


def _pb_fields(b):
    out, i = [], 0
    while i < len(b):
        k, i = _pb_varint(b, i)
        f, w = k >> 3, k & 7
        if w == 0:
            v, i = _pb_varint(b, i)
        elif w == 2:
            n, i = _pb_varint(b, i)
            v, i = b[i:i + n], i + n
        elif w == 1:
            v, i = b[i:i + 8], i + 8
        elif w == 5:
            v, i = b[i:i + 4], i + 4
        else:
            raise ValueError(f"wire type {w}")
        out.append((f, v))
    return out


def derive_blobs(block):
    for t in block["block"]["data"].get("txs") or []:
        raw = base64.b64decode(t)
        if not raw.endswith(b"\x1a\x04BLOB"):  # BlobTx type marker
            continue
        for f, v in _pb_fields(raw):
            if f == 2:
                blob = dict(_pb_fields(v))  # 1 namespace id, 2 data, 3 share version
                if blob.get(1) in (NAMESPACE, NAMESPACE[1:]) and blob.get(3, 0) == 0:
                    yield blob.get(2, b"")


def shares_of(data):
    out, i, first = [], 0, True
    while first or i < len(data):
        head = NAMESPACE + (b"\x01" + len(data).to_bytes(4, "big") if first else b"\x00")
        chunk = data[i:i + SHARE - len(head)]
        i += len(chunk)
        out.append(head + chunk + b"\x00" * (SHARE - len(head) - len(chunk)))
        first = False
    return out


def _pow2(n):
    r = 1
    while r < n:
        r <<= 1
    return r


def _split(n):
    return 1 << ((n - 1).bit_length() - 1)


def nmt_leaf(share):
    ns = share[:29]
    return ns + ns + hashlib.sha256(b"\x00" + ns + share).digest()  # celestia-app pushes ns‖share


def nmt_node(left, right):
    return NAMESPACE + NAMESPACE + hashlib.sha256(b"\x01" + left + right).digest()


def nmt_levels(leaves):
    levels = [leaves]
    while len(levels[-1]) > 1:
        lv = levels[-1]
        levels.append([nmt_node(lv[j], lv[j + 1]) for j in range(0, len(lv), 2)])
    return levels


def rfc_root(items):
    if len(items) == 1:
        return hashlib.sha256(b"\x00" + items[0]).digest()
    k = _split(len(items))
    return hashlib.sha256(b"\x01" + rfc_root(items[:k]) + rfc_root(items[k:])).digest()


def rfc_path(items, m):
    if len(items) == 1:
        return []
    k = _split(len(items))
    if m < k:
        return rfc_path(items[:k], m) + [rfc_root(items[k:])]
    return rfc_path(items[k:], m - k) + [rfc_root(items[:k])]


def layout(n):
    width = min(_pow2(math.ceil(n / 64)), _pow2(math.ceil(math.sqrt(n))))
    out, i = [], 0
    while i < n:
        size = width if n - i >= width else 1 << ((n - i).bit_length() - 1)
        out.append((i, size))
        i += size
    return out


class Tree:
    """Share commitment of a blob plus the paths to prove any share."""

    def __init__(self, data):
        self.shares = shares_of(data)
        self.subtrees = layout(len(self.shares))
        self.levels = [nmt_levels([nmt_leaf(s) for s in self.shares[a:a + z]]) for a, z in self.subtrees]
        self.roots = [lv[-1][0] for lv in self.levels]
        self.commitment = rfc_root(self.roots)

    def prove(self, i):
        k = next(j for j, (a, z) in enumerate(self.subtrees) if a <= i < a + z)
        pos = i - self.subtrees[k][0]
        sib, p = [], pos
        for lv in self.levels[k][:-1]:
            sib.append(lv[p ^ 1])
            p //= 2
        return {"index": i, "share": "0x" + self.shares[i].hex(),
                "nmtSiblings": ["0x" + x.hex() for x in sib],
                "rfcSiblings": ["0x" + x.hex() for x in rfc_path(self.roots, k)]}


# ------------------------------------------------------------------------------------------------ records

_WIDTH = {0xFB: 2, 0xFC: 4, 0xFD: 8, 0xFE: 16}


def varint(b, i):
    t = b[i]
    if t < 251:
        return t, i + 1
    n = _WIDTH[t]
    return int.from_bytes(b[i + 1:i + 1 + n], "little"), i + 1 + n


def zigzag(v):
    return v >> 1 if v % 2 == 0 else -((v + 1) >> 1)


def parse_record(b, i):
    start = i
    sid, i = varint(b, i)
    if b[i] != 1:
        raise ValueError
    sid2, i = varint(b, i + 1)
    flag, i = varint(b, i)
    if sid2 != sid or flag != 0:
        raise ValueError
    manager, i = varint(b, i)
    owner = "0x" + b[i:i + 20].hex()
    i += 20
    perps, i = varint(b, i)
    for _ in range(perps):
        i += 20
        for _ in range(4):
            _, i = varint(b, i)
    n, i = varint(b, i)
    coll = []
    for _ in range(n):
        asset = "0x" + b[i:i + 20].hex()
        i += 20
        _, i = varint(b, i)
        bal, i = varint(b, i)
        _, i = varint(b, i)
        coll.append((asset, zigzag(bal)))
    n_opts, i = varint(b, i)
    opts = []
    for _ in range(n_opts):
        asset = "0x" + b[i:i + 20].hex()
        i += 20
        sub_id, i = varint(b, i)
        amount, i = varint(b, i)
        opts.append({"asset": asset, "subId": sub_id, "amount": zigzag(amount)})
    for _ in range(4):
        _, i = varint(b, i)
    return {"id": sid, "manager": manager, "owner": owner, "collateral": coll, "perps": perps,
            "options": opts, "span": [start, i]}


_HEAD = re.compile(rb"(?=([\x00-\xfa]|\xfb..|\xfc....)\x01\1)", re.S)


def subaccounts(b):
    """The longest sorted, gap-free run of records in the blob (the subaccount section).

    A head that already started a record inside an earlier run is skipped: the run from it is a suffix of that run,
    so it cannot be longer, and re-decoding it made the scan quadratic in the number of records.
    """
    best, seen = [], set()
    for m in _HEAD.finditer(b):
        if m.start() in seen:
            continue
        out, i = [], m.start()
        try:
            while True:
                r = parse_record(b, i)
                if out and r["id"] <= out[-1]["id"]:
                    break
                out.append(r)
                seen.add(i)
                i = r["span"][1]
        except (ValueError, KeyError, IndexError):
            pass
        if len(out) > len(best):
            best = out
    return best


def data_start(i):
    return 0 if i == 0 else FIRST_DATA + (i - 1) * CONT_DATA


def share_of(p):
    return 0 if p < FIRST_DATA else 1 + (p - FIRST_DATA) // CONT_DATA


def prove_record(tree, recs, k):
    """SubaccountProof for record k, framed by the next head, or by the previous record if k is the last."""
    rec = recs[k]
    b0, b1 = rec["span"]
    use_prev = k == len(recs) - 1
    if use_prev:
        if k == 0:
            sys.exit("record is alone in its section: no neighbour to frame it")
        p0, p_end = recs[k - 1]["span"]
        if p_end != b0:
            sys.exit(f"previous record ends at {p_end}, not at {b0}")
        s0, s1 = share_of(p0), share_of(b1 - 1)
    else:
        s0, s1 = share_of(b0), share_of(b1 + 11)
    return {"subaccountId": rec["id"], "recordOffset": b0 - data_start(s0),
            "usePrevious": use_prev, "prevOffset": (p0 - data_start(s0)) if use_prev else 0,
            "shares": [tree.prove(i) for i in range(s0, s1 + 1)]}


# ------------------------------------------------------------------------------------------------ feeds

class FeedError(ValueError):
    """The records cannot be valued from the feeds at hand (DeriveOptionPricer or the adapter would revert)."""


def _wad(s):
    """Derive's decimal string -> 1e18 fixed-point decimal string, exactly."""
    return str(int(Decimal(s) * 10**18))


def series(sub_id):
    """(expiry, 8-decimal strike, is_call) of an option subId: bits 0-31, 32-94, 95 (DeriveRecord)."""
    return sub_id & 0xFFFFFFFF, (sub_id >> 32) & ((1 << 63) - 1), (sub_id >> 95) & 1 == 1


def fetch_signed_feeds(api, currency):
    out = json.loads(_curl(["-X", "POST", f"{api}/public/get_latest_signed_feeds", "-H",
                            "content-type: application/json", "-d", json.dumps({"currency": currency})]))
    if "result" not in out:
        raise RuntimeError(f"signed feeds for {currency}: {out.get('error')}")
    return out["result"]


def _signed(item, now, live):
    signers = [s.lower() for s in item["signatures"]["signers"]]
    if sorted(signers) != sorted(FEED_SIGNERS):
        raise FeedError(f"{item['currency']}: signed by {signers}, the pricer takes {FEED_SIGNERS}")
    if item["deadline"] < now or item["timestamp"] > now:
        raise FeedError(f"{item['currency']}: item outside [timestamp, deadline] at {now}")
    if live and now - item["timestamp"] > MAX_FEED_AGE:
        raise FeedError(f"{item['currency']}: item from {item['timestamp']} is stale at {now}")
    return {"deadline": item["deadline"], "timestamp": item["timestamp"],
            "signatures": item["signatures"]["signatures"]}


def build_feeds(signed, opts, now, spot_currencies=()):
    """The feed items that price `opts` and the collateral spots at `now`, from `signed` (currency ->
    get_latest_signed_feeds result).

    Exactly the items used, as the pricer rejects unused ones: a spot per currency with a live option or in
    `spot_currencies`; per (currency, expiry) a forward, plus a rate and a vol when the expiry is live.
    """
    need = {cur: set() for cur in spot_currencies}
    for o in opts:
        if o["amount"] == 0:
            continue
        if o["asset"] not in OPTION_MARKETS:
            raise FeedError(f"option asset {o['asset']} has no configured market")
        need.setdefault(OPTION_MARKETS[o["asset"]], set()).add(series(o["subId"])[0])
    feeds = {"spots": [], "expiries": []}
    for cur, expiries in sorted(need.items()):
        f = signed[cur]
        if cur in spot_currencies or any(e > now for e in expiries):
            s = f["spot_data"][cur]
            feeds["spots"].append({"currency": cur, "price": _wad(s["price"]), "confidence": _wad(s["confidence"]),
                                   **_signed(s, now, True)})
        for e in sorted(expiries):
            live, k = e > now, str(e)
            fw = f["fwd_data"][cur].get(k)
            if fw is None:
                raise FeedError(f"{cur} {e}: no signed forward item")
            if not live and fw["timestamp"] != e:
                raise FeedError(f"{cur} {e}: expired, and Derive has not published its settlement item")
            entry = {"currency": cur, "forward": {
                "expiry": e, "start": str(int(Decimal(fw["spot_aggregate_start"]))),
                "latest": str(int(Decimal(fw["spot_aggregate_latest"]))), "fwdDiff": _wad(fw["fwd_diff"]),
                "confidence": _wad(fw["confidence"]), **_signed(fw, now, live)}}
            if live:
                rt, vo = f["rate_data"][cur].get(k), f["vol_data"][cur].get(k)
                if rt is None or vo is None:
                    raise FeedError(f"{cur} {e}: no signed rate or vol item")
                v = vo["vol_data"]
                entry["rate"] = {"expiry": e, "rate": _wad(rt["rate"]), "confidence": _wad(rt["confidence"]),
                                 **_signed(rt, now, True)}
                entry["vol"] = {"expiry": e, "a": _wad(v["SVI_a"]), "b": _wad(v["SVI_b"]), "rho": _wad(v["SVI_rho"]),
                                "m": _wad(v["SVI_m"]), "sigma": _wad(v["SVI_sigma"]), "sviFwd": _wad(v["SVI_fwd"]),
                                "refTau": _wad(v["SVI_refTau"]), "confidence": _wad(vo["confidence"]),
                                **_signed(vo, now, True)}
            feeds["expiries"].append(entry)
    return feeds


# ------------------------------------------------------------------------------------------------ reference pricer
# Float re-derivation of DeriveOptionPricer from the published formulas (decision 0031), written apart from the
# Solidity fixed-point code so each checks the other. Doubles carry ~1e-15 relative error: far below 1 micro-USDC.

def _f(s):
    return int(s) / 1e18


def norm_cdf(x):
    return 0.5 * math.erfc(-x / math.sqrt(2))


def black76(fwd, strike, vol, tau, rate, is_call):
    disc = math.exp(-max(rate, 0.0) * tau)
    total_vol, m = vol * math.sqrt(tau), strike / fwd
    std_call = 1.0
    if total_vol < 24:
        d1 = (total_vol * total_vol / 2 - math.log(m)) / total_vol
        std_call = max(norm_cdf(d1) - m * norm_cdf(d1 - total_vol), 0.0)
    if is_call:
        return min(std_call * fwd * disc, fwd * disc)
    return min(max(std_call + m - 1, 0.0) * fwd * disc, strike * disc)


def svi_vol(v, strike):
    a, b, rho, m, sigma = _f(v["a"]), _f(v["b"]), _f(v["rho"]), _f(v["m"]), _f(v["sigma"])
    bound = 4 * math.sqrt(a + b * sigma)
    k = min(max(math.log(strike / _f(v["sviFwd"])), -bound), bound)
    w = a + b * (rho * (k - m) + math.sqrt((k - m) ** 2 + sigma * sigma))
    if w < 0:
        raise FeedError("negative SVI variance")
    return math.sqrt(min(w, 144.0) / _f(v["refTau"]))


def option_value12(o, feeds, now):
    """Signed 12-decimal USD value of one option: a long rounded down, a short rounded up and negated."""
    cur = OPTION_MARKETS[o["asset"]]
    expiry, strike8, is_call = series(o["subId"])
    entry = next((x for x in feeds["expiries"] if x["currency"] == cur and x["forward"]["expiry"] == expiry), None)
    if entry is None:
        raise FeedError(f"{cur} {expiry}: no forward in feeds")
    mag = abs(o["amount"])
    if expiry <= now:
        fw = entry["forward"]
        settle = (int(fw["latest"]) - int(fw["start"])) // SETTLEMENT_SAMPLES
        strike18 = strike8 * 10**10
        p18 = max(settle - strike18, 0) if is_call else max(strike18 - settle, 0)
        return mag * p18 // 10**18 if o["amount"] > 0 else -((mag * p18 + 10**18 - 1) // 10**18)
    spot = next(_f(s["price"]) for s in feeds["spots"] if s["currency"] == cur)
    fwd = spot + _f(entry["forward"]["fwdDiff"])
    strike = strike8 / 1e8
    price = black76(fwd, strike, svi_vol(entry["vol"], strike), (expiry - now) / SECONDS_PER_YEAR,
                    _f(entry["rate"]["rate"]), is_call)
    v = mag * price
    return math.floor(v) if o["amount"] > 0 else -math.ceil(v)


def needs_equity(r):
    """The adapter values a record as equity when it holds options or any negative balance (_bookPriced)."""
    return bool(r["options"]) or any(bal < 0 for _, bal in r["collateral"])


def spot_currencies(recs):
    """Feed currencies whose spot prices the non-cash collateral of the records valued as equity."""
    out = set()
    for r in recs:
        if not needs_equity(r):
            continue
        for asset, bal in r["collateral"]:
            if bal == 0 or asset not in ASSETS or asset == CASH_ASSET:
                continue
            if asset not in COLLATERAL_SPOTS:
                raise FeedError(f"subaccount {r['id']}: {ASSETS[asset][0]} collateral has no spot feed")
            out.add(COLLATERAL_SPOTS[asset])
    return out


def _ceil_div(a, b):
    return -(-a // b)


def _spot18(feeds, asset):
    cur = COLLATERAL_SPOTS[asset]
    s = next((s for s in feeds["spots"] if s["currency"] == cur), None)
    if s is None:
        raise FeedError(f"{cur}: no spot in feeds")
    return int(s["price"])


def expected_amounts(recs, feeds=None, now=None):
    """Token -> amount the adapter reports for these records, mirroring _addCollateral and _addEquity.

    Raw 12-decimal balances are summed per token before converting once, as the adapter does: rounding each entry
    first can come out lower across several subaccounts. A record with options or debt is equity in USD: cash at 1,
    non-cash collateral at its signed spot (debt rounded up), options at the reference. Non-cash legs keep their
    units; cash, options and debt net into USDC; a negative net is taken from the same record's non-cash legs at spot,
    rounded up, and one larger than they are worth is refused (NegativeEquity). Every mapped token a record covers is
    listed, zero included, as the adapter writes it.
    """
    raw = {}

    def add(asset, amount):
        _, token, dec = ASSETS[asset]
        raw[(token, dec)] = raw.get((token, dec), 0) + amount

    for r in recs:
        for asset, bal in r["collateral"]:
            if bal != 0 and asset not in ASSETS:
                raise FeedError(f"subaccount {r['id']}: unmapped asset {asset}")
        if not needs_equity(r):
            for asset, bal in r["collateral"]:
                if asset in ASSETS:
                    add(asset, bal)
            continue
        net = sum(option_value12(o, feeds, now) for o in r["options"] if o["amount"] != 0)
        non_cash, legs = 0, []
        for asset, bal in r["collateral"]:
            if asset not in ASSETS:
                continue
            if asset == CASH_ASSET:
                net += bal
            elif bal > 0:
                spot = _spot18(feeds, asset)
                non_cash += bal * spot // 10**18
                legs.append((asset, bal, spot))
            else:
                if bal < 0:
                    net -= _ceil_div(-bal * _spot18(feeds, asset), 10**18)
                legs.append((asset, 0, None))
        shortfall = max(-net, 0)
        if shortfall > non_cash:
            raise FeedError(f"subaccount {r['id']}: equity below 0 (options and debt exceed its collateral)")
        add(CASH_ASSET, max(net, 0))
        for asset, units, spot in legs:
            if shortfall and units:
                take = min(shortfall, units * spot // 10**18)
                units -= _ceil_div(take * 10**18, spot)
                shortfall -= take
            add(asset, units)
    return {token: (bal * 10 ** (dec - 12) if dec >= 12 else bal // 10 ** (12 - dec))
            for (token, dec), bal in raw.items()}


def value_with_feeds(recs, signed, now):
    """(feeds, expected) for records valued as equity; raises FeedError when they cannot be valued."""
    feeds = build_feeds(signed, [o for r in recs for o in r["options"]], now, spot_currencies(recs))
    return feeds, expected_amounts(recs, feeds, now)


def is_option_candidate(r, max_options=12):
    """No perps, USDC as the only non-zero collateral, 1..max_options options, all in configured markets."""
    live = [o for o in r["options"] if o["amount"] != 0]
    return (r["perps"] == 0 and 0 < len(live) <= max_options
            and all(o["asset"] in OPTION_MARKETS for o in live)
            and all(bal == 0 or (asset == CASH_ASSET and bal > 0) for asset, bal in r["collateral"]))


# ------------------------------------------------------------------------------------------------ preflight
# Settlement in-flight check (docs/plans/2026-11-27-derive-in-flight-value.md). Value between a fund Safe and Derive
# is in neither NAV leg: a deposit queued on Ethereum but not yet applied by a batch, a withdrawal parked in the
# outbox's rate-limit queue, or a withdrawal deferred after a failed transfer. The settlement guard runs this right
# before it signs and skips the window unless it passes; it reads Ethereum only, all at one block. It runs before the
# settlement transaction, not inside it, so the gap between the two must be kept to seconds.
#
# Pending actions: action ids are `publicAccHistory.length - 1` at queue time (ActionManager `_appendPublic`), and
# VAPP.consumedPublicAccIndex() is the first id no batch has consumed yet, so an action is pending iff
# id >= consumedPublicAccIndex. A queued withdrawal request also fails the check although its value is still in the
# attested subaccount until its batch: conservative on purpose, keep it.
# Queued withdrawals: an entry stays in the bucket chosen when it was enqueued, which can differ from the Safe's
# current bucketKey, so each is read where its WithdrawalEnqueued says; a paid entry is deleted (id becomes zero).
# Deferred withdrawals: unpaid iff deferredWithdrawals(deferredId) != 0 (deferredProcess deletes it; `consumed(id)`
# is replay protection and true for every deferred one).
# A deposit's `fallbackRecipient` receives the funds if Derive cannot apply it; the check clears once the action is
# consumed, so a fund must name its own wallet as fallback.

ACTION_MANAGER = "0xE366CcA474968e33b777E13905829A3b800CFAD3"
OUTBOX = "0x7c743D79C9C595cE332314503d84cBBb4E85FA63"
# First block with code at each proxy (eth_getCode bisection, 2026-11-27): no event can predate it.
ACTION_MANAGER_FROM_BLOCK = 26_097_581
OUTBOX_FROM_BLOCK = 26_097_577
# keccak256 of the event signatures and function selectors (`cast keccak` / `cast sig`; hashlib has no keccak):
# PublicActionQueued(uint256,address,uint64,bytes,bytes32), WithdrawalEnqueued(bytes32,address,address,uint128,
# address,address,uint256), WithdrawalDeferred(uint256,bytes32,address,uint64,address,uint128); consumedPublicAccIndex(),
# DEPOSIT_TYPE(), DEPOSIT_TO_NEW_SUBACCOUNT_TYPE(), WITHDRAWAL_TYPE(), deferredWithdrawals(uint256),
# queueEntry(address,address,uint256).
TOPIC_PUBLIC_ACTION = "0xea5d2d4aa41b860cc464a7033c748b8a87630dac2abbd1ce7db29afd94154c76"
TOPIC_ENQUEUED = "0x34f5d9b906f59607b40497097216f665902a0cdae9f864bf7242dd87c8999f0c"
TOPIC_DEFERRED = "0xd02ce5c2994eabd72f0129570fcba54f6904ab570305000af144d6eb540e5687"
SEL_CONSUMED_PUBLIC = "0xf0d739e2"
SEL_ACTION_TYPES = ("0x14ba698f", "0xa4a61859", "0x4b3ccf18")
SEL_DEFERRED = "0xdfca460a"
SEL_QUEUE_ENTRY = "0xc3ed098a"
# The scans start at deployment, so they need an archive RPC (publicnode refuses: "Archive requests require a
# personal token"). Alchemy answers each whole scan in one call (the three take about 2 s, 2026-11-27); 10,000-block
# chunks took 90-107 s. A provider with a smaller range cap fails with exit 2 and needs a smaller --log-chunk.
LOG_CHUNK = 500_000


def _topic(addr):
    return "0x" + addr[2:].lower().rjust(64, "0")


def _words(hexdata):
    h = hexdata[2:]
    return [int(h[i:i + 64], 16) for i in range(0, len(h), 64)]


def _addr(word):
    return "0x" + f"{word:064x}"[24:]


def _call(rpc, to, data, block):
    return _words(rpc("eth_call", [{"to": to, "data": data}, hex(block)]))


def chunked_logs(rpc, address, topics, start, end, chunk):
    """Every log of `address` matching `topics` in [start, end], fetched in `chunk`-block ranges."""
    lo = start
    while lo <= end:
        hi = min(lo + chunk - 1, end)
        yield from rpc("eth_getLogs", [{"address": address, "topics": topics, "fromBlock": hex(lo), "toBlock": hex(hi)}])
        lo = hi + 1


def preflight(rpc, safe, block, chunk=LOG_CHUNK):
    """In-flight value of `safe` at `block`; `ok` only if there is none. `rpc(method, params)` is the transport."""
    safe = safe.lower()
    consumed = _call(rpc, VAPP, SEL_CONSUMED_PUBLIC, block)[0]
    types = {_call(rpc, ACTION_MANAGER, s, block)[0] for s in SEL_ACTION_TYPES}
    pending = []
    for lg in chunked_logs(rpc, ACTION_MANAGER, [TOPIC_PUBLIC_ACTION, None, _topic(safe)],
                           ACTION_MANAGER_FROM_BLOCK, block, chunk):
        action_id, action_type = int(lg["topics"][1], 16), int(lg["topics"][3], 16)
        if action_id >= consumed and action_type in types:
            pending.append({"actionId": action_id, "actionType": action_type, "tx": lg["transactionHash"]})

    queued = []
    for lg in chunked_logs(rpc, OUTBOX, [TOPIC_ENQUEUED, None, None, _topic(safe)], OUTBOX_FROM_BLOCK, block, chunk):
        wid = lg["topics"][1]
        _, b_recipient, b_asset, index = _words(lg["data"])
        data = SEL_QUEUE_ENTRY + f"{b_recipient:064x}{b_asset:064x}{index:064x}"
        entry_id, asset, _, _, remaining = _call(rpc, OUTBOX, data, block)
        if f"0x{entry_id:064x}" == wid.lower():  # processQueue deletes an entry once paid in full
            queued.append({"id": wid, "asset": _addr(asset), "remaining": remaining,
                           "bucket": [_addr(b_recipient), _addr(b_asset)], "queueIndex": index})

    deferred = []
    for lg in chunked_logs(rpc, OUTBOX, [TOPIC_DEFERRED], OUTBOX_FROM_BLOCK, block, chunk):
        _, recipient, amount = _words(lg["data"])
        did = int(lg["topics"][1], 16)
        if _addr(recipient) == safe and _call(rpc, OUTBOX, SEL_DEFERRED + f"{did:064x}", block)[0] != 0:
            deferred.append({"deferredId": did, "id": lg["topics"][2], "asset": _addr(int(lg["topics"][3], 16)),
                             "amount": amount})

    reasons = ([f"action {p['actionId']} (type {p['actionType']}) not yet applied by a batch" for p in pending]
               + [f"withdrawal {q['id']} queued in the outbox, {q['remaining']} left" for q in queued]
               + [f"withdrawal {d['id']} deferred (id {d['deferredId']}), unpaid" for d in deferred])
    return {"ok": not reasons, "block": block, "safe": safe, "pendingActions": pending, "queued": queued,
            "deferred": deferred, "reasons": reasons}


# Bridge legs (plan Phase 2): the fund's shares live on HyperEVM, Derive is reached from Ethereum, and HYPE crosses
# over LayerZero V2 (HyperEVM native OFT adapter, locking native HYPE <-> Ethereum HYPE OFT, mint/burn). The operator
# reads each chain at its own pinned block, so a transfer is counted on its source iff it was sent after the source
# pin, and on its destination iff it was received at or before the destination pin. Exactly once is right; both is
# a double count (the two reads are not simultaneous), neither is in flight. Scans start at the previous settlement's
# pins: that settlement proved nothing was in flight then.
ETHEREUM, HYPEREVM = "ethereum", "hyperevm"
OFT = {ETHEREUM: "0x0762365e088Fb8D285b295d782BB7b23690713e2", HYPEREVM: "0x1e0470ef72d029bdc87d3b8543fb62fc04db9670"}
CHAIN_OF_EID = {30101: ETHEREUM, 30367: HYPEREVM}
WHYPE = "0x5555555555555555555555555555555555555555"  # HyperEVM wrapped HYPE; the fund holds HYPE as native or WHYPE
# OFTSent(bytes32,uint32,address,uint256,uint256), OFTReceived(bytes32,uint32,address,uint256), balanceOf(address).
TOPIC_OFT_SENT = "0x85496b760a4b7f8d66384b9df21b381f5d1b1e79f229a47aaf4c232edc2fe59a"
TOPIC_OFT_RECEIVED = "0xefed6d3500546b29533b128a29e3a94d70788727f0507505ac12eaf2e578fd9c"
SEL_BALANCE_OF = "0x70a08231"
# Alchemy's HyperEVM endpoint answers a filtered 1,000,000-block eth_getLogs in about 0.3 s. The public
# rpc.hyperliquid.xyz/evm is not usable for these scans: 10,000-block queries time out, and of two filtered
# 1,000-block queries one returned at once and the other timed out after 90 s (2026-11-27).
HYPEREVM_LOG_CHUNK = 1_000_000


def bridge_check(chains, safe):
    """Holdings at the pins and every LayerZero transfer of `safe` since the last settlement, classified.

    `chains[name]` = {"rpc", "pin", "since", "chunk"} for ETHEREUM and HYPEREVM.
    """
    safe = safe.lower()
    head = {c: int(v["rpc"]("eth_blockNumber", []), 16) for c, v in chains.items()}

    def scan(c, topics, since=None):
        v = chains[c]
        return chunked_logs(v["rpc"], OFT[c], topics, v["since"] if since is None else since, head[c], v["chunk"])

    received = {}
    for c in chains:
        for lg in scan(c, [TOPIC_OFT_RECEIVED, None, _topic(safe)]):
            received[lg["topics"][1].lower()] = {"chain": c, "to": safe, "block": int(lg["blockNumber"], 16),
                                                 "amount": _words(lg["data"])[1]}
    transfers, reasons = [], []
    for c in chains:
        pin_src = chains[c]["pin"]
        for lg in scan(c, [TOPIC_OFT_SENT, None, _topic(safe)]):
            guid = lg["topics"][1].lower()
            dst_eid, amount, _ = _words(lg["data"])
            dst = CHAIN_OF_EID.get(dst_eid)
            sent = int(lg["blockNumber"], 16)
            rec = received.pop(guid, None)
            if rec is None and dst is not None:  # delivered to someone else, or not yet
                for r in scan(dst, [TOPIC_OFT_RECEIVED, guid]):
                    rec = {"chain": dst, "to": _addr(int(r["topics"][2], 16)), "block": int(r["blockNumber"], 16),
                           "amount": _words(r["data"])[1]}
            t = {"guid": guid, "from": c, "to": dst, "recipient": rec and rec["to"], "amount": amount,
                 "sentBlock": sent, "receivedBlock": rec and rec["block"]}
            on_src = sent > pin_src
            if dst is None:
                t["verdict"] = "ok" if on_src else "unknown destination"
            elif rec is not None and rec["to"] != safe:
                t["verdict"] = "payout"  # leaves the fund on receipt; counted at the source until sent
            else:
                on_dst = rec is not None and rec["block"] <= chains[dst]["pin"]
                t["verdict"] = "double count" if on_src and on_dst else "ok" if on_src or on_dst else "in flight"
            if t["verdict"] in ("in flight", "double count", "unknown destination"):
                reasons.append(f"bridge {guid} {c} -> {dst or dst_eid}: {t['verdict']} "
                               f"(sent {sent}, received {t['receivedBlock']}, pins {pin_src}/"
                               f"{chains[dst]['pin'] if dst else '-'})")
            transfers.append(t)
    for guid, rec in received.items():  # inflows the Safe did not send: counted on arrival only
        transfers.append({"guid": guid, "from": None, "to": rec["chain"], "recipient": safe, "amount": rec["amount"],
                          "sentBlock": None, "receivedBlock": rec["block"], "verdict": "inflow"})

    def balance_of(c, token):
        return _call(chains[c]["rpc"], token, SEL_BALANCE_OF + safe[2:].rjust(64, "0"), chains[c]["pin"])[0]

    hyp = chains[HYPEREVM]
    holdings = {"hyperevmNative": int(hyp["rpc"]("eth_getBalance", [safe, hex(hyp["pin"])]), 16),
                "hyperevmWhype": balance_of(HYPEREVM, WHYPE), "ethereumHype": balance_of(ETHEREUM, OFT[ETHEREUM])}
    holdings["outsideDerive"] = sum(holdings.values())  # the Derive leg comes from the attested adapter
    return {"pins": {c: v["pin"] for c, v in chains.items()}, "holdings": holdings, "transfers": transfers,
            "reasons": reasons}


def preflight_verdict(rpc, safe, block=None, chunk=LOG_CHUNK, hyperevm=None):
    """(exit code, report): 0 nothing in flight, 1 something is (skip the window), 2 a read failed (skip too).

    `block` None reads at the current head. `hyperevm` = {"rpc", "pin" (None: head), "since", "chunk", "sinceEth"}
    adds the bridge legs.
    """
    try:
        block = block or int(rpc("eth_blockNumber", []), 16)
        report = preflight(rpc, safe, block, chunk)
        if hyperevm:
            pin_h = hyperevm["pin"] or int(hyperevm["rpc"]("eth_blockNumber", []), 16)
            bridge = bridge_check({
                ETHEREUM: {"rpc": rpc, "pin": block, "since": hyperevm["sinceEth"], "chunk": chunk},
                HYPEREVM: {"rpc": hyperevm["rpc"], "pin": pin_h, "since": hyperevm["since"],
                           "chunk": hyperevm["chunk"]},
            }, safe)
            report["bridge"] = bridge
            report["reasons"] += bridge["reasons"]
            report["ok"] = not report["reasons"]
    except (RuntimeError, ValueError, KeyError, IndexError, subprocess.CalledProcessError) as e:
        return 2, {"ok": False, "block": block, "safe": safe.lower(), "error": f"{type(e).__name__}: {e}"}
    return (0 if report["ok"] else 1), report


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--subaccount", type=int, action="append")
    g.add_argument("--pick-collateral-only", action="store_true")
    g.add_argument("--pick-options", action="store_true")
    g.add_argument("--preflight", metavar="SAFE")
    ap.add_argument("--log-chunk", type=int, default=LOG_CHUNK)
    ap.add_argument("--hyperevm-rpc", help="with --preflight: also check the LayerZero legs to/from HyperEVM")
    ap.add_argument("--hyperevm-block", type=int, help="HyperEVM pin (default: head)")
    ap.add_argument("--hyperevm-log-chunk", type=int, default=HYPEREVM_LOG_CHUNK)
    ap.add_argument("--since-eth", type=int, help="previous settlement's Ethereum pin (first: the Safe's deployment)")
    ap.add_argument("--since-hyperevm", type=int, help="previous settlement's HyperEVM pin")
    ap.add_argument("--out")
    ap.add_argument("--eth-rpc")
    ap.add_argument("--celestia-rpc", default="https://rpc.celestia.pops.one")
    ap.add_argument("--derive-api", default=DERIVE_API)
    ap.add_argument("--block", type=int)
    a = ap.parse_args()

    eth_url = a.eth_rpc or os.environ.get("MAINNET_URL") or (
        f"https://eth-mainnet.g.alchemy.com/v2/{os.environ['ALCHEMY_API_KEY']}" if os.environ.get("ALCHEMY_API_KEY")
        else "https://ethereum-rpc.publicnode.com")
    if a.preflight:
        hyperevm = None
        if a.hyperevm_rpc:
            if a.since_eth is None or a.since_hyperevm is None:
                ap.error("--hyperevm-rpc needs --since-eth and --since-hyperevm (the previous settlement's pins)")
            hyperevm = {"rpc": lambda m, p: eth(a.hyperevm_rpc, m, p), "pin": a.hyperevm_block,
                        "since": a.since_hyperevm, "sinceEth": a.since_eth, "chunk": a.hyperevm_log_chunk}
        code, report = preflight_verdict(lambda m, p: eth(eth_url, m, p), a.preflight, a.block, a.log_chunk,
                                         hyperevm)
        print(json.dumps(report, indent=1))
        sys.exit(code)
    block = a.block or int(eth(eth_url, "eth_blockNumber", []), 16)
    anchor = eth(eth_url, "eth_call", [{"to": VAPP, "data": GET_ANCHOR}, hex(block)])[2:]
    height, commitment = int(anchor[0:64], 16), "0x" + anchor[128:192]

    tree = data = None
    for blob in derive_blobs(celestia_block(a.celestia_rpc, height)):
        t = Tree(blob)
        if "0x" + t.commitment.hex() == commitment:
            tree, data = t, blob
            break
    if tree is None:
        sys.exit(f"no Derive blob at Celestia {height} recomputes to {commitment}")

    recs = subaccounts(data)
    by_id = {r["id"]: k for k, r in enumerate(recs)}
    signed, now = {}, int(time.time())

    def feeds_for(rs):
        curs = {OPTION_MARKETS[o["asset"]] for r in rs for o in r["options"]
                if o["amount"] != 0 and o["asset"] in OPTION_MARKETS}
        for cur in curs | spot_currencies(rs):
            if cur not in signed:
                signed[cur] = fetch_signed_feeds(a.derive_api, cur)
        return value_with_feeds(rs, signed, now)

    feeds = None
    if a.pick_collateral_only:
        ok = [k for k, r in enumerate(recs)
              if r["perps"] == 0 and not r["options"] and r["collateral"]
              and all(bal >= 0 and asset in ASSETS for asset, bal in r["collateral"])
              and any(bal > 0 for _, bal in r["collateral"])]
        if not ok:
            sys.exit("no subaccount holding only mapped collateral in the newest batch; try after the next batch")
        ks = [ok[0]]
    elif a.pick_options:
        ks = None
        for k, r in enumerate(recs):
            if not is_option_candidate(r):
                continue
            try:
                feeds, expected = feeds_for([r])
            except FeedError as e:
                print(f"skip {r['id']}: {e}", file=sys.stderr)
                continue
            ks = [k]
            break
        if ks is None:
            sys.exit("no USDC + options subaccount in the newest batch can be valued; try after the next batch")
    else:
        missing = [s for s in a.subaccount if s not in by_id]
        if missing:
            sys.exit(f"subaccounts {missing} are not in the newest batch: touch them and retry")
        ks = sorted(by_id[s] for s in a.subaccount)
    owners = {recs[k]["owner"] for k in ks}
    if len(owners) != 1:
        sys.exit(f"subaccounts belong to different owners: {owners}")

    chosen = [recs[k] for k in ks]
    if feeds is None and any(needs_equity(r) for r in chosen):
        try:
            feeds, expected = feeds_for(chosen)
        except FeedError as e:
            sys.exit(str(e))
    elif feeds is None:
        expected = expected_amounts(chosen)

    out = {"forkBlock": block, "celestiaHeight": height, "commitment": commitment, "account": owners.pop(),
           "firstShare": tree.prove(0),
           "proofs": [prove_record(tree, recs, k) for k in ks],
           "expected": [{"token": t, "amount": v} for t, v in expected.items()]}
    if feeds is not None:
        out.update({"valuationTime": now, "signers": FEED_SIGNERS, "feedContracts": FEED_CONTRACTS,
                    "optionAssets": {cur: asset for asset, cur in OPTION_MARKETS.items()}, "feeds": feeds})
    text = json.dumps(out, indent=1)
    if a.out:
        with open(a.out, "w") as fh:
            fh.write(text + "\n")
    else:
        print(text)


if __name__ == "__main__":
    main()
