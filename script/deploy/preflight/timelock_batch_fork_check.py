#!/usr/bin/env python3
"""Fork-only follow-through for a timelock `scheduleBatch` that rode in a Council batch (ADR0029_ROLLOUT.md,
"Another team's Council calls in the same transaction").

Both files must be stamped for the fork's chain (the Safe UI sends a file to the chain its `chainId` names).
Run as `rehearse_adr0029_fork.sh`'s POST_CHECK (it sets ADR0029_FORK_RPC). Asserts that the operation in the
`scheduleBatch` file is PENDING and not yet ready, that the `executeBatch` file names the same operation, warps past
the timelock's own `getMinDelay()`, executes from a random EOA (the BTC Carry timelock's EXECUTOR_ROLE is open), and
asserts the operation is DONE. Both files are Safe Transaction-Builder JSON in the UI's method form.

usage:
  POST_CHECK="python3 script/deploy/preflight/timelock_batch_fork_check.py --timelock 0xa490… \\
      --schedule <..._scheduleBatch_....json> --execute <..._executeBatch_....json>"
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
import sys

EXECUTOR = "0x00000000000000000000000000000000000b7c01"


class CheckError(Exception):
    pass


def _cast(rpc: str, *a: str) -> str:
    r = subprocess.run(["cast", *a, "--rpc-url", rpc], capture_output=True, text=True)
    if r.returncode:
        raise CheckError(f"cast {a[0]}: {r.stderr.strip()[:300]}")
    return r.stdout.strip()


def _batch_args(path: str, timelock: str, method: str, chain_id: int) -> tuple[str, str, str, str, str]:
    """The one call in a Transaction-Builder file, checked to be `method` on `timelock`: the rehearsal then sends
    exactly what the file would send, so a file aimed at another contract, function or chain cannot pass."""
    doc = json.load(open(path))
    # The Safe UI sends a file to the chain its `chainId` names, so a file stamped for another chain must not pass a
    # rehearsal on this fork even though its arguments are identical.
    if str(doc.get("chainId")) != str(chain_id):
        raise CheckError(f"{path}: made for chain {doc.get('chainId')}, but the fork is chain {chain_id}")
    txs = doc.get("transactions") or []
    if len(txs) != 1:
        raise CheckError(f"{path}: expected exactly one transaction, found {len(txs)}")
    t = txs[0]
    if str(t.get("to", "")).lower() != timelock.lower():
        raise CheckError(f"{path}: targets {t.get('to')}, not the timelock {timelock}")
    if (t.get("contractMethod") or {}).get("name") != method:
        raise CheckError(f"{path}: calls {(t.get('contractMethod') or {}).get('name')!r}, not {method!r}")
    if int(str(t.get("value", "0") or "0"), 0) != 0 or int(t.get("operation", 0) or 0) != 0:
        raise CheckError(f"{path}: sends value or is a DELEGATECALL")
    # The Safe UI encodes from the method form only when `data` is null (any string, "0x" and "" included, is sent
    # as-is; "0x" would hit the timelock's receive function), so pin both to what this check re-encodes: `data` null,
    # and exactly the timelock's argument types and names, in order. Same rule as `adr0029_batch.py import`.
    if t.get("data") is not None:
        raise CheckError(f"{path}: `data` is {t.get('data')!r}; expected null (the method form only)")
    want = [("targets", "address[]"), ("values", "uint256[]"), ("payloads", "bytes[]"), ("predecessor", "bytes32"),
            ("salt", "bytes32")] + ([("delay", "uint256")] if method == "scheduleBatch" else [])
    got = [(i.get("name"), i.get("type")) for i in (t.get("contractMethod") or {}).get("inputs") or []]
    if got != want:
        raise CheckError(f"{path}: {method} inputs {got} != {want}")
    v = t["contractInputsValues"]
    # Elements may be JSON strings ("0") or numbers (0); both are valid Transaction-Builder input.
    arr = lambda k: "[" + ",".join(str(x) for x in (json.loads(v[k]) if isinstance(v[k], str) else v[k])) + "]"  # noqa: E731
    return arr("targets"), arr("values"), arr("payloads"), v["predecessor"], v["salt"]


def _rpc(rpc: str, method: str, params: list):
    """JSON-RPC straight to the local fork: a large BTC Carry batch (file 2 is ~70 KB since #280) exceeds Linux's
    128 KiB per-argument limit as a hex `cast` argument, so its calldata never goes through `cast`."""
    import urllib.request
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(rpc, data=body, headers={"Content-Type": "application/json"}),
                                    timeout=600) as r:
            out = json.loads(r.read())
    except (OSError, ValueError) as e:  # URLError/HTTPError are OSErrors; a non-JSON body is a ValueError
        raise CheckError(f"{method}: {e}") from None
    if "error" in out:
        raise CheckError(f"{method}: {json.dumps(out['error'])[:300]}")
    return out["result"]


def _encode(sig: str, args: tuple[str, str, str, str, str]) -> str:
    """ABI-encode `sig` over the five batch arguments as `_batch_args` returns them ("[a,b]" strings + bytes32)."""
    from eth_abi import encode
    from eth_utils import keccak
    lst = lambda x: [e for e in x.strip("[]").split(",") if e]  # noqa: E731
    t, v, p, pred, salt = args

    def hexb(x: str, size: int | None = None) -> bytes:
        try:
            if not x.startswith("0x"):
                raise ValueError("missing 0x")
            b = bytes.fromhex(x[2:])
        except ValueError as e:
            raise CheckError(f"malformed hex argument {x[:20]!r}: {e}") from None
        if size is not None and len(b) != size:
            raise CheckError(f"{x[:20]!r} is {len(b)} bytes, expected {size}")
        return b
    vals = [lst(t), [int(x) for x in lst(v)], [hexb(x) for x in lst(p)], hexb(pred, 32), hexb(salt, 32)]
    return "0x" + keccak(text=sig)[:4].hex() + encode(["address[]", "uint256[]", "bytes[]", "bytes32", "bytes32"],
                                                       vals).hex()


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--timelock", required=True)
    ap.add_argument("--schedule", required=True)
    ap.add_argument("--execute", required=True)
    a = ap.parse_args(argv)
    rpc = os.environ.get("ADR0029_FORK_RPC", "")
    import chainlib
    if not chainlib.is_loopback_rpc(rpc):
        raise CheckError("ADR0029_FORK_RPC must be a loopback fork")
    fork_chain = int(_cast(rpc, "chain-id"))
    sched = _batch_args(a.schedule, a.timelock, "scheduleBatch", fork_chain)
    exe = _batch_args(a.execute, a.timelock, "executeBatch", fork_chain)
    # Compare the timelock's own operation ids, not the argument text (address casing must not matter).
    hash_sig = "hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32)"
    op = _rpc(rpc, "eth_call", [{"to": a.timelock, "data": _encode(hash_sig, exe)}, "latest"])
    if _rpc(rpc, "eth_call", [{"to": a.timelock, "data": _encode(hash_sig, sched)}, "latest"]) != op:
        raise CheckError("the executeBatch file does not name the scheduled operation (its hashOperationBatch differs)")
    pending = _cast(rpc, "call", a.timelock, "isOperationPending(bytes32)(bool)", op)
    ready = _cast(rpc, "call", a.timelock, "isOperationReady(bytes32)(bool)", op)
    print(f"operation {op}: pending={pending} ready={ready} (after the Council batch)")
    if pending != "true" or ready != "false":
        raise CheckError("the batch did not schedule the operation, or it is already executable")

    # The operation's own ready time (scheduled delay may exceed getMinDelay()), not the minimum.
    ready_at = int(_cast(rpc, "call", a.timelock, "getTimestamp(bytes32)(uint256)", op).split()[0])
    # The rehearsal pins the clock to +1 s per block (anvil_setBlockTimestampInterval), which overrides
    # evm_increaseTime: lift it and set the next block's timestamp explicitly.
    _cast(rpc, "rpc", "anvil_removeBlockTimestampInterval")
    now = int(_cast(rpc, "block", "latest", "--field", "timestamp"))
    delay = ready_at - now
    _cast(rpc, "rpc", "evm_setNextBlockTimestamp", hex(ready_at + 1))
    _cast(rpc, "rpc", "evm_mine")
    if _cast(rpc, "call", a.timelock, "isOperationReady(bytes32)(bool)", op) != "true":
        raise CheckError(f"not ready at its scheduled time ({ready_at})")

    _cast(rpc, "rpc", "anvil_setBalance", EXECUTOR, "0xde0b6b3a7640000")
    _cast(rpc, "rpc", "anvil_impersonateAccount", EXECUTOR)
    data = _encode("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", exe)
    call = {"from": EXECUTOR, "to": a.timelock, "data": data}
    gas = int(_rpc(rpc, "eth_estimateGas", [call]), 16)
    block_gas = int(_rpc(rpc, "eth_getBlockByNumber", ["latest", False])["gasLimit"], 16)
    txh = _rpc(rpc, "eth_sendTransaction", [dict(call, gas=hex(min(gas * 13 // 10, block_gas)))])
    rcpt = {}
    for _ in range(60):  # the receipt can lag the send by a moment
        rcpt = _rpc(rpc, "eth_getTransactionReceipt", [txh]) or {}
        if rcpt:
            break
        time.sleep(1)
    if not rcpt:
        raise CheckError(f"executeBatch {txh} was not mined")
    print(f"executeBatch from a random EOA after {delay + 1} s: status {rcpt['status']}, "
          f"gasUsed {int(rcpt['gasUsed'], 16)}, logs {len(rcpt['logs'])}")
    done = _cast(rpc, "call", a.timelock, "isOperationDone(bytes32)(bool)", op)
    print(f"operation done: {done}")
    if rcpt.get("status") not in ("0x1", 1) or done != "true":
        raise CheckError("executeBatch did not complete the operation")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except CheckError as e:
        print(f"FAIL: {e}")
        sys.exit(1)
