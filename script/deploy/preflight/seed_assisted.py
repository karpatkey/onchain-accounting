#!/usr/bin/env python3
"""Build the `submitForBatch` calldata that seeds the NEW assisted adapters (ADR 0030) before the NAV swap.

READ-ONLY: it reads logs and eth_calls, writes a JSON plan, and never sends a transaction. The keeper holding
`SUBMITTER_ROLE` sends the chunks later (`cast send <to> <data>` per chunk).

Two sources of coordinates, per member:
  1. MIGRATE — everything the OLD adapter caches today. Accounts come from its `CoordSubmitted` logs, coordinates from
     its live `coordsOf(account)`. These were submitted by the account itself (msg.sender-keyed), so they are trusted.
  2. DISCOVER — positions the allow-listed accounts (`--accounts`, the client Safes) hold but never fed through an
     assistant: ether.fi `WithdrawRequestNFT` and Nexus `StakingNFT` mints to the account, StakeWise
     `ExitQueueEntered` with the account as receiver (in the `--stakewise-vaults` given) plus the remainder ticket a
     partial claim re-queues (`ExitedAssetsClaimed`, same entry timestamp).

ADR 0030 S13 (anyone can create a position OWNED by a victim): a discovered position is kept only if the creating
event (the NFT mint / `ExitQueueEntered`) was emitted INSIDE a call frame the account itself made — checked on the
transaction's call trace (`debug_traceTransaction`, `callTracer` with logs). That holds for a Safe's own transaction, a
Zodiac Roles module execution (the production path, where `tx.to` is the Roles modifier) and the delegatecall assistant
alike, and it rejects a third party that bundles an unrelated Safe execution with its own deposit naming the Safe. A
position someone else created in the account's name is skipped and reported. No trace support on the RPC = abort.

Every surviving coordinate is then checked with an `eth_call` of the new adapter's `previewPositions(account,
[coord])`, which runs the same ownership validation as `submitFor` and reverts on a bad coordinate; failures are
reported, not seeded.

usage: seed_assisted.py --chain 1 --member etherfi --old 0x… --new 0x… --accounts safes.txt [--from-block N]
                        [--stakewise-vaults 0xV1,0xV2] [--chunk 50] --out plan.json
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

import requests

import chainlib as c

SEL_SUBMIT_FOR_BATCH = "b74e4c50"  # submitForBatch(address[],bytes[])
SEL_COORDS_OF = "197c3a51"  # coordsOf(address)
SEL_PREVIEW = "9461d46c"  # previewPositions(address,bytes)
TOPIC_COORD_SUBMITTED = "0x7728999634b195c39bbd63fdaab812fa23cdf37de6bbc1e06a1dedddd04cd01e"
TOPIC_TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
TOPIC_EXIT_ENTERED = "0x211091c5bf013c1230f996c3bb2bc327e3de429a3d3c356dcea9a0c858bc407f"
TOPIC_EXITED_CLAIMED = "0xeb3b05c070c24f667611fdb3ff75fe007d42401c573aed8d8faca95fd00ccb56"

# Protocol contracts the discovery reads (chain 1; StakeWise vaults are passed explicitly).
ETHERFI_WITHDRAW_REQUEST_NFT = {1: "0x7d5706f6ef3f89b3951e23e557cdfbc3239d4e2c"}
NEXUS_STAKING_NFT = {1: "0xcafea508a477d94c502c253a58239fb8f948e97f"}


class SeedError(Exception):
    pass


# ---- ABI encoding (hand-rolled: CI's preflight job installs only `requests`) ----

def _word(n: int) -> str:
    return format(n, "064x")


def _addr_word(a: str) -> str:
    if not c.is_address(a):
        raise SeedError(f"not an address: {a!r}")
    return "0" * 24 + a[2:].lower()


def _bytes_tail(b: bytes) -> str:
    padded = b.hex() + "0" * ((-len(b) % 32) * 2)
    return _word(len(b)) + padded


def encode_bytes_array(items: list[bytes]) -> str:
    """ABI-encode a `bytes[]` (length + offsets + tails), without a leading head offset."""
    tails = [_bytes_tail(x) for x in items]
    offsets, pos = [], 32 * len(items)
    for t in tails:
        offsets.append(_word(pos))
        pos += len(t) // 2
    return _word(len(items)) + "".join(offsets) + "".join(tails)


def encode_submit_for_batch(accounts: list[str], coords: list[bytes]) -> str:
    if len(accounts) != len(coords):
        raise SeedError("accounts/coords length mismatch")
    a = _word(len(accounts)) + "".join(_addr_word(x) for x in accounts)
    b = encode_bytes_array(coords)
    head = _word(64) + _word(64 + len(a) // 2)
    return "0x" + SEL_SUBMIT_FOR_BATCH + head + a + b


def encode_preview(account: str, coords: list[bytes]) -> str:
    payload = bytes.fromhex(_word(32) + encode_bytes_array(coords))  # abi.encode(bytes[])
    return "0x" + SEL_PREVIEW + _addr_word(account) + _word(64) + _bytes_tail(payload)


def decode_bytes_array(ret_hex: str) -> list[bytes]:
    """Decode a `bytes[]` return value (`coordsOf`)."""
    d = bytes.fromhex(ret_hex[2:] if ret_hex.startswith("0x") else ret_hex)
    if len(d) < 64 or int.from_bytes(d[0:32], "big") != 32:
        raise SeedError("malformed bytes[] return")
    base = 32
    n = int.from_bytes(d[base:base + 32], "big")
    out = []
    for i in range(n):
        off = int.from_bytes(d[base + 32 + 32 * i: base + 64 + 32 * i], "big")
        start = base + 32 + off
        ln = int.from_bytes(d[start:start + 32], "big")
        out.append(d[start + 32:start + 32 + ln])
    return out


# ---- Coordinates per member ----

def coord_token(token_id: int) -> bytes:
    return bytes.fromhex(_word(token_id))


def coord_stakewise(vault: str, ticket: int, ts: int) -> bytes:
    return bytes.fromhex(_addr_word(vault) + _word(ticket) + _word(ts))


# ---- Chain reads ----

def etherscan_logs(chain: int, address: str, topics: dict[str, str], from_block: int) -> list[dict]:
    key = os.environ.get("ETHERSCAN_API_KEY", "")
    if not key:
        raise SeedError("ETHERSCAN_API_KEY not set")
    out, page = [], 1
    while True:
        params = {"chainid": chain, "module": "logs", "action": "getLogs", "address": address,
                  "fromBlock": from_block, "toBlock": "latest", "page": page, "offset": 1000, "apikey": key}
        params.update(topics)
        r = requests.get("https://api.etherscan.io/v2/api", params=params, timeout=60).json()
        res = r.get("result")
        if not isinstance(res, list):
            if "No records" in str(r.get("message", "")) or res == []:
                break
            raise SeedError(f"getLogs failed: {r.get('message')} {str(res)[:120]}")
        out += res
        if len(res) < 1000:
            break
        page += 1
        time.sleep(0.25)
    return out


def _hex(x: str) -> int:
    """Etherscan returns `"0x"` for a zero `logIndex` / `transactionIndex`."""
    return 0 if x in ("0x", "") else int(x, 16)


def _log_key(lg: dict) -> tuple:
    return (lg.get("address", "").lower(), tuple(x.lower() for x in (lg.get("topics") or [])),
            (lg.get("data") or "0x").lower())


# Safe entry points that execute a transaction the Safe itself authorised (owner signatures or an enabled module).
SAFE_EXEC_SELECTORS = ("0x6a761202", "0x468721a7", "0x5229073f")  # execTransaction / ...FromModule / ...ReturnData


def emitted_inside_account_frame(trace: dict, log: dict, account: str) -> bool:
    """True iff `log` was emitted inside a Safe execution of `account` (ADR 0030 S13): a frame calling `account` with
    `execTransaction` / `execTransactionFromModule(ReturnData)` and the log somewhere in its subtree.

    That covers the Safe's own transaction, a Zodiac Roles module execution and the delegatecall assistant (all run
    inside such a frame), and rejects a log a third party produced in the same transaction — including through the
    Safe's fallback handler, which is reached without an exec entry point. Raises if the trace does not contain the log
    at all (a tracer that ignored `withLog`, or a null trace): that must abort, not read as "not created"."""
    a, target = account.lower(), _log_key(log)

    def walk(frame: dict, inside: bool):
        # A real CALL only: DELEGATECALL / CALLCODE to the Safe run its code in the CALLER's context, not the Safe's.
        inside = inside or ((frame.get("type") or "").upper() == "CALL" and frame.get("to", "").lower() == a
                            and (frame.get("input") or "")[:10].lower() in SAFE_EXEC_SELECTORS)
        for lg in frame.get("logs") or []:
            if _log_key(lg) == target:
                return inside
        for child in frame.get("calls") or []:
            found = walk(child, inside)
            if found is not None:
                return found
        return None

    found = walk(trace or {}, False)
    if found is None:
        raise SeedError(f"creating log not found in the call trace of {log.get('transactionHash', '?')} "
                        "(tracer without withLog support?) — refusing to guess")
    return found


def topic_addr(a: str) -> str:
    return "0x" + _addr_word(a)


# ---- Plan ----

def created_by_account(url: str, log: dict, account: str, cache: dict[str, dict]) -> bool:
    h = log["transactionHash"]
    if h not in cache:
        try:
            cache[h] = c.rpc(url, "debug_traceTransaction", [h, {"tracer": "callTracer", "tracerConfig": {"withLog": True}}])
        except c.RpcError as e:
            raise SeedError(f"call trace unavailable for {h} (the S13 check needs debug_traceTransaction): {e}") from e
    return emitted_inside_account_frame(cache[h], log, account)


def discover(chain: int, member: str, url: str, accounts: list[str], from_block: int,
             vaults: list[str]) -> tuple[list[tuple[str, bytes]], list[str]]:
    found, skipped, txcache = [], [], {}
    for acct in accounts:
        if member in ("etherfi", "nexus"):
            nft = (ETHERFI_WITHDRAW_REQUEST_NFT if member == "etherfi" else NEXUS_STAKING_NFT).get(chain)
            if not nft:
                raise SeedError(f"no {member} NFT address for chain {chain}")
            logs = etherscan_logs(chain, nft, {"topic0": TOPIC_TRANSFER, "topic1": "0x" + "0" * 64,
                                               "topic2": topic_addr(acct), "topic0_1_opr": "and",
                                               "topic1_2_opr": "and", "topic0_2_opr": "and"}, from_block)
            for lg in logs:
                tid = int(lg["topics"][3], 16)
                if created_by_account(url, lg, acct, txcache):
                    found.append((acct, coord_token(tid)))
                else:
                    skipped.append(f"{acct} id {tid}: minted in a transaction the account did not execute")
        elif member == "stakewise":
            for v in vaults:
                entered = etherscan_logs(chain, v, {"topic0": TOPIC_EXIT_ENTERED, "topic2": topic_addr(acct),
                                                    "topic0_2_opr": "and"}, from_block)
                ts_of: dict[int, int] = {}
                for lg in entered:
                    data = lg["data"][2:]
                    ticket, ts = int(data[0:64], 16), _hex(lg["timeStamp"])
                    if created_by_account(url, lg, acct, txcache):
                        ts_of[ticket] = ts
                        found.append((acct, coord_stakewise(v, ticket, ts)))
                    else:
                        skipped.append(f"{acct} ticket {ticket}: queued in a transaction the account did not execute")
                claimed = etherscan_logs(chain, v, {"topic0": TOPIC_EXITED_CLAIMED, "topic1": topic_addr(acct),
                                                    "topic0_1_opr": "and"}, from_block)
                for lg in sorted(claimed, key=lambda x: (_hex(x["blockNumber"]), _hex(x["logIndex"]))):
                    data = lg["data"][2:]
                    prev, new = int(data[0:64], 16), int(data[64:128], 16)
                    if prev in ts_of and new != 0:  # the remainder keeps the entry timestamp
                        ts_of[new] = ts_of[prev]
                        found.append((acct, coord_stakewise(v, new, ts_of[prev])))
        else:
            raise SeedError(f"unknown member {member}")
    return found, skipped


def probe_coords_of(url: str, adapter: str, label: str) -> None:
    """Abort unless `adapter` answers `coordsOf(address)` with a `bytes[]` (i.e. it is an assisted adapter)."""
    try:
        ret = c.eth_call(url, adapter, "0x" + SEL_COORDS_OF + _addr_word("0x" + "00" * 19 + "01"))
    except c.RpcError as e:
        raise SeedError(f"{label} {adapter} does not serve coordsOf(address): {str(e)[:120]}") from e
    if not is_abi_array_reply(ret):
        raise SeedError(f"{label} {adapter} answered coordsOf with {str(ret)[:66]} — not an assisted adapter")


def cached_sets(url: str, adapter: str, accounts: set[str]) -> dict[str, set[bytes]]:
    """The coordinates each account ALREADY has in `adapter` (they count toward the keeper limit)."""
    return {a: set(decode_bytes_array(c.eth_call(url, adapter, "0x" + SEL_COORDS_OF + _addr_word(a))))
            for a in sorted(accounts)}


def migrate(chain: int, url: str, old: str, from_block: int) -> list[tuple[str, bytes]]:
    logs = etherscan_logs(chain, old, {"topic0": TOPIC_COORD_SUBMITTED}, from_block)
    accounts = sorted({"0x" + lg["topics"][1][-40:] for lg in logs})
    out = []
    for a in accounts:
        ret = c.eth_call(url, old, "0x" + SEL_COORDS_OF + _addr_word(a))
        out += [(a, x) for x in decode_bytes_array(ret)]
    return out


def is_abi_array_reply(ret: str) -> bool:
    """A dynamic-array return value: head offset 0x20 followed by a length word."""
    h = (ret or "")[2:] if (ret or "").startswith("0x") else (ret or "")
    return len(h) >= 128 and int(h[0:64], 16) == 32


def validate(url: str, new: str, pairs: list[tuple[str, bytes]]) -> tuple[list, list[str]]:
    """Keep what `previewPositions` accepts. Only an execution REVERT rejects a coordinate; any other RPC failure
    aborts the run, so an outage can never masquerade as "every coordinate is invalid"."""
    if pairs and c.get_code(url, new) in ("0x", "", None):
        raise SeedError(f"--new {new} has no code")
    if pairs:
        # Probe once that --new really serves previewPositions (an empty payload answers an empty array), so a wrong
        # target — e.g. the OLD adapter — aborts instead of "rejecting" every coordinate and exiting with nothing kept.
        try:
            probe = c.eth_call(url, new, "0x" + SEL_PREVIEW + _addr_word("0x" + "00" * 19 + "01") + _word(64) + _word(0))
        except c.RpcError as e:
            raise SeedError(f"--new {new} does not serve previewPositions(address,bytes): {str(e)[:120]}") from e
        if not is_abi_array_reply(probe):
            raise SeedError(f"--new {new} answered previewPositions with {str(probe)[:66]} — not an assisted adapter")
    ok, bad = [], []
    for acct, coord in pairs:
        try:
            ret = c.eth_call(url, new, encode_preview(acct, [coord]))
            if not is_abi_array_reply(ret):
                raise SeedError(f"previewPositions on {new} returned {str(ret)[:66]} — not an adapter reply")
            ok.append((acct, coord))
        except c.RpcError as e:
            if "revert" not in str(e).lower():
                raise SeedError(f"RPC failure while validating (not a revert): {str(e)[:160]}") from e
            bad.append(f"{acct} 0x{coord.hex()}: {str(e)[:160]}")
    return ok, bad


def dedupe(pairs: list[tuple[str, bytes]]) -> list[tuple[str, bytes]]:
    seen, out = set(), []
    for a, x in pairs:
        k = (a.lower(), x)
        if k not in seen:
            seen.add(k)
            out.append((a.lower(), x))
    return out


def over_headroom(pairs: list[tuple[str, bytes]], headroom: int,
                  existing: dict[str, set[bytes]] | None = None) -> dict[str, int]:
    """Accounts whose cache would exceed `headroom` entries after the plan: the UNION of what the NEW cache already
    holds and what the plan adds (a re-run re-plans cached coordinates; they must not count twice)."""
    total: dict[str, set[bytes]] = {a: set(s) for a, s in (existing or {}).items()}
    for a, x in pairs:
        total.setdefault(a, set()).add(x)
    return {a: len(s) for a, s in total.items() if len(s) > headroom}


def not_yet_cached(pairs: list[tuple[str, bytes]], existing: dict[str, set[bytes]]) -> list[tuple[str, bytes]]:
    """Drop coordinates the NEW cache already holds, so a re-run only sends what is missing."""
    return [(a, x) for a, x in pairs if x not in existing.get(a, set())]


def chunks(new: str, pairs: list[tuple[str, bytes]], size: int) -> list[dict]:
    if size < 1:
        raise SeedError("chunk size must be >= 1")
    out = []
    for i in range(0, len(pairs), size):
        part = pairs[i:i + size]
        out.append({"to": new, "count": len(part),
                    "data": encode_submit_for_batch([a for a, _ in part], [x for _, x in part])})
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--chain", type=int, required=True)
    ap.add_argument("--member", choices=["etherfi", "nexus", "stakewise"], required=True)
    ap.add_argument("--old", required=True, help="the live (old) adapter")
    ap.add_argument("--new", required=True, help="the new adapter to seed")
    ap.add_argument("--accounts", help="file with one allow-listed account per line (discovery)")
    ap.add_argument("--stakewise-vaults", default="", help="comma-separated vaults to scan (stakewise)")
    ap.add_argument("--from-block", type=int, default=0)
    ap.add_argument("--chunk", type=int, default=50)
    ap.add_argument("--allow-empty-migration", action="store_true",
                    help="accept an old adapter with nothing cached (otherwise migrated == 0 aborts)")
    ap.add_argument("--headroom", type=int, default=200,
                    help="flag accounts the plan would fill past this many entries (keeper limit 224 = cap 256 - "
                         "OWNER_RESERVE 32; ADR 0030 S13)")
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    for x in (a.old, a.new):
        if not c.is_address(x):
            raise SeedError(f"not an address: {x}")
    c.load_env()
    url, note = c.resolve_rpc(a.chain)
    if not url:
        raise SeedError(f"no RPC for chain {a.chain}: {note}")

    for label, addr in (("--old", a.old), ("--new", a.new)):
        if c.get_code(url, addr) in ("0x", "", None):
            raise SeedError(f"{label} {addr} has no code on chain {a.chain}")
    if a.old.lower() == a.new.lower():
        raise SeedError("--old and --new are the same address")
    probe_coords_of(url, a.old, "--old")
    probe_coords_of(url, a.new, "--new")
    migrated = migrate(a.chain, url, a.old, a.from_block)
    if not migrated and not a.allow_empty_migration:
        raise SeedError(f"--old {a.old} has nothing cached — wrong address? (pass --allow-empty-migration if expected)")
    discovered, skipped = [], []
    if a.accounts:
        accts = [ln.strip() for ln in open(a.accounts) if ln.strip() and not ln.strip().startswith("#")]
        for x in accts:
            if not c.is_address(x):
                raise SeedError(f"bad account in {a.accounts}: {x}")
        vaults = [v for v in a.stakewise_vaults.split(",") if v]
        discovered, skipped = discover(a.chain, a.member, url, accts, a.from_block, vaults)
    pairs = dedupe(migrated + discovered)
    ok, rejected = validate(url, a.new, pairs)
    existing = cached_sets(url, a.new, {x for x, _ in ok})
    to_send = not_yet_cached(ok, existing)
    plan = {"chain": a.chain, "member": a.member, "old": a.old, "new": a.new,
            "migrated": len(migrated), "discovered": len(discovered), "kept": len(ok),
            "skipped_not_created_by_account": skipped, "rejected_by_preview": rejected,
            "accounts_over_headroom": over_headroom(ok, a.headroom, existing),
            "already_cached": len(ok) - len(to_send), "to_send": len(to_send),
            "chunks": chunks(a.new, to_send, a.chunk)}
    json.dump(plan, open(a.out, "w"), indent=2)
    print(f"{a.member}: migrated {len(migrated)}, discovered {len(discovered)}, kept {len(ok)}, "
          f"skipped {len(skipped)}, rejected {len(rejected)}, already cached {plan['already_cached']} → "
          f"{plan['to_send']} to send in {len(plan['chunks'])} chunk(s), {a.out}")
    if plan["accounts_over_headroom"]:
        print(f"WARNING: over --headroom {a.headroom}: {plan['accounts_over_headroom']} — review before sending",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SeedError as e:
        print(f"seed_assisted: {e}", file=sys.stderr)
        sys.exit(1)
