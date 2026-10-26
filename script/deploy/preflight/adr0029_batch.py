#!/usr/bin/env python3
"""Build the per-chain ADR 0029 rollout batch for the Security Council Safe, as ONE Transaction-Builder file.

The batch, in its load-bearing order (`script/deploy/ADR0029_ROLLOUT.md`):
  1. removals  — `NAVCalculator.removeBalanceAdapters([...])` for registered adapters whose config is now
                 `enabled: false`, then `AssetKindRegistry.unregisterAsset(asset)` for every asset registered on the
                 live NAV but absent from nav-config (ezETH on 1 and 42161, EIGEN on 1). Adapters first: that
                 releases their claim on the asset's coordinate.
  2. the `MigrateToMonitorFeeds` batch (alone; it also swaps the primaries — see the rollout doc);
  3. `upgradeToAndCall(newImpl, "")` on the NAV proxy, last.

Removals are DERIVED from live state vs config, so they are only as right as the config. To make an accidental
unregistration impossible, `removals` refuses unless the derived sets equal what the operator states with
`--expect-assets` / `--expect-adapters` (empty = expect none).

usage:
  adr0029_batch.py removals --chain 1 --rpc-env MAINNET_URL --expect-assets 0xbf54…,0xec53… \\
                            --expect-adapters 0x9145… --out safe-transactions/1-adr0029-removals.json
  adr0029_batch.py assemble --chain 1 --parts safe-transactions/1-adr0029-removals.json \\
                            safe-transactions/1-migrate-monitor-feeds.json --upgrade-impl 0x… \\
                            --out safe-transactions/1-adr0029-rollout.json
  adr0029_batch.py import   --chain 1 --in <Transaction-Builder file from another repo> \\
                            --out safe-transactions/1-btc-carry-schedule.json
`import` turns a Council Transaction-Builder file written in the UI's method form (`contractMethod` +
`contractInputsValues`, no `data`, no checksum) into a stamped part, so `assemble` can bundle another team's Council
calls into the same Safe transaction (2026-10-26: the BTC Carry `scheduleBatch` rides in chain 1's batch). It refuses
tuple-typed inputs, value, DELEGATECALL, another chain or another Safe, and records the source file's sha256.
`--rpc-url` is accepted only for a loopback (fork) endpoint; a real endpoint is read from the environment with
`--rpc-env` and is never printed.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

import adr0029_census as ac
import chainlib as c

SEL_GET_ALL_ADAPTERS = "0xe31ada97"  # getAllAdapters()
NATIVE_ADDRESS = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"  # src/balances/Balances.sol NATIVE_ADDRESS
SEL_REMOVE_BALANCE_ADAPTERS = "0x3aecc485"  # removeBalanceAdapters(address[])
SEL_UNREGISTER_ASSET = "0xc906d2cf"  # unregisterAsset(address)
SEL_UPGRADE_TO_AND_CALL = "0x4f1ef286"  # upgradeToAndCall(address,bytes)


class BatchError(Exception):
    pass


def _csv(s: str | None) -> set[str]:
    return {x.strip().lower() for x in (s or "").split(",") if x.strip()}


def decode_addresses(ret_hex: str) -> list[str]:
    """`address[]`: offset, length, one word per element."""
    raw = ac._raw(ret_hex)
    off = ac._word(raw, 0)
    n = ac._word(raw, off)
    return [ac._addr(ac._word(raw, off + 32 + 32 * i)) for i in range(n)]


def config_assets(chain: int) -> set[str]:
    p = c.NAV_CONFIG_DIR / "assets-and-price-feeds" / f"{chain}.json"
    cfg = json.loads(p.read_text()) if p.exists() else {}
    return {v["address"].lower() for k, v in cfg.items()
            if not k.startswith("$") and isinstance(v, dict) and c.is_address(v.get("address", ""))}


def enabled_adapter_addresses(chain: int) -> set[str]:
    """Record addresses of every adapter that is `enabled: true` in nav-config, plus the default adapter."""
    rec = (c.deployment(chain).get("balanceAdapters") or {})
    out: set[str] = set()
    for sub in ("meta-balance-adapters", "balance-adapters"):
        p = c.NAV_CONFIG_DIR / sub / f"{chain}.json"
        if not p.exists():
            continue
        for k, v in json.loads(p.read_text()).items():
            if k.startswith("$") or not isinstance(v, dict) or v.get("enabled") is not True:
                continue
            a = rec.get(k)
            if isinstance(a, str) and c.is_address(a):
                out.add(a.lower())
    return out


def disabled_adapters(chain: int) -> dict[str, str]:
    """{record address: key} for adapters that have a deployment record but are `enabled: false` in nav-config."""
    rec = (c.deployment(chain).get("balanceAdapters") or {})
    out: dict[str, str] = {}
    for sub in ("meta-balance-adapters", "balance-adapters"):
        p = c.NAV_CONFIG_DIR / sub / f"{chain}.json"
        if not p.exists():
            continue
        for k, v in json.loads(p.read_text()).items():
            if k.startswith("$") or not isinstance(v, dict) or v.get("enabled") is not False:
                continue
            a = rec.get(k)
            if isinstance(a, str) and c.is_address(a):
                out[a.lower()] = k
    return out


def derive_removals(chain: int, reader, proxy: str = ac.NAV_PROXY) -> tuple[list[str], list[str]]:
    """(adapters to deregister, assets to unregister), from the live NAV vs this tree's config."""
    live_assets = {a.lower() for a in ac.decode_assets(reader.call(proxy, ac.SEL_GET_REGISTERED_ASSETS))}
    live_adapters = {a.lower() for a in decode_addresses(reader.call(proxy, SEL_GET_ALL_ADAPTERS))}
    # The native-token placeholder is registered by `NAVCalculator.initialize`, never by config (most chains with
    # no assets have no asset config at all), so it is never a removal.
    assets = sorted(live_assets - config_assets(chain) - {NATIVE_ADDRESS})
    adapters = sorted(set(disabled_adapters(chain)) & live_adapters)
    # The symmetric check: any OTHER registered adapter that config does not enable (a deleted key, a re-pointed
    # record) is not removed automatically — it is reported, so under-derivation cannot pass silently.
    unexplained = live_adapters - enabled_adapter_addresses(chain) - set(adapters) - set(default_adapters(reader, proxy))
    if unexplained:
        raise BatchError(f"chain {chain}: registered adapter(s) neither enabled nor disabled in config: "
                         f"{sorted(unexplained)} — resolve the config before building the batch")
    return adapters, assets


SEL_DEFAULT_ADAPTER = "0xac3351bd"  # erc20DefaultBalanceAdapter()


def default_adapters(reader, proxy: str) -> list[str]:
    """The NAV's ERC20 default adapter, which config never lists."""
    try:
        raw = ac._raw(reader.call(proxy, SEL_DEFAULT_ADAPTER))
        return [ac._addr(ac._word(raw, 0))] if len(raw) == 32 else []
    except ac.CensusError:  # a malformed reply: nothing to exempt (an RPC error propagates, honestly)
        return []


def removal_transactions(chain: int, adapters: list[str], assets: list[str], proxy: str = ac.NAV_PROXY) -> list[dict]:
    txs = []
    if adapters:
        txs.append({"to": proxy, "value": "0", "operation": 0,
                    "data": enc_remove_balance_adapters(adapters)})
    if assets:
        akr = (c.deployment(chain).get("AssetKindRegistry") or "")
        if not c.is_address(akr):
            raise BatchError(f"chain {chain}: no AssetKindRegistry in the deployment record")
        for a in assets:
            txs.append({"to": akr, "value": "0", "operation": 0, "data": enc_unregister_asset(a)})
    return txs


# Calldata, ABI-encoded by hand: the CI preflight job has no Foundry, so no `cast`. Cross-checked against
# `cast calldata` in test_adr0029_batch.py wherever cast is installed.
def _word_addr(a: str) -> str:
    if not c.is_address(a):
        raise BatchError(f"not an address: {a!r}")
    return a[2:].lower().rjust(64, "0")


def enc_remove_balance_adapters(adapters: list[str]) -> str:
    return (SEL_REMOVE_BALANCE_ADAPTERS + f"{32:064x}" + f"{len(adapters):064x}"
            + "".join(_word_addr(a) for a in adapters))


def enc_unregister_asset(asset: str) -> str:
    return SEL_UNREGISTER_ASSET + _word_addr(asset)


def enc_upgrade_to_and_call(impl: str) -> str:
    """`upgradeToAndCall(impl, "")`: address, offset 0x40, empty bytes."""
    return SEL_UPGRADE_TO_AND_CALL + _word_addr(impl) + f"{64:064x}" + f"{0:064x}"


def checksum(txs: list[dict]) -> str:
    """keccak256(abi.encode(Transaction[])), exactly as `SafeTxBuilder.writeSafeTx` stamps it."""
    from eth_abi import encode
    from eth_utils import keccak
    rows = [(t["to"], int(str(t["value"]), 0), bytes.fromhex(t["data"][2:]), int(t.get("operation", 0)))
            for t in txs]
    return "0x" + keccak(encode(["(address,uint256,bytes,uint8)[]"], [rows])).hex()


def write_batch(path: str, chain: int, safe: str, name: str, description: str, txs: list[dict]) -> None:
    for t in txs:
        t.setdefault("contractMethod", None)
        t.setdefault("contractInputsValues", None)
    doc = {"version": "1.0", "chainId": str(chain), "createdAt": int(time.time() * 1000),
           "meta": {"name": name, "description": description, "txBuilderVersion": "1.18.3",
                    "createdFromSafeAddress": safe, "createdFromOwnerAddress": "", "checksum": checksum(txs)},
           "transactions": [{"to": t["to"], "value": str(t["value"]), "data": t["data"],
                             "operation": int(t.get("operation", 0)), "contractMethod": None,
                             "contractInputsValues": None} for t in txs]}
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(doc, indent=2) + "\n")


def _council(chain: int) -> str:
    s = (c.chain_config(chain).get("addresses") or {}).get("securityCouncil", "")
    if not c.is_address(s):
        raise BatchError(f"chain {chain}: no securityCouncil in script/config/chains/{chain}.json")
    return s


def _reader(a) -> ac.LiveReader:
    if a.rpc_url:
        if not (a.rpc_url.startswith("http://127.0.0.1:") or a.rpc_url.startswith("http://localhost:")):
            raise BatchError("--rpc-url is for a loopback fork only; use --rpc-env for a real endpoint")
        url = a.rpc_url
    else:
        url = os.environ.get(a.rpc_env or "")
        if not url:
            raise BatchError(f"no RPC: set --rpc-url (fork) or --rpc-env <VAR> (env var {a.rpc_env!r} is empty)")
    reader = ac.LiveReader(url)
    why = ac.chain_mismatch(reader, a.chain)
    if why:
        raise BatchError(f"chain {a.chain}: {why} — refusing to derive removals from another chain")
    return reader


def cmd_removals(a) -> int:
    adapters, assets = derive_removals(a.chain, _reader(a))
    want_ad, want_as = _csv(a.expect_adapters), _csv(a.expect_assets)
    if set(adapters) != want_ad or set(assets) != want_as:
        raise BatchError(f"chain {a.chain}: derived removals differ from what was expected — refusing.\n"
                         f"  adapters derived {adapters} / expected {sorted(want_ad)}\n"
                         f"  assets   derived {assets} / expected {sorted(want_as)}")
    txs = removal_transactions(a.chain, adapters, assets)
    # ALWAYS written, even empty: `assemble` refuses an absent part, so a mistyped path can never silently drop
    # the removals from a chain's batch.
    write_batch(a.out, a.chain, _council(a.chain), "ADR 0029 rollout — asset removals",
                f"removeBalanceAdapters {len(adapters)}, unregisterAsset {len(assets)}", txs)
    print(f"chain {a.chain}: {len(txs)} removal call(s) -> {a.out}" if txs else f"chain {a.chain}: nothing to remove (empty part written to {a.out})")
    return 0


_INT_RE = re.compile(r"^(0x[0-9a-fA-F]+|[0-9]+)$")
_HEX_RE = re.compile(r"^0x([0-9a-fA-F]{2})*$")


def _strict_address(v) -> str:
    """40-hex address, non-zero, and if mixed-case a valid EIP-55 checksum (a typo'd checksum is refused)."""
    a = str(v)
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", a) or int(a, 16) == 0:
        raise BatchError(f"not an address: {a!r}")
    if a[2:] != a[2:].lower() and a[2:] != a[2:].upper():
        from eth_utils import to_checksum_address
        if to_checksum_address(a) != a:
            raise BatchError(f"bad EIP-55 checksum: {a}")
    return a


def _abi_value(typ: str, v):
    if typ.endswith("[]"):
        items = json.loads(v) if isinstance(v, str) else v
        if not isinstance(items, list):
            raise BatchError(f"{typ} value is not a list")
        return [_abi_value(typ[:-2], x) for x in items]
    if typ == "address":
        return _strict_address(v)
    if typ.startswith(("uint", "int")):
        if not _INT_RE.fullmatch(str(v)):
            raise BatchError(f"{typ} value {str(v)[:30]!r} is not a plain decimal or 0x integer")
        return int(str(v), 0)
    if typ == "bool":
        if str(v).lower() not in ("true", "false"):
            raise BatchError(f"bool value {v!r} is not true/false")
        return str(v).lower() == "true"
    if typ == "bytes" or (typ.startswith("bytes") and typ[5:].isdigit()):
        h = str(v)
        if not _HEX_RE.fullmatch(h):
            raise BatchError(f"{typ} value {h[:20]!r} is not 0x-hex")
        if typ != "bytes" and len(h) != 2 + 2 * int(typ[5:]):
            raise BatchError(f"{typ} value has {(len(h) - 2) // 2} bytes, expected {typ[5:]}")
        return bytes.fromhex(h[2:])
    if typ == "string":
        return str(v)
    raise BatchError(f"unsupported input type {typ!r} (tuples are refused: encode them in the source repo)")


def encode_method_call(method: dict, values: dict) -> str:
    """Calldata for a Transaction-Builder `contractMethod` + `contractInputsValues` entry."""
    types = [i["type"] for i in method.get("inputs") or []]
    if any(t.startswith("tuple") for t in types):  # before the eth_abi import, so the refusal needs no dependency
        raise BatchError(f"{method.get('name')}: tuple inputs are refused")
    from eth_abi import encode
    from eth_utils import keccak
    sel = keccak(f"{method['name']}({','.join(types)})".encode())[:4]
    args = [_abi_value(i["type"], values[i["name"]]) for i in method.get("inputs") or []]
    return "0x" + (sel + encode(types, args)).hex()


def cmd_import(a) -> int:
    import hashlib
    council = _council(a.chain)
    raw = Path(a.input).read_bytes()
    b = json.loads(raw)
    if str(b.get("chainId")) != str(a.chain):
        raise BatchError(f"{a.input}: chainId {b.get('chainId')} != {a.chain}")
    safe = (b.get("meta") or {}).get("createdFromSafeAddress", "")
    if safe.lower() != council.lower():
        raise BatchError(f"{a.input}: made for {safe or '<none>'}, not the Council {council}")
    txs = []
    for t in b.get("transactions") or []:
        if int(t.get("operation", 0) or 0) != 0:
            raise BatchError(f"{a.input}: DELEGATECALL entry refused")
        if int(str(t.get("value", "0") or "0"), 0) != 0:
            raise BatchError(f"{a.input}: an entry sends value — refused")
        to = _strict_address(t.get("to", ""))
        data = t.get("data")
        if data is None:
            if not t.get("contractMethod"):
                raise BatchError(f"{a.input}: entry has neither data nor contractMethod")
            data = encode_method_call(t["contractMethod"], t.get("contractInputsValues") or {})
        if not _HEX_RE.fullmatch(str(data)) or len(str(data)) < 10:
            raise BatchError(f"{a.input}: entry to {to} has no function call (data {str(data)[:12]!r})")
        txs.append({"to": to, "value": "0", "data": data, "operation": 0})
    if not txs:
        raise BatchError(f"{a.input}: no transactions")
    sha = hashlib.sha256(raw).hexdigest()
    write_batch(a.out, a.chain, council, (b.get("meta") or {}).get("name") or "imported",
                f"imported from {Path(a.input).name} (sha256 {sha})", txs)
    print(f"chain {a.chain}: {len(txs)} call(s) imported from {Path(a.input).name} (sha256 {sha[:16]}…) -> {a.out}")
    return 0


def cmd_assemble(a) -> int:
    council = _council(a.chain)
    txs: list[dict] = []
    summary: list[str] = []
    for p in a.parts:
        if not Path(p).exists():
            raise BatchError(f"part {p} does not exist — refusing (every part must be present; an empty one is fine)")
        b = json.loads(Path(p).read_text())
        if not isinstance(b.get("transactions"), list):
            raise BatchError(f"{p}: no `transactions` list — refusing (an empty part is stamped with `[]`)")
        part_txs = b["transactions"]
        stamped_sum = (b.get("meta") or {}).get("checksum", "")
        # Checked even for an empty part: `write_batch` stamps `checksum([])`, so a part whose transactions were
        # cleared by hand no longer matches and cannot shrink the batch to an upgrade without its swaps.
        if not stamped_sum:
            raise BatchError(f"{p}: no meta.checksum — refusing an unstamped part")
        if stamped_sum.lower() != checksum(
                [{"to": t["to"], "value": str(t.get("value", "0")), "data": t["data"],
                  "operation": int(t.get("operation", 0))} for t in part_txs]).lower():
            raise BatchError(f"{p}: transactions do not match its meta.checksum (edited by hand?)")
        if str(b.get("chainId")) != str(a.chain):
            raise BatchError(f"{p}: chainId {b.get('chainId')} != {a.chain}")
        stamped = (b.get("meta") or {}).get("createdFromSafeAddress", "")
        if stamped.lower() != council.lower():
            raise BatchError(f"{p}: generated for {stamped or '<none>'}, not the Council {council}")
        for t in part_txs:
            if int(t.get("operation", 0)) != 0:
                raise BatchError(f"{p}: DELEGATECALL entry refused")
            txs.append({"to": t["to"], "value": str(t.get("value", "0")), "data": t["data"], "operation": 0})
        desc = (b.get("meta") or {}).get("description", "")
        prov = f" [{desc[desc.index('imported from'):]}]" if "imported from" in desc else ""
        summary.append(f"{len(part_txs)} from {Path(p).name}{prov}")
    if a.upgrade_impl:
        if not c.is_address(a.upgrade_impl):
            raise BatchError(f"--upgrade-impl {a.upgrade_impl!r} is not an address")
        txs.append({"to": ac.NAV_PROXY, "value": "0", "operation": 0,
                    "data": enc_upgrade_to_and_call(a.upgrade_impl)})
        summary.append(f"upgradeToAndCall({a.upgrade_impl})")
    if not txs:
        raise BatchError("empty batch")
    write_batch(a.out, a.chain, council, "ADR 0029 rollout",
                f"{len(txs)} call(s): " + "; ".join(summary), txs)
    print(f"chain {a.chain}: {len(txs)} call(s) -> {a.out}")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("removals")
    r.add_argument("--chain", type=int, required=True)
    r.add_argument("--rpc-url")
    r.add_argument("--rpc-env")
    r.add_argument("--expect-assets", default="")
    r.add_argument("--expect-adapters", default="")
    r.add_argument("--out", required=True)
    s = sub.add_parser("assemble")
    s.add_argument("--chain", type=int, required=True)
    s.add_argument("--parts", nargs="+", required=True)
    s.add_argument("--upgrade-impl")
    s.add_argument("--out", required=True)
    i = sub.add_parser("import")
    i.add_argument("--chain", type=int, required=True)
    i.add_argument("--in", dest="input", required=True)
    i.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    c.load_env()
    try:
        return {"removals": cmd_removals, "assemble": cmd_assemble, "import": cmd_import}[a.cmd](a)
    except (BatchError, ac.CensusError) as e:
        print(f"FAIL: {e}")
        return 1
    except Exception as e:  # noqa: BLE001 - an RPC error must not escape as a traceback carrying the URL
        print(f"FAIL: {type(e).__name__}: {ac._safe(e, 300)}")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
