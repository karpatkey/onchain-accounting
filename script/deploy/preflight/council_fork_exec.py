#!/usr/bin/env python3
"""Execute a Transaction-Builder batch through a MULTI-OWNER Safe on a LOCAL anvil fork, as ONE MultiSend.

WHY THIS EXISTS
---------------
The ADR 0029 rollout batch (asset removals -> MigrateToMonitorFeeds -> upgradeToAndCall) is signed by the Security
Council Safe (5-of-8), not by the throwaway 1/1 ops Safe `ops_safe.py` drives. Rehearsing it faithfully means running
it the way the Council will: one `execTransaction` into `MultiSendCallOnly`, with `safeTxGas = gasPrice = 0` so any
failing inner call reverts the whole transaction (GS013). On a fork the owners' keys are unavailable, so each of the
first `threshold` owners (impersonated by anvil) calls `approveHash(safeTxHash)`, and the execution carries Safe's
"pre-approved" signature (v = 1, r = owner) for each of them, sorted by owner address as Safe requires.

FORK-ONLY: it refuses any RPC that is not loopback, because it impersonates owners and funds them with
`anvil_setBalance`. It reuses `ops_safe.py`'s MultiSend packer and cast wrapper; that tool is unchanged.

usage:
  council_fork_exec.py --rpc-url http://127.0.0.1:8546 --safe 0x… --batch FILE [--sender 0x…]
"""
from __future__ import annotations

import argparse
import json
import sys
import time

import ops_safe as o

FUND = "0x21e19e0c9bab2400000"  # 10,000 ether, for the impersonated owners' approveHash gas


class CouncilForkError(RuntimeError):
    pass


def approved_signatures(owners: list[str]) -> str:
    """Concatenated v=1 signatures for `owners`, sorted ascending by address (Safe's `checkNSignatures` order).
    Each is valid because that owner called `approveHash` (or is the sender)."""
    if not owners:
        raise CouncilForkError("no approving owners")
    if len({a.lower() for a in owners}) != len(owners):
        raise CouncilForkError("duplicate owner")
    ordered = sorted(owners, key=lambda a: int(a, 16))
    return "0x" + "".join(o.owner_approved_signature(a)[2:] for a in ordered)


def _loopback(rpc: str) -> None:
    import chainlib
    if not chainlib.is_loopback_rpc(rpc):
        raise CouncilForkError("REFUSING: council_fork_exec.py runs on a local anvil fork only (loopback RPC)")


def _owners(rpc: str, safe: str) -> tuple[list[str], int]:
    raw = o.cast("call", safe, "getOwners()(address[])", "--rpc-url", rpc)
    owners = [x.strip() for x in raw.strip("[]").split(",") if x.strip()]
    threshold = int(o.cast("call", safe, "getThreshold()(uint256)", "--rpc-url", rpc).split()[0])
    if not owners or threshold < 1 or threshold > len(owners):
        raise CouncilForkError(f"implausible Safe config: {len(owners)} owners, threshold {threshold}")
    return owners, threshold


def _rpc(rpc: str, method: str, params: list):
    """JSON-RPC straight to the LOCAL fork. The MultiSend calldata is passed this way, never as a `cast` argument: a
    large batch (the 2026-10-29 mainnet batch is ~88 KB, ~177 KB as hex) exceeds Linux's 128 KiB per-argument limit
    (MAX_ARG_STRLEN) and `cast` cannot even be started."""
    import urllib.request
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(rpc, data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            out = json.loads(r.read())
    except (OSError, ValueError) as e:  # URLError/HTTPError are OSErrors; a non-JSON body is a ValueError
        raise CouncilForkError(f"{method}: {e}") from None
    if "error" in out:
        raise CouncilForkError(f"{method}: {json.dumps(out['error'])[:300]}")
    return out["result"]


def _abi_call(sig: str, types: list[str], values: list) -> str:
    from eth_abi import encode
    from eth_utils import keccak
    return "0x" + keccak(text=sig)[:4].hex() + encode(types, values).hex()


def run(rpc: str, safe: str, batch_path: str, sender: str) -> dict:
    _loopback(rpc)
    o.check_code(rpc, o.MULTISEND_CALL_ONLY, safe)
    chain_id = int(o.cast("chain-id", "--rpc-url", rpc))
    batch = o.load_batch(batch_path)
    o.check_batch(batch, safe, chain_id)
    owners, threshold = _owners(rpc, safe)
    signers = sorted(owners, key=lambda a: int(a, 16))[:threshold]
    nonce = int(o.cast("call", safe, "nonce()(uint256)", "--rpc-url", rpc).split()[0])
    ms_bytes = bytes.fromhex(o.pack_multisend(batch["transactions"])[2:])
    ms = _abi_call("multiSend(bytes)", ["bytes"], [ms_bytes])
    tx_args_types = ["address", "uint256", "bytes", "uint8", "uint256", "uint256", "uint256", "address", "address"]
    tx_args = [o.MULTISEND_CALL_ONLY, 0, bytes.fromhex(ms[2:]), 1, 0, 0, 0, o.ZERO, o.ZERO]
    h = _rpc(rpc, "eth_call", [{"to": safe, "data": _abi_call(
        "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)",
        tx_args_types + ["uint256"], tx_args + [nonce])}, "latest"])
    for owner in signers:
        o.cast("rpc", "anvil_setBalance", owner, FUND, "--rpc-url", rpc)
        # Explicit, so this also works on a plain `anvil --fork-url` (the rehearsal adds --auto-impersonate).
        o.cast("rpc", "anvil_impersonateAccount", owner, "--rpc-url", rpc)
        o.send(rpc, safe, o.cast("calldata", "approveHash(bytes32)", h), ["--unlocked", "--from", owner], None)
    exec_data = _abi_call(
        "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
        tx_args_types + ["bytes"], tx_args + [bytes.fromhex(approved_signatures(signers)[2:])])
    call = {"from": sender, "to": safe, "data": exec_data}
    ok = _rpc(rpc, "eth_call", [call, "latest"])
    if int(ok or "0x0", 16) != 1:
        raise CouncilForkError(f"simulation returned {ok}, expected true")
    est = int(_rpc(rpc, "eth_estimateGas", [call]), 16)
    block_gas = int(o.cast("block", "latest", "--field", "gasLimit", "--rpc-url", rpc), 0)
    gas_limit = min(est * 13 // 10, block_gas)
    o.cast("rpc", "anvil_setBalance", sender, FUND, "--rpc-url", rpc)
    o.cast("rpc", "anvil_impersonateAccount", sender, "--rpc-url", rpc)
    txh = _rpc(rpc, "eth_sendTransaction", [dict(call, gas=hex(gas_limit))])
    r = None
    for _ in range(60):  # anvil automines; poll briefly in case it does not
        r = _rpc(rpc, "eth_getTransactionReceipt", [txh])
        if r:
            break
        time.sleep(1)
    if not r or str(r.get("status")) not in ("0x1", "1"):
        raise CouncilForkError(f"tx {txh} reverted or was not mined (status {r and r.get('status')})")
    ok_t = o.cast("keccak", o.EXECUTION_SUCCESS_TOPIC_SIG).lower()
    topics = [(l.get("address", "").lower(), (l.get("topics") or [""])[0].lower()) for l in r.get("logs", [])]
    if (safe.lower(), ok_t) not in topics:
        raise CouncilForkError(f"tx {r.get('transactionHash')} mined without ExecutionSuccess from the Safe")
    after = int(o.cast("call", safe, "nonce()(uint256)", "--rpc-url", rpc).split()[0])
    if after != nonce + 1:
        raise CouncilForkError(f"Safe nonce {nonce} -> {after}, expected +1")
    return {"calls": len(batch["transactions"]), "threshold": threshold, "owners": len(owners),
            "estimate": est, "gasUsed": int(str(r.get("gasUsed")), 0), "blockGasLimit": block_gas,
            "tx": r.get("transactionHash")}


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rpc-url", required=True)
    ap.add_argument("--safe", required=True)
    ap.add_argument("--batch", required=True)
    ap.add_argument("--sender", default="0x000000000000000000000000000000000000bEEF",
                    help="who sends execTransaction (any account; the signatures are the owners' approvals)")
    a = ap.parse_args(argv)
    try:
        res = run(a.rpc_url, a.safe, a.batch, a.sender)
    except (CouncilForkError, o.OpsSafeError) as e:
        print(f"FAIL: {e}")
        return 1
    print(f"EXECUTED atomically through {a.safe} ({res['threshold']}-of-{res['owners']}): {res['calls']} call(s), "
          f"gasUsed {res['gasUsed']} (estimate {res['estimate']}, block gas limit {res['blockGasLimit']}), "
          f"tx {res['tx']}")
    print(json.dumps(res))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
