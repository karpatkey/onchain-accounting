#!/usr/bin/env python3
"""Deploy the throwaway 1/1 ops Safe and execute a Transaction-Builder batch through it as ONE MultiSend.

WHY THIS EXISTS
---------------
The PR #338 swap (`SwapMetaAdapter.plan()`) is only safe if a chain's whole batch lands ATOMICALLY: the
registry no longer re-arms the default adapter on release, so a half-applied swap leaves tokens reported by
nobody, and a reordered one could leave two reporters. The plan routes that batch through a throwaway 1/1
Safe (MANAGER only) owned by the deployer EOA. This tool is that path, end to end, with no Safe UI:

  * `deploy`  — CREATE2 a Safe v1.4.1 (`SafeL2` singleton, canonical `SafeProxyFactory`, canonical fallback
                handler) with the deployer as sole owner, threshold 1. The same owner + salt nonce gives the
                SAME address on every chain, so one `OPS_SAFE` value serves the fleet. Idempotent: if the
                predicted address already has code, it is verified instead of redeployed.
  * `exec`    — wrap every entry of a Transaction-Builder JSON batch into one `MultiSendCallOnly.multiSend`
                and call `execTransaction` on the Safe, sent BY the sole owner. The signature is Safe's
                "approved by msg.sender" form (v = 1, r = owner), so nothing is signed off-chain and the
                Transaction Builder's `createdFromSafeAddress`/checksum import step is never involved.
                `safeTxGas = gasPrice = 0`, so any failing inner call reverts the WHOLE transaction (GS013):
                all or nothing.

Both default to SIMULATION (eth_call from the owner). `--send` broadcasts via `cast send`, with every
argument after `--` passed to it verbatim (the signer): on a fork `-- --unlocked --from <owner>`, for real
`-- --account kpk-deployer --password-file <file>`. The RPC URL is never printed.

usage:
  ops_safe.py address --rpc-url URL --owner 0x… [--salt-nonce N]
  ops_safe.py deploy  --rpc-url URL --owner 0x… [--salt-nonce N] [--send -- <cast signer args>]
  ops_safe.py exec    --rpc-url URL --owner 0x… --safe 0x… --batch FILE [--send -- <cast signer args>]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys

# Safe v1.4.1 canonical deployments (safe-global/safe-deployments). Presence on every PR #338 asset chain
# (1, 10, 56, 100, 137, 8453, 42161, 5042) verified 2026-09-29; `check_code` re-verifies on every run.
SAFE_PROXY_FACTORY = "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67"
SAFE_L2_SINGLETON = "0x29fcB43b46531BcA003ddC8FCB67FFE91900C762"
FALLBACK_HANDLER = "0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99"
MULTISEND_CALL_ONLY = "0x9641d764fc13c8B624c04430C7356C1C7C8102e2"
ZERO = "0x0000000000000000000000000000000000000000"
SENTINEL = "0x0000000000000000000000000000000000000001"
# Safe's storage slots for its fallback handler and transaction guard (hashed at runtime by `verify_safe`).
FALLBACK_HANDLER_SLOT_SEED = "fallback_manager.handler.address"
GUARD_SLOT_SEED = "guard_manager.guard.address"
# Fixed so the ops Safe has ONE predictable address fleet-wide: uint256(keccak256(SALT_SEED)).
SALT_SEED = "kpk.pr338.ops-safe"
EXECUTION_SUCCESS_TOPIC_SIG = "ExecutionSuccess(bytes32,uint256)"
EXECUTION_FAILURE_TOPIC_SIG = "ExecutionFailure(bytes32,uint256)"


class OpsSafeError(RuntimeError):
    pass


# --- pure encoders (unit-tested) ------------------------------------------------------------------------

def _hex(b: str) -> str:
    b = b[2:] if b.startswith(("0x", "0X")) else b
    if len(b) % 2:
        raise OpsSafeError(f"odd-length hex: {b[:20]}…")
    int(b or "0", 16)  # validates
    return b.lower()


def _addr(a: str) -> str:
    h = _hex(a)
    if len(h) != 40:
        raise OpsSafeError(f"not an address: {a}")
    return h


def pack_multisend(txs: list[dict]) -> str:
    """MultiSend's packed encoding: per tx `uint8 op | address to | uint256 value | uint256 len | bytes data`.

    Only operation 0 (Call) is accepted — the target is MultiSendCallOnly, which reverts on DELEGATECALL
    anyway, and a batch that asks for one is not a batch this tool should run.
    """
    if not txs:
        raise OpsSafeError("empty batch")
    out = []
    for i, t in enumerate(txs):
        op = int(t.get("operation", 0) or 0)
        if op != 0:
            raise OpsSafeError(f"entry {i}: operation {op} (DELEGATECALL) refused")
        value = int(str(t.get("value", "0") or "0"), 0)
        if value < 0:
            raise OpsSafeError(f"entry {i}: negative value")
        raw = t.get("data")
        if raw is None:
            # A Transaction-Builder entry in the UI's method form (contractMethod + contractInputsValues, data null)
            # carries no calldata; packing it as empty would silently call the target's receive/fallback instead.
            hint = " (method form: encode it first with `adr0029_batch.py import`)" if t.get("contractMethod") else ""
            raise OpsSafeError(f"entry {i}: no calldata{hint}")
        data = _hex(raw)
        if not data and value == 0:
            raise OpsSafeError(f"entry {i}: empty call with no value — it would only hit the target's receive/fallback")
        out.append("00" + _addr(t["to"]) + f"{value:064x}" + f"{len(data) // 2:064x}" + data)
    return "0x" + "".join(out)


def owner_approved_signature(owner: str) -> str:
    """Safe signature type v=1: "approved by msg.sender". Valid only when the tx is SENT by `owner`."""
    return "0x" + "0" * 24 + _addr(owner) + "0" * 64 + "01"


def load_batch(path: str) -> dict:
    with open(path) as f:
        batch = json.load(f)
    if not isinstance(batch.get("transactions"), list) or not batch["transactions"]:
        raise OpsSafeError(f"{path}: no transactions")
    return batch


def check_batch(batch: dict, safe: str, chain_id: int) -> None:
    """The batch must have been generated FOR this Safe on THIS chain."""
    bc = str(batch.get("chainId", ""))
    if bc != str(chain_id):
        raise OpsSafeError(f"batch chainId {bc!r} != RPC chain id {chain_id}")
    stamped = (batch.get("meta") or {}).get("createdFromSafeAddress") or ""
    if stamped.lower() != safe.lower():
        raise OpsSafeError(f"batch was generated for Safe {stamped or '<none>'}, not {safe} — regenerate it "
                           f"with OPS_SAFE={safe}")


# --- cast wrappers ----------------------------------------------------------------------------------------

# A whole-chain swap batch is one heavy eth_call; against a cold fork (every slot fetched upstream) it takes
# minutes, well past cast's 45 s default (observed: chain-1, 54 calls). Only the RPC-touching subcommands take it.
RPC_TIMEOUT_S = "900"
_RPC_SUBCOMMANDS = {"call", "estimate", "send", "code", "storage", "chain-id", "block"}


def cast(*args: str) -> str:
    argv = ["cast", *args] + (["--rpc-timeout", RPC_TIMEOUT_S] if args and args[0] in _RPC_SUBCOMMANDS else [])
    r = subprocess.run(argv, capture_output=True, text=True)
    if r.returncode != 0:
        # Never echo the command line: it carries the RPC URL (and possibly an API key).
        raise OpsSafeError(f"cast {args[0]} failed: {(r.stderr or r.stdout).strip()[-400:]}")
    return r.stdout.strip()


def salt_nonce(explicit: str | None) -> str:
    return explicit if explicit is not None else str(int(cast("keccak", SALT_SEED), 16))


def setup_initializer(owner: str) -> str:
    return cast("calldata", "setup(address[],uint256,address,bytes,address,address,uint256,address)",
                f"[{owner}]", "1", ZERO, "0x", FALLBACK_HANDLER, ZERO, "0", ZERO)


def check_code(rpc: str, *addrs: str) -> None:
    for a in addrs:
        if cast("code", a, "--rpc-url", rpc) in ("0x", ""):
            raise OpsSafeError(f"no code at {a} on this chain — canonical Safe v1.4.1 not deployed here")


def predict(rpc: str, owner: str, nonce: str) -> str:
    return cast("call", SAFE_PROXY_FACTORY, "createProxyWithNonce(address,bytes,uint256)(address)",
                SAFE_L2_SINGLETON, setup_initializer(owner), nonce, "--from", owner, "--rpc-url", rpc)


def verify_safe(rpc: str, safe: str, owner: str) -> int:
    """Asserts the Safe is exactly what `deploy` creates; returns its nonce."""
    if cast("code", safe, "--rpc-url", rpc) in ("0x", ""):
        raise OpsSafeError(f"no code at Safe {safe}")
    owners = cast("call", safe, "getOwners()(address[])", "--rpc-url", rpc).strip("[]").replace(" ", "")
    if owners.lower() != owner.lower():
        raise OpsSafeError(f"Safe owners are [{owners}], expected exactly [{owner}]")
    if cast("call", safe, "getThreshold()(uint256)", "--rpc-url", rpc).split()[0] != "1":
        raise OpsSafeError("Safe threshold is not 1")
    singleton = cast("parse-bytes32-address", cast("storage", safe, "0", "--rpc-url", rpc))
    if singleton.lower() != SAFE_L2_SINGLETON.lower():
        raise OpsSafeError(f"Safe singleton is {singleton}, expected {SAFE_L2_SINGLETON}")
    handler = cast("parse-bytes32-address",
                   cast("storage", safe, cast("keccak", FALLBACK_HANDLER_SLOT_SEED), "--rpc-url", rpc))
    if handler.lower() != FALLBACK_HANDLER.lower():
        raise OpsSafeError(f"Safe fallback handler is {handler}, expected {FALLBACK_HANDLER}")
    guard = cast("parse-bytes32-address", cast("storage", safe, cast("keccak", GUARD_SLOT_SEED), "--rpc-url", rpc))
    if guard.lower() != ZERO:
        raise OpsSafeError(f"Safe has a transaction guard set: {guard}")
    modules = cast("call", safe, "getModulesPaginated(address,uint256)(address[],address)", SENTINEL, "10",
                   "--rpc-url", rpc).splitlines()[0].strip()
    if modules != "[]":
        raise OpsSafeError(f"Safe has modules enabled: {modules}")
    return int(cast("call", safe, "nonce()(uint256)", "--rpc-url", rpc).split()[0])


def settled(fn, what: str, tries: int = 12, delay: float = 5.0):
    """Retry a post-send read until it passes. Load-balanced RPCs can serve a read from a replica that is
    behind the node that returned the receipt (observed on Base: "no code at Safe" 0 s after a mined deploy).
    A false failure here is dangerous — it invites a re-send — so wait out the lag before reporting one."""
    import time
    for i in range(tries):
        try:
            return fn()
        except OpsSafeError as e:
            if i == tries - 1:
                raise OpsSafeError(f"{what} still failing after {int(tries * delay)} s: {e}")
            time.sleep(delay)


def send(rpc: str, to: str, data: str, signer: list[str], gas_limit: int | None) -> dict:
    extra = ["--gas-limit", str(gas_limit)] if gas_limit else []
    r = json.loads(cast("send", to, data, "--rpc-url", rpc, "--json", *extra, *signer))
    if str(r.get("status")) not in ("0x1", "1"):
        raise OpsSafeError(f"tx {r.get('transactionHash')} reverted (status {r.get('status')})")
    return r


# --- commands --------------------------------------------------------------------------------------------

def cmd_address(a) -> int:
    check_code(a.rpc_url, SAFE_PROXY_FACTORY, SAFE_L2_SINGLETON, FALLBACK_HANDLER)
    print(predict(a.rpc_url, a.owner, salt_nonce(a.salt_nonce)))
    return 0


def cmd_deploy(a, signer: list[str]) -> int:
    check_code(a.rpc_url, SAFE_PROXY_FACTORY, SAFE_L2_SINGLETON, FALLBACK_HANDLER, MULTISEND_CALL_ONLY)
    nonce = salt_nonce(a.salt_nonce)
    safe = predict(a.rpc_url, a.owner, nonce)
    if cast("code", safe, "--rpc-url", a.rpc_url) not in ("0x", ""):
        verify_safe(a.rpc_url, safe, a.owner)
        print(f"ALREADY DEPLOYED + verified: {safe}")
        return 0
    data = cast("calldata", "createProxyWithNonce(address,bytes,uint256)", SAFE_L2_SINGLETON,
                setup_initializer(a.owner), nonce)
    if not a.send:
        print(f"SIMULATION: would deploy ops Safe at {safe} (owner {a.owner}, threshold 1). Re-run with --send.")
        return 0
    r = send(a.rpc_url, SAFE_PROXY_FACTORY, data, signer, None)
    settled(lambda: verify_safe(a.rpc_url, safe, a.owner), "post-deploy Safe verification")
    print(f"DEPLOYED + verified: {safe}  tx {r.get('transactionHash')}  gas {int(str(r.get('gasUsed')), 0)}")
    return 0


def cmd_exec(a, signer: list[str]) -> int:
    check_code(a.rpc_url, MULTISEND_CALL_ONLY)
    chain_id = int(cast("chain-id", "--rpc-url", a.rpc_url))
    batch = load_batch(a.batch)
    check_batch(batch, a.safe, chain_id)
    nonce_before = verify_safe(a.rpc_url, a.safe, a.owner)
    txs = batch["transactions"]
    ms = cast("calldata", "multiSend(bytes)", pack_multisend(txs))
    exec_data = cast("calldata",
                     "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
                     MULTISEND_CALL_ONLY, "0", ms, "1", "0", "0", "0", ZERO, ZERO, owner_approved_signature(a.owner))
    # Simulate first, always: a revert here means the batch cannot land atomically — do not send.
    ok = cast("call", a.safe, exec_data, "--from", a.owner, "--rpc-url", a.rpc_url)
    if int(ok or "0x0", 16) != 1:
        raise OpsSafeError(f"simulation returned {ok}, expected true")
    est = int(cast("estimate", a.safe, exec_data, "--from", a.owner, "--rpc-url", a.rpc_url))
    gas_limit = est * 13 // 10
    block_gas = int(cast("block", "latest", "--field", "gasLimit", "--rpc-url", a.rpc_url), 0)
    print(f"batch {a.batch}: {len(txs)} call(s) -> ONE execTransaction, estimate {est} gas "
          f"(limit {gas_limit}, block gas limit {block_gas}), Safe nonce {nonce_before}")
    if gas_limit > block_gas:
        raise OpsSafeError("batch does not fit in one block — split it at an adapter-swap boundary")
    if not a.send:
        print("SIMULATION OK — re-run with --send to broadcast.")
        return 0
    r = send(a.rpc_url, a.safe, exec_data, signer, gas_limit)
    ok_t = cast("keccak", EXECUTION_SUCCESS_TOPIC_SIG).lower()
    bad_t = cast("keccak", EXECUTION_FAILURE_TOPIC_SIG).lower()
    topics = [(l.get("address", "").lower(), (l.get("topics") or [""])[0].lower()) for l in r.get("logs", [])]
    if (a.safe.lower(), bad_t) in topics or (a.safe.lower(), ok_t) not in topics:
        raise OpsSafeError(f"tx {r.get('transactionHash')} mined but the Safe did not emit ExecutionSuccess")
    def nonce_advanced() -> int:
        n = int(cast("call", a.safe, "nonce()(uint256)", "--rpc-url", a.rpc_url).split()[0])
        if n != nonce_before + 1:
            raise OpsSafeError(f"Safe nonce {nonce_before} -> {n}, expected +1")
        return n
    nonce_after = settled(nonce_advanced, "post-exec nonce check (the tx IS mined with ExecutionSuccess — do NOT re-send)")
    print(f"EXECUTED atomically: tx {r.get('transactionHash')}  gasUsed {int(str(r.get('gasUsed')), 0)}  "
          f"Safe nonce {nonce_before} -> {nonce_after}")
    return 0


def main(argv: list[str]) -> int:
    signer: list[str] = []
    if "--" in argv:
        i = argv.index("--")
        argv, signer = argv[:i], argv[i + 1:]
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("address", "deploy", "exec"):
        p = sub.add_parser(name)
        p.add_argument("--rpc-url", required=True)
        p.add_argument("--owner", required=True)
        if name in ("address", "deploy"):
            p.add_argument("--salt-nonce", default=None)
        if name == "exec":
            p.add_argument("--safe", required=True)
            p.add_argument("--batch", required=True)
        if name != "address":
            p.add_argument("--send", action="store_true")
    a = ap.parse_args(argv)
    if getattr(a, "send", False) and not signer:
        ap.error("--send needs the cast signer args after `--` (e.g. `-- --unlocked --from <owner>`)")
    try:
        if a.cmd == "address":
            return cmd_address(a)
        if a.cmd == "deploy":
            return cmd_deploy(a, signer)
        return cmd_exec(a, signer)
    except OpsSafeError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
