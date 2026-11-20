#!/usr/bin/env python3
"""Build Celestia share proofs for Derive v3 subaccount records (DeriveCelestiaAttestedBalanceAdapter).

Reads the newest Derive batch the way the adapter does: VAPP.getCelestiaAnchor() gives the Celestia height and
blob commitment; the Derive-namespace blob at that height must recompute to that commitment. The subaccount
section is decoded (Rust bincode varints, 12-decimal zigzag amounts) and the shares holding a record are proven
against the commitment.

Usage:
  derive-celestia-proof.py --subaccount ID [--subaccount ID ...]   prove these records (same owner)
  derive-celestia-proof.py --pick-collateral-only                   pick one USDC/USDT-only record in the batch
  options: --out FILE (default stdout), --eth-rpc URL, --celestia-rpc URL,
           --block N (read VAPP at block N instead of the newest; rebuilds a fixture for a pinned fork block)

ETH RPC: --eth-rpc, else $MAINNET_URL, else Alchemy with $ALCHEMY_API_KEY. Output JSON (hex strings) is read by
test/balances/AttestedBalanceAdapters/fork/DeriveCelestiaAttestedBalanceAdapter.fork.t.sol. It carries the blob's
share 0 (`firstShare`, which fixes the share count) and each record's shares, each with its blob index; the
adapter derives every share's place in the tree from those. The proof is only valid until Derive posts the next
batch (about 10 minutes); fork tests pin `forkBlock` instead.

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
}


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
    options, i = varint(b, i)
    for _ in range(options):
        i += 20
        for _ in range(2):
            _, i = varint(b, i)
    for _ in range(4):
        _, i = varint(b, i)
    return {"id": sid, "manager": manager, "owner": owner, "collateral": coll, "perps": perps,
            "options": options, "span": [start, i]}


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


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--subaccount", type=int, action="append")
    g.add_argument("--pick-collateral-only", action="store_true")
    ap.add_argument("--out")
    ap.add_argument("--eth-rpc")
    ap.add_argument("--celestia-rpc", default="https://rpc.celestia.pops.one")
    ap.add_argument("--block", type=int)
    a = ap.parse_args()

    eth_url = a.eth_rpc or os.environ.get("MAINNET_URL") or (
        f"https://eth-mainnet.g.alchemy.com/v2/{os.environ['ALCHEMY_API_KEY']}" if os.environ.get("ALCHEMY_API_KEY")
        else "https://ethereum-rpc.publicnode.com")
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
    if a.pick_collateral_only:
        ok = [k for k, r in enumerate(recs)
              if r["perps"] == 0 and r["options"] == 0 and r["collateral"]
              and all(bal >= 0 and asset in ASSETS for asset, bal in r["collateral"])
              and any(bal > 0 for _, bal in r["collateral"])]
        if not ok:
            sys.exit("no USDC/USDT-only subaccount in the newest batch; try again after the next batch")
        ks = [ok[0]]
    else:
        missing = [s for s in a.subaccount if s not in by_id]
        if missing:
            sys.exit(f"subaccounts {missing} are not in the newest batch: touch them and retry")
        ks = sorted(by_id[s] for s in a.subaccount)
    owners = {recs[k]["owner"] for k in ks}
    if len(owners) != 1:
        sys.exit(f"subaccounts belong to different owners: {owners}")

    # Collateral only (options need the signed feeds). Sum raw 12-decimal balances per token first, then convert
    # once, as the adapter does: rounding each entry first can come out lower across several subaccounts.
    raw = {}
    for k in ks:
        for asset, bal in recs[k]["collateral"]:
            if bal > 0 and asset in ASSETS:
                _, token, dec = ASSETS[asset]
                raw[(token, dec)] = raw.get((token, dec), 0) + bal
    expected = {token: (bal * 10 ** (dec - 12) if dec >= 12 else bal // 10 ** (12 - dec))
                for (token, dec), bal in raw.items()}

    out = {"forkBlock": block, "celestiaHeight": height, "commitment": commitment, "account": owners.pop(),
           "firstShare": tree.prove(0),
           "proofs": [prove_record(tree, recs, k) for k in ks],
           "expected": [{"token": t, "amount": v} for t, v in expected.items()]}
    text = json.dumps(out, indent=1)
    if a.out:
        with open(a.out, "w") as fh:
            fh.write(text + "\n")
    else:
        print(text)


if __name__ == "__main__":
    main()
