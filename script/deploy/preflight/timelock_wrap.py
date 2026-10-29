#!/usr/bin/env python3
"""Turn a NAV batch into the two Safe files the NAV timelock needs: the Council's `scheduleBatch`, and the
`executeBatch` anyone sends once the delay has passed.

WHY THIS EXISTS
---------------
After the ADR 0029 handover the Security Council holds no role on the NAV: the `TimelockController` holds
DEFAULT_ADMIN_ROLE and MANAGER, with a 3-day delay, and the Council is its only proposer (`ADR0029_ROLLOUT.md`,
"Timelock handover"). Every batch tool in this folder (`MigrateToMonitorFeeds`, `RegisterAssets`, `adr0029_batch.py`,
`ops_safe.py`, ...) writes DIRECT calls to the NAV, which now revert for the Council. This wraps such a batch, call
for call and byte for byte, into one timelock operation:

  wrap      <batch> → <schedule file> (Council → timelock.scheduleBatch) + <execute file> (anyone →
            timelock.executeBatch after the delay). Both name the same operation; its id is printed and recorded.
  rehearse  on a LOCAL fork: run the schedule file through the real Council Safe, check the operation is pending and
            not ready, warp past its ready time, execute from a random account, check it is done, then run an
            optional post-check.

Plan the wrapped batch AS THE TIMELOCK: inside the operation every call's `msg.sender` is the timelock, so a forge
planning script must run with `--sender <TimelockController>` (the Council no longer passes the role checks).

usage:
  timelock_wrap.py wrap --chain 1 --in safe-transactions/1-migrate-monitor-feeds.json --label "feed switch: X" \\
                        --out-schedule safe-transactions/1-tl-schedule.json --out-execute safe-transactions/1-tl-execute.json \\
                        [--rpc-env MAINNET_URL] [--delay 259200] [--predecessor 0x…]
  timelock_wrap.py rehearse --chain 1 --rpc-url http://127.0.0.1:8546 --schedule <file> --execute <file> \\
                        [--post-check "<command>"]

`wrap` refuses value, DELEGATECALL, an empty or unstamped batch (or one whose transactions no longer match its
checksum), a batch made for another chain, and a delay below 259200 s. With `--rpc-env` it also reads the live
timelock and refuses if the delay is below its `getMinDelay()`, the Council is not a proposer, or the operation
already exists. `--rpc-url` is accepted only for a loopback (fork) endpoint; a real endpoint is read from the
environment and never printed. The salt is keccak256(label); the operation id also covers the calls, so reusing a
label only blocks re-scheduling the SAME batch — use a fresh, descriptive label per change.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

import adr0029_batch as b
import chainlib as c

SEL_SCHEDULE_BATCH = "0x8f2a0bb0"  # scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)
SEL_EXECUTE_BATCH = "0xe38335e5"  # executeBatch(address[],uint256[],bytes[],bytes32,bytes32)
SEL_IS_OPERATION = "0x31d50750"  # isOperation(bytes32)
SEL_GET_MIN_DELAY = b.SEL_TL_GET_MIN_DELAY
ZERO32 = "0x" + "00" * 32
ERR_UNEXPECTED_STATE = "0x5ead8eb5"  # TimelockUnexpectedOperationState(bytes32,bytes32)
EXECUTOR = "0x00000000000000000000000000000000000e7ec0"  # an unrelated account: the timelock's EXECUTOR is open


class WrapError(Exception):
    pass


# --- ABI encoding (hand-rolled like adr0029_batch.py, so the offline tests need neither Foundry nor eth_abi;
#     cross-checked against `cast calldata` in test_timelock_wrap.py wherever cast is installed) ----------------

def _word(n: int) -> str:
    return f"{n:064x}"


def _b32(h: str) -> str:
    raw = h[2:] if h.startswith("0x") else h
    if len(raw) != 64 or any(ch not in "0123456789abcdefABCDEF" for ch in raw):
        raise WrapError(f"not a bytes32: {h!r}")
    return raw.lower()


def _bytes_elem(data_hex: str) -> str:
    raw = data_hex[2:]
    return _word(len(raw) // 2) + raw.lower() + "0" * ((-len(raw)) % 64)


def _batch_args(targets: list[str], values: list[int], payloads: list[str], predecessor: str, salt: str,
                delay: int | None) -> str:
    """ABI body of (address[], uint256[], bytes[], bytes32, bytes32[, uint256]) — no selector."""
    head_words = 6 if delay is not None else 5
    t = _word(len(targets)) + "".join(b._word_addr(a) for a in targets)
    v = _word(len(values)) + "".join(_word(x) for x in values)
    elems = [_bytes_elem(p) for p in payloads]
    offs, pos = [], 32 * len(elems)
    for e in elems:
        offs.append(_word(pos))
        pos += len(e) // 2
    p = _word(len(payloads)) + "".join(offs) + "".join(elems)
    off_t = 32 * head_words
    off_v = off_t + len(t) // 2
    off_p = off_v + len(v) // 2
    head = _word(off_t) + _word(off_v) + _word(off_p) + _b32(predecessor) + _b32(salt)
    if delay is not None:
        head += _word(delay)
    return head + t + v + p


def enc_schedule_batch(targets, values, payloads, predecessor, salt, delay) -> str:
    return SEL_SCHEDULE_BATCH + _batch_args(targets, values, payloads, predecessor, salt, delay)


def enc_execute_batch(targets, values, payloads, predecessor, salt) -> str:
    return SEL_EXECUTE_BATCH + _batch_args(targets, values, payloads, predecessor, salt, None)


def operation_id(targets, values, payloads, predecessor, salt) -> str:
    """OZ TimelockController.hashOperationBatch = keccak256(abi.encode(targets, values, payloads, predecessor, salt)),
    which is exactly the ABI body of executeBatch's arguments."""
    from eth_utils import keccak
    return "0x" + keccak(bytes.fromhex(_batch_args(targets, values, payloads, predecessor, salt, None))).hex()


def label_salt(label: str) -> str:
    from eth_utils import keccak
    if not label.strip():
        raise WrapError("empty --label: the salt is keccak256(label) and names the operation")
    return "0x" + keccak(text=label).hex()


# --- input -------------------------------------------------------------------------------------------------

def load_inner(path: str, chain: int) -> tuple[list[dict], str]:
    """The stamped batch's transactions, refused unless they still match their checksum and are plain calls."""
    raw = Path(path).read_bytes()
    doc = json.loads(raw)
    if str(doc.get("chainId")) != str(chain):
        raise WrapError(f"{path}: made for chain {doc.get('chainId')}, not {chain}")
    txs = doc.get("transactions") or []
    if not txs:
        raise WrapError(f"{path}: no transactions")
    stamped = (doc.get("meta") or {}).get("checksum", "")
    if not stamped:
        raise WrapError(f"{path}: no meta.checksum — refusing an unstamped batch")
    for t in txs:
        if t.get("data") in (None, "", "0x") or not str(t["data"]).startswith("0x"):
            raise WrapError(f"{path}: an entry to {t.get('to')} has no calldata (method-form files: build the "
                            "batch with the repo tools, which write raw calldata)")
        if int(str(t.get("value", "0") or "0"), 0) != 0:
            raise WrapError(f"{path}: an entry to {t.get('to')} sends value — refused")
        if int(t.get("operation", 0) or 0) != 0:
            raise WrapError(f"{path}: an entry to {t.get('to')} is a DELEGATECALL — refused")
        if not c.is_address(t.get("to", "")):
            raise WrapError(f"{path}: bad target {t.get('to')!r}")
        try:
            bytes.fromhex(str(t["data"])[2:])
        except ValueError:
            raise WrapError(f"{path}: an entry to {t.get('to')} has malformed calldata") from None
    if stamped.lower() != b.checksum([dict(t) for t in txs]).lower():
        raise WrapError(f"{path}: transactions do not match meta.checksum — edited after it was stamped; refusing")
    return txs, hashlib.sha256(raw).hexdigest()


def _timelock(chain: int) -> str:
    tl = c.deployment(chain).get("TimelockController") or ""
    if not c.is_address(tl):
        raise WrapError(f"chain {chain}: no TimelockController in script/config/deployments/{chain}.json")
    return tl


# --- wrap --------------------------------------------------------------------------------------------------

def wrap(chain: int, in_path: str, label: str, delay: int, predecessor: str, reader=None) -> tuple[dict, dict, dict]:
    """(schedule batch, execute batch, summary). `reader` (adr0029_census.LiveReader-like, `.call(to, data)`) adds the
    live checks; None = offline."""
    if delay < b.TIMELOCK_DELAY_S:
        raise WrapError(f"delay {delay} s is below the NAV timelock's {b.TIMELOCK_DELAY_S} s — refusing")
    txs, src_sha = load_inner(in_path, chain)
    tl, council = _timelock(chain), b._council(chain)
    targets = [t["to"] for t in txs]
    values = [0] * len(txs)
    payloads = [t["data"] for t in txs]
    salt = label_salt(label)
    _b32(predecessor)
    op = operation_id(targets, values, payloads, predecessor, salt)
    if reader is not None:
        raw = reader.call(tl, SEL_GET_MIN_DELAY)
        if not raw or len(raw) < 66:
            raise WrapError(f"getMinDelay on {tl} returned {raw!r} — no timelock there?")
        if delay < int(raw, 16):
            raise WrapError(f"delay {delay} s is below the live timelock minimum {int(raw, 16)} s")
        if not b._has_role(reader, tl, b.ROLE_TL_PROPOSER, council):
            raise WrapError(f"the Council {council} is not a proposer on {tl} — refusing")
        exists = reader.call(tl, SEL_IS_OPERATION + _b32(op))
        if not exists or len(exists) < 66:
            raise WrapError(f"isOperation on {tl} returned {exists!r}")
        if int(exists, 16) == 1:
            raise WrapError(f"operation {op} already exists on {tl} (same batch and label scheduled before?)")
        if predecessor.lower() != ZERO32:
            pre = reader.call(tl, SEL_IS_OPERATION + _b32(predecessor))
            if not pre or len(pre) < 66 or int(pre, 16) != 1:
                raise WrapError(f"predecessor {predecessor} is not an operation on {tl}: executeBatch could never "
                                "succeed — refusing")
        if not b._has_role(reader, tl, b.ROLE_TL_EXECUTOR, "0x" + "00" * 20):
            raise WrapError(f"execution on {tl} is not open to any account (EXECUTOR_ROLE not granted to "
                            "address(0)) — the execute file's 'any account' would be false; refusing")
    desc = (f"NAV timelock operation {op}: {len(txs)} call(s) from {Path(in_path).name} (sha256 {src_sha}); "
            f"label {label!r} (salt {salt}); predecessor {predecessor}; delay {delay} s")
    schedule = {"to": tl, "value": "0", "operation": 0,
                "data": enc_schedule_batch(targets, values, payloads, predecessor, salt, delay)}
    execute = {"to": tl, "value": "0", "operation": 0,
               "data": enc_execute_batch(targets, values, payloads, predecessor, salt)}
    summary = {"chain": chain, "timelock": tl, "council": council, "operation": op, "salt": salt, "label": label,
               "predecessor": predecessor, "delay": delay, "calls": len(txs), "source": in_path,
               "sourceSha256": src_sha}
    return ({"desc": "SCHEDULE (Security Council signs) — " + desc, "tx": schedule},
            {"desc": f"EXECUTE (any account, once {delay} s have passed after the schedule executed) — " + desc,
             "tx": execute}, summary)


def cmd_wrap(a) -> int:
    reader = None
    if a.rpc_env or a.rpc_url:
        reader = b._reader(a)
    sched, exe, s = wrap(a.chain, a.input, a.label, a.delay, a.predecessor, reader)
    b.write_batch(a.out_schedule, a.chain, s["council"], "NAV timelock: schedule", sched["desc"], [sched["tx"]])
    b.write_batch(a.out_execute, a.chain, s["council"], "NAV timelock: execute", exe["desc"], [exe["tx"]])
    print(f"chain {a.chain}: {s['calls']} call(s) -> timelock operation {s['operation']} (delay {s['delay']} s, "
          f"label {s['label']!r}){'' if reader else ' [offline: live checks skipped]'}")
    print(f"  schedule: {a.out_schedule}  (Security Council {s['council']})")
    print(f"  execute:  {a.out_execute}  (any account, after the delay)")
    return 0


# --- rehearse (fork only) ----------------------------------------------------------------------------------

def _cast(rpc: str, *args: str) -> str:
    r = subprocess.run(["cast", *args, "--rpc-url", rpc], capture_output=True, text=True)
    if r.returncode:
        raise WrapError(f"cast {args[0]}: {(r.stderr or r.stdout).strip()[:300]}")
    return r.stdout.strip()


def _one_call(path: str, timelock: str, selector: str) -> str:
    doc = json.loads(Path(path).read_text())
    txs = doc.get("transactions") or []
    if len(txs) != 1 or txs[0]["to"].lower() != timelock.lower() or not str(txs[0].get("data", "")).startswith(selector):
        raise WrapError(f"{path}: expected exactly one {selector} call to the timelock {timelock}")
    if int(str(txs[0].get("value", "0") or "0"), 0) or int(txs[0].get("operation", 0) or 0):
        raise WrapError(f"{path}: sends value or is a DELEGATECALL")
    return txs[0]["data"]


def rehearse(chain: int, rpc: str, schedule_path: str, execute_path: str, post_check: str | None) -> dict:
    import council_fork_exec as fx
    fx._loopback(rpc)
    if int(_cast(rpc, "chain-id")) != chain:
        raise WrapError(f"the fork at {rpc} is not chain {chain}")
    tl, council = _timelock(chain), b._council(chain)
    sched_data = _one_call(schedule_path, tl, SEL_SCHEDULE_BATCH)
    exec_data = _one_call(execute_path, tl, SEL_EXECUTE_BATCH)
    # The two files must name the SAME operation: decode both and compare the timelock's own operation ids.
    from eth_abi import decode
    arr = ["address[]", "uint256[]", "bytes[]", "bytes32", "bytes32"]
    sa = decode(arr + ["uint256"], bytes.fromhex(sched_data[10:]))
    ea = decode(arr, bytes.fromhex(exec_data[10:]))
    ids = []
    for t, v, p, pred, salt in (sa[:5], ea):
        ids.append(_cast(rpc, "call", tl, "hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32)(bytes32)",
                         "[" + ",".join(t) + "]", "[" + ",".join(str(x) for x in v) + "]",
                         "[" + ",".join("0x" + x.hex() for x in p) + "]", "0x" + pred.hex(), "0x" + salt.hex()))
    if ids[0] != ids[1]:
        raise WrapError("the execute file does not name the scheduled operation")
    op = ids[0]
    r = fx.run(rpc, council, schedule_path, council)
    st = lambda f: _cast(rpc, "call", tl, f"{f}(bytes32)(bool)", op)  # noqa: E731
    if st("isOperationPending") != "true" or st("isOperationReady") != "false":
        raise WrapError(f"after the schedule, operation {op} is not pending-and-not-ready")
    early = subprocess.run(["cast", "call", tl, exec_data, "--from", EXECUTOR, "--rpc-url", rpc],
                           capture_output=True, text=True)
    # Must be the timelock's own refusal (TimelockUnexpectedOperationState), not any cast failure.
    if early.returncode == 0 or ERR_UNEXPECTED_STATE not in (early.stderr + early.stdout):
        raise WrapError("executeBatch before the delay did not revert with TimelockUnexpectedOperationState "
                        f"(rc {early.returncode}) — the timelock is not enforcing the delay, or the call is malformed")
    ready_at = int(_cast(rpc, "call", tl, "getTimestamp(bytes32)(uint256)", op).split()[0])
    _cast(rpc, "rpc", "anvil_removeBlockTimestampInterval")
    _cast(rpc, "rpc", "evm_setNextBlockTimestamp", hex(ready_at + 1))
    _cast(rpc, "rpc", "evm_mine")
    _cast(rpc, "rpc", "anvil_setBalance", EXECUTOR, "0xde0b6b3a7640000")
    _cast(rpc, "rpc", "anvil_impersonateAccount", EXECUTOR)
    rcpt = json.loads(_cast(rpc, "send", tl, exec_data, "--from", EXECUTOR, "--unlocked", "--json"))
    if rcpt.get("status") not in ("0x1", 1) or st("isOperationDone") != "true":
        raise WrapError(f"executeBatch did not complete operation {op}")
    out = {"operation": op, "scheduleGas": r["gasUsed"], "executeGas": int(str(rcpt["gasUsed"]), 0),
           "executedAfter": ready_at + 1, "postCheck": None}
    if post_check:
        env = dict(os.environ, ADR0029_FORK_RPC=rpc, TIMELOCK_WRAP_CHAIN=str(chain), TIMELOCK_WRAP_OPERATION=op)
        pc = subprocess.run(["bash", "-c", post_check], env=env)
        out["postCheck"] = pc.returncode
        if pc.returncode:
            raise WrapError(f"post-check failed (exit {pc.returncode})")
    return out


def cmd_rehearse(a) -> int:
    r = rehearse(a.chain, a.rpc_url, a.schedule, a.execute, a.post_check)
    print(f"REHEARSAL PASS chain {a.chain}: operation {r['operation']} scheduled by the Council "
          f"(gas {r['scheduleGas']}), refused before the delay, executed by an unrelated account after it "
          f"(gas {r['executeGas']}), done{'; post-check passed' if r['postCheck'] == 0 else ''}")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("wrap")
    w.add_argument("--chain", type=int, required=True)
    w.add_argument("--in", dest="input", required=True)
    w.add_argument("--label", required=True)
    w.add_argument("--delay", type=int, default=b.TIMELOCK_DELAY_S)
    w.add_argument("--predecessor", default=ZERO32)
    w.add_argument("--out-schedule", required=True)
    w.add_argument("--out-execute", required=True)
    w.add_argument("--rpc-env", default=None)
    w.add_argument("--rpc-url", default=None)
    w.set_defaults(fn=cmd_wrap)
    r = sub.add_parser("rehearse")
    r.add_argument("--chain", type=int, required=True)
    r.add_argument("--rpc-url", required=True)
    r.add_argument("--schedule", required=True)
    r.add_argument("--execute", required=True)
    r.add_argument("--post-check", default=None)
    r.set_defaults(fn=cmd_rehearse)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (WrapError, b.BatchError, c.RpcError, ValueError) as e:
        print(f"REFUSED: {e}")
        sys.exit(2)
    except Exception as e:  # the fork executor's own errors (CouncilForkError, OpsSafeError): same exit, no traceback
        if type(e).__name__ not in ("CouncilForkError", "OpsSafeError"):
            raise
        print(f"REFUSED: {e}")
        sys.exit(2)
