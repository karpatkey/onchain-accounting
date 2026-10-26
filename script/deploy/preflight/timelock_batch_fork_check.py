#!/usr/bin/env python3
"""Fork-only follow-through for a timelock `scheduleBatch` that rode in a Council batch (ADR0029_ROLLOUT.md,
"Another team's Council calls in the same transaction").

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
import sys

EXECUTOR = "0x00000000000000000000000000000000000b7c01"


class CheckError(Exception):
    pass


def _cast(rpc: str, *a: str) -> str:
    r = subprocess.run(["cast", *a, "--rpc-url", rpc], capture_output=True, text=True)
    if r.returncode:
        raise CheckError(f"cast {a[0]}: {r.stderr.strip()[:300]}")
    return r.stdout.strip()


def _batch_args(path: str) -> tuple[str, str, str, str, str]:
    v = json.load(open(path))["transactions"][0]["contractInputsValues"]
    arr = lambda k: "[" + ",".join(json.loads(v[k]) if isinstance(v[k], str) else v[k]) + "]"  # noqa: E731
    return arr("targets"), arr("values"), arr("payloads"), v["predecessor"], v["salt"]


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--timelock", required=True)
    ap.add_argument("--schedule", required=True)
    ap.add_argument("--execute", required=True)
    a = ap.parse_args(argv)
    rpc = os.environ.get("ADR0029_FORK_RPC", "")
    if not (rpc.startswith("http://127.0.0.1:") or rpc.startswith("http://localhost:")):
        raise CheckError("ADR0029_FORK_RPC must be a loopback fork")
    sched, exe = _batch_args(a.schedule), _batch_args(a.execute)
    if sched != exe:
        raise CheckError("the executeBatch file does not name the scheduled operation (targets/values/payloads/"
                         "predecessor/salt differ)")
    op = _cast(rpc, "call", a.timelock, "hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32)(bytes32)",
               *exe)
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
    data = subprocess.run(["cast", "calldata", "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", *exe],
                          capture_output=True, text=True, check=True).stdout.strip()
    rcpt = json.loads(_cast(rpc, "send", a.timelock, data, "--from", EXECUTOR, "--unlocked", "--json"))
    print(f"executeBatch from a random EOA after {delay + 1} s: status {rcpt['status']}, "
          f"gasUsed {int(rcpt['gasUsed'], 16)}, logs {len(rcpt['logs'])}")
    done = _cast(rpc, "call", a.timelock, "isOperationDone(bytes32)(bool)", op)
    print(f"operation done: {done}")
    if rcpt["status"] not in ("0x1", 1) or done != "true":
        raise CheckError("executeBatch did not complete the operation")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except CheckError as e:
        print(f"FAIL: {e}")
        sys.exit(1)
