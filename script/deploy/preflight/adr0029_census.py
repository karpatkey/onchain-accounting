#!/usr/bin/env python3
"""ADR 0029 pre-upgrade census: Rule 1 (custom feeds swapped) and Rule 2 (no primary heartbeat >= 7 days).

Read-only. Run it per chain right BEFORE the NAV implementation upgrade (`script/deploy/ADR0029_ROLLOUT.md`), and
again after; any ERROR blocks the upgrade on that chain.

RULE 1 - every `PriceType.Custom` feed the live NAV uses is a NEW feed
---------------------------------------------------------------------
Walks the live proxy: `getRegisteredAssets()` x (`getPriceFeeds`, `getMonitorFeeds`). For every Custom entry,
primary and monitor alike:
  * it must be an address in this tree's `deployments/<chainId>.json .customPriceFeeds` (the record `03` updates
    after the CREATE2 deploy), and
  * it must NOT be an address of the PRE-ROLLOUT record (`--base`, default `origin/main`). Without this second
    check the census passes before anything is deployed: until `03` runs, the record still holds the old
    addresses, which are exactly the ones live. After #354/#358 merge, `origin/main` holds the NEW addresses, so
    pass `--base <the pre-rollout commit>` for any later run.
The swap scripts are config-driven, so an asset registered on-chain but absent from config, or one a script
skipped, is invisible to them; this walk is not. It does not prove the new addresses run this tree's bytecode -
`bytecode_audit.py <chainId>` does that, and the rollout runs it after each chain's deploy.

RULE 2 - no stored primary heartbeat at or above MAX_STALE_PRICE_AGE
--------------------------------------------------------------------
`PriceFeedLib.addFeed` refuses such a heartbeat only when one is written; a stored one keeps the old
fresh-to-zero cliff after the upgrade. `type(uint256).max` is exempt (never stale by age).

ALSO REPORTED (context, never an error): the live implementation (ERC-1967 slot), whether the NAV has an L2
sequencer uptime feed (Rule 1's hazard is real only there), and, per Custom feed, whether it reads the NAV
(`NAV()` == the proxy, i.e. built with `NavBaseUsdLib`) - the feeds that carry the sequencer hazard.

LIVE-ONLY MODE (`--live-only`, for Robinhood 4663, which has no record in this repo): Rule 2 as above; Rule 1
cannot be checked against a record, so every Custom feed is LISTED (as a WARN) for the manual check the rollout
doc describes.

usage:
  python3 adr0029_census.py --chain 1 --chain 8453            # Rule 1 + Rule 2 against this tree's records
  python3 adr0029_census.py                                   # every chain with a deployment record
  python3 adr0029_census.py --chain 4663 --live-only --rpc-env RH_URL --env-file ../onchain-investment-vehicles/.env
  python3 adr0029_census.py --chain 1 --rpc-env ANVIL_URL     # e.g. a local fork rehearsal (URL read from env)
The RPC URL is only ever read from the environment and never printed.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import chainlib as c

ERROR = "ERROR"
WARN = "WARN"
INFO = "INFO"

NAV_PROXY = "0x54ead2a1db7456ca917675ea8908ec8a997c6214"
MAX_STALE_PRICE_AGE = 7 * 24 * 3600
UINT256_MAX = 2**256 - 1
CUSTOM = 3  # IPrices.PriceType: Chainlink 0, Redstone 1, API3 2, Custom 3 (src/prices/IPrices.sol)
IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"

SEL_GET_REGISTERED_ASSETS = "0xcf5cb132"  # getRegisteredAssets()
SEL_GET_PRICE_FEEDS = "0x7cc6ce52"  # getPriceFeeds(address)
SEL_GET_MONITOR_FEEDS = "0x8dca81c3"  # getMonitorFeeds(address)
SEL_SEQUENCER_FEED = "0x35834599"  # chainlinkL2SequencerUptimeFeed()
SEL_NAV = "0x52fd856b"  # NAV()


_URL_RE = re.compile(r"(?:https?|wss?)://\S+|with url: \S+|/v[0-9]/[A-Za-z0-9_-]+|host='[^']*'|'[\w.-]+\.[a-z]{2,}(?:/\S*)?'")


def _safe(e: Exception, n: int = 160) -> str:
    """An exception's text with any URL, API-key path or host removed: transport errors from `requests` embed the
    full RPC URL, and these messages are printed and pasted into reviews."""
    return _URL_RE.sub("<rpc>", str(e))[:n]


class CensusError(Exception):
    """A reply this tool cannot read. Raised instead of `assert`, so the checks survive `python3 -O`."""


# ---------------------------------------------------------------------------
# ABI decoding, by hand (the CI preflight job installs only `requests`)
# ---------------------------------------------------------------------------

def _raw(ret_hex: str) -> bytes:
    if not isinstance(ret_hex, str):
        raise CensusError(f"non-string reply {ret_hex!r}")
    return bytes.fromhex(ret_hex[2:] if ret_hex.startswith("0x") else ret_hex)


def _word(raw: bytes, at: int) -> int:
    if at + 32 > len(raw):
        raise CensusError(f"read past the reply ({at + 32} > {len(raw)} bytes)")
    return int.from_bytes(raw[at:at + 32], "big")


def _addr(word: int) -> str:
    if word >= 2**160:
        raise CensusError(f"word {word:#x} is not an address")
    return "0x" + word.to_bytes(20, "big").hex()


def decode_assets(ret_hex: str) -> list[str]:
    """`Asset[]` = tuple(address asset, string symbol, uint8 decimals)[]; a dynamic tuple array, so the head is one
    offset per element (relative to the start of the element area); each element starts with its address."""
    raw = _raw(ret_hex)
    off = _word(raw, 0)
    n = _word(raw, off)
    base = off + 32
    if n > 100_000:
        raise CensusError(f"implausible Asset[] length {n}")
    return [_addr(_word(raw, base + _word(raw, base + 32 * i))) for i in range(n)]


def decode_feed_configs(ret_hex: str) -> list[dict]:
    """`PriceFeedConfig[]` = (address priceFeed, uint8 decimals, PriceType priceType, uint256 chainlinkHeartbeat)[]:
    static tuples of four words."""
    raw = _raw(ret_hex)
    off = _word(raw, 0)
    n = _word(raw, off)
    base = off + 32
    if len(raw) < base + 128 * n:
        raise CensusError(f"truncated PriceFeedConfig[] ({n} elements, {len(raw)} bytes)")
    out = []
    for i in range(n):
        e = base + 128 * i
        out.append({"feed": _addr(_word(raw, e)), "type": _word(raw, e + 64), "heartbeat": _word(raw, e + 96)})
    return out


def _arg(addr: str) -> str:
    return addr[2:].lower().rjust(64, "0")


# ---------------------------------------------------------------------------
# Reading the chain (injectable, so the verdicts are testable offline)
# ---------------------------------------------------------------------------

class LiveReader:
    def __init__(self, url: str):
        self._url = url

    def call(self, to: str, data: str) -> str:
        return c.eth_call(self._url, to, data)

    def storage(self, addr: str, slot: str) -> str:
        return c.rpc(self._url, "eth_getStorageAt", [addr, slot, "latest"])

    def chain_id(self) -> int:
        return int(c.rpc(self._url, "eth_chainId", []), 16)


def chain_mismatch(reader, chain: int) -> str | None:
    """None when the endpoint serves `chain`, else why not. A census run against the wrong chain's endpoint would
    read another NAV and could report 0 ERRORs for a chain it never looked at."""
    try:
        got = reader.chain_id()
    except Exception as e:  # noqa: BLE001 - an unreadable chain id is a refusal, not a pass
        return f"eth_chainId unreadable ({_safe(e, 120)})"
    return None if got == chain else f"endpoint serves chain {got}, not {chain}"


def _optional_address(reader, to: str, sel: str) -> str | None:
    """An address getter that may legitimately not exist (a feed with no NAV()). None on a revert or a non-address."""
    try:
        raw = _raw(reader.call(to, sel))
        return _addr(_word(raw, 0)) if len(raw) == 32 else None
    except Exception:  # noqa: BLE001 - absence is the expected answer for most feeds
        return None


# ---------------------------------------------------------------------------
# The census
# ---------------------------------------------------------------------------

def record_addresses(record: dict) -> set[str]:
    feeds = record.get("customPriceFeeds") or {}
    return {v.lower() for k, v in feeds.items() if not k.startswith("$") and isinstance(v, str) and c.is_address(v)}


def all_record_addresses(record: dict) -> set[str]:
    """Every address anywhere in a record, so an OLD feed is recognised under any key or section."""
    out: set[str] = set()

    def walk(v):
        if isinstance(v, dict):
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
        elif isinstance(v, str) and c.is_address(v):
            out.add(v.lower())

    walk(record)
    return out


def census(chain: int, reader, new_feeds: set[str] | None, old_addresses: set[str] | None,
           proxy: str = NAV_PROXY) -> tuple[list[tuple[str, str]], dict]:
    """Returns (findings, summary). `new_feeds is None` = live-only mode (no Rule 1 against a record)."""
    out: list[tuple[str, str]] = []
    proxy = proxy.lower()
    summary: dict = {"chain": chain, "assets": 0, "custom": [], "impl": None, "sequencerFeed": None}

    try:
        summary["impl"] = _addr(int(reader.storage(proxy, IMPL_SLOT), 16))
    except Exception as e:  # noqa: BLE001 - context only
        out.append((WARN, f"chain {chain}: implementation slot unreadable ({_safe(e, 120)})"))
    seq = _optional_address(reader, proxy, SEL_SEQUENCER_FEED)
    summary["sequencerFeed"] = seq if seq and int(seq, 16) else None

    try:
        assets = decode_assets(reader.call(proxy, SEL_GET_REGISTERED_ASSETS))
    except Exception as e:  # noqa: BLE001 - unchecked must not pass
        out.append((ERROR, f"chain {chain}: getRegisteredAssets() unreadable, so NOTHING was checked: {_safe(e)}"))
        return out, summary
    summary["assets"] = len(assets)

    for asset in assets:
        for kind, sel in (("primary", SEL_GET_PRICE_FEEDS), ("monitor", SEL_GET_MONITOR_FEEDS)):
            try:
                cfgs = decode_feed_configs(reader.call(proxy, sel + _arg(asset)))
            except Exception as e:  # noqa: BLE001
                out.append((ERROR, f"chain {chain}: asset {asset} {kind} feeds unreadable, NOT checked: "
                                   f"{_safe(e)}"))
                continue
            for i, f in enumerate(cfgs):
                where = f"asset {asset} {kind}[{i}] {f['feed']}"
                # Rule 2: primaries only (a monitor's heartbeat never zeroes a price).
                if kind == "primary" and f["heartbeat"] != UINT256_MAX and f["heartbeat"] >= MAX_STALE_PRICE_AGE:
                    out.append((ERROR, f"chain {chain}: RULE 2 {where}: stored heartbeat {f['heartbeat']} s is "
                                       f">= {MAX_STALE_PRICE_AGE} s; realign it below 7 days before the upgrade."))
                if f["type"] != CUSTOM:
                    continue
                reads_nav = (_optional_address(reader, f["feed"], SEL_NAV) or "") == proxy
                summary["custom"].append({"asset": asset, "kind": kind, "feed": f["feed"], "readsNav": reads_nav})
                hazard = " (reads the NAV: carries the sequencer hazard)" if reads_nav else ""
                if new_feeds is None:
                    out.append((WARN, f"chain {chain}: RULE 1 (live-only) {where}{hazard}: confirm by hand what it "
                                      f"returns when its input is stale."))
                    continue
                if f["feed"] in (old_addresses or set()):
                    out.append((ERROR, f"chain {chain}: RULE 1 {where} is a PRE-ROLLOUT feed (in the base record)"
                                       f"{hazard}. Swap it before the upgrade."))
                elif f["feed"] not in new_feeds:
                    out.append((ERROR, f"chain {chain}: RULE 1 {where} is not in this tree's customPriceFeeds "
                                       f"record{hazard}. Unknown feed: find what registered it before upgrading."))
    return out, summary


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def base_record(chain: int, base: str) -> dict:
    """The deployment record at git revision `base` ({} if the chain had none)."""
    rel = f"script/config/deployments/{chain}.json"
    try:
        txt = subprocess.run(["git", "-C", str(c.REPO), "show", f"{base}:{rel}"], check=True,
                             capture_output=True, text=True).stdout
    except subprocess.CalledProcessError as e:
        if "does not exist" in (e.stderr or "") or "exists on disk, but not in" in (e.stderr or ""):
            return {}
        raise CensusError(f"cannot read {rel} at {base}: {(e.stderr or '').strip()[:200]}")
    return json.loads(txt)


def _load_env_file(path: Path) -> None:
    """KEY=VALUE lines into os.environ (existing values win). Values are never printed."""
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip().removeprefix("export ").strip()
        os.environ.setdefault(k, v.strip().strip('"').strip("'"))


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--chain", type=int, action="append", help="chain id (repeatable); default: every record")
    ap.add_argument("--base", default="origin/main", help="git revision holding the PRE-ROLLOUT records")
    ap.add_argument("--live-only", action="store_true", help="no record to compare against (Robinhood 4663)")
    ap.add_argument("--rpc-env", help="name of the env var holding the RPC URL (default: the chain's resolver)")
    ap.add_argument("--env-file", type=Path, help="extra KEY=VALUE file to load (values are never printed)")
    ap.add_argument("--json", action="store_true", help="print the per-chain summaries as JSON at the end")
    a = ap.parse_args(argv)

    c.load_env()
    if a.env_file:
        _load_env_file(a.env_file)
    chains = a.chain or c.deployed_chain_ids()
    total = 0
    summaries = []
    for chain in chains:
        if a.rpc_env:
            url, note = os.environ.get(a.rpc_env) or None, f"env {a.rpc_env}"
        else:
            url, note, _ = c.probe_rpc(chain)
        if not url:
            print(f"=== chain {chain}: 1 ERROR (no RPC: {note}) ===")
            print(f"  ERROR: chain {chain} NOT checked - no working endpoint ({note}).")
            total += 1
            continue
        reader = LiveReader(url)
        why = chain_mismatch(reader, chain)
        if why:
            print(f"=== chain {chain}: 1 ERROR (wrong endpoint: {why}) ===")
            print(f"  ERROR: chain {chain} NOT checked - {why} [rpc: {note.split(' (')[0]}].")
            total += 1
            continue
        if a.live_only:
            new_feeds = old = None
        else:
            new_feeds = record_addresses(c.deployment(chain))
            old = all_record_addresses(base_record(chain, a.base))
        f, s = census(chain, reader, new_feeds, old)
        errs = [m for lvl, m in f if lvl == ERROR]
        total += len(errs)
        seq = s["sequencerFeed"] or "none"
        print(f"=== chain {chain}: {len(errs)} ERROR, {len(f) - len(errs)} WARN | assets {s['assets']}, custom "
              f"{len(s['custom'])} (NAV-sourced {sum(x['readsNav'] for x in s['custom'])}), impl {s['impl']}, "
              f"sequencer feed {seq} [rpc: {note.split(' (')[0]}] ===")
        for lvl, m in f:
            print(f"  {lvl}: {m}")
        summaries.append(s)
    print(f"total ERRORs: {total}")
    if a.json:
        print(json.dumps(summaries, indent=1))
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
