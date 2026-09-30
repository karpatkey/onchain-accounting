#!/usr/bin/env python3
"""Read-only on-chain gates for the PR #338 in-place migration — one command per chain per phase.

`forge script` bodies run as local simulation, so no script can prove its own broadcast landed. These
gates do, from chain state, and exit non-zero on the first thing that is not exactly as planned. They
write nothing and send nothing.

  council <id>  before Phase 4 (and in preflight): the chain's Council Safe has code on every endpoint and
                the same owners + threshold as the chain-1 Council.
  phase1  <id>  after 01_2 (+ 04 on asset chains), BEFORE the upgrade: the new implementation and both
                pinned libraries have code, the implementation is not the pre-upgrade one, and every
                enabled meta/wallet key in the record has code (meta keys at a NEW address).
  upgrade <id>  after `upgradeToAndCall`: the ERC-1967 slot equals the recorded new implementation, read
                on EVERY configured endpoint that answers (two agreeing is the bar; one is flagged).
                Run it BEFORE generating a MANAGER batch and again BEFORE executing it.
  swap    <id>  after the swap batch AND the wallet-adds batch: for every meta key that was LIVE pre-swap
                (registered in the pre snapshot) OLD is deregistered with an empty set, NEW is registered
                with the same set size, and every NEW coordinate's claimant is NEW; keys NOT live pre-swap
                (pre-provisioned) must not have become registered; every wallet adapter is registered,
                each coordinate is claimed by it and no longer default-armed; and no registered adapter
                outside the record still carries a meta set (L-2).
  roles   <id>  after Phase 4: timelock holds ADMIN+MANAGER; deployer and ops Safe hold neither; the
                Council holds both iff --council-retains; plus a holder census rebuilt from the proxy's
                RoleGranted/RoleRevoked logs (the NAV is not AccessControlEnumerable), every survivor
                confirmed with hasRole, and any holder outside {timelock, Council} fails the gate.

usage:
  pr338_check.py council <id> [--rpc-url URL]
  pr338_check.py phase1  <id> [--rpc-url URL] [--pre DIR]
  pr338_check.py upgrade <id> [--rpc-url URL]
  pr338_check.py swap    <id> [--rpc-url URL] [--pre DIR] [--pre-swap FILE]
  pr338_check.py roles   <id> --ops-safe 0x… [--council-retains] [--rpc-url URL] [--from-block N] [--log-chunk N]

`--rpc-url` pins one endpoint (a fork); otherwise every endpoint chainlib knows for the chain is tried.
URLs are never printed.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

import chainlib as c

IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
PRE_UPGRADE_IMPL = "0x40e4134849308d53F85A8B685324E2189b13ff7D"
CLAIMANT_SLOT = 109
ADMIN = "0x" + "0" * 64
LIB_PINS_SOL = c.REPO / "script/utils/LibraryPins.sol"
META_CFG_DIR = c.CONTRACTS_CONFIG_DIR / "meta-balance-adapters"
NAV_META_CFG_DIR = c.NAV_CONFIG_DIR / "meta-balance-adapters"
ZERO = "0x" + "0" * 40


class Fail(RuntimeError):
    pass


# --- plumbing -------------------------------------------------------------------------------------------

def cast(*args: str) -> str:
    r = subprocess.run(["cast", *args, "--rpc-timeout", "300"] if args[0] in ("call", "storage", "code", "logs",
                       "block-number", "chain-id") else ["cast", *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise Fail(f"cast {args[0]} failed: {(r.stderr or r.stdout).strip()[-300:]}")
    return r.stdout.strip()


def endpoints(cid: int, pinned: str | None) -> list[tuple[str, str]]:
    if pinned:
        return [(pinned, "pinned --rpc-url")]
    out = []
    for url, note in c.rpc_candidates(cid):
        try:
            c.rpc(url, "eth_blockNumber", [], retries=2, timeout=45)
            out.append((url, note))
        except Exception:  # noqa: BLE001 — a dead endpoint is simply not counted
            pass
    if not out:
        raise Fail(f"no working endpoint for chain {cid}")
    return out


def has_code(url: str, a: str) -> bool:
    return cast("code", a, "--rpc-url", url) not in ("0x", "")


def slot_addr(url: str, a: str, slot: str) -> str:
    """Lower-cased: `cast parse-bytes32-address` checksums, and every comparison here is on lower-case."""
    return cast("parse-bytes32-address", cast("storage", a, slot, "--rpc-url", url)).lower()


def call(url: str, to: str, sig: str, *args: str) -> str:
    return cast("call", to, sig, *args, "--rpc-url", url)


def reg(url: str, nav: str, a: str) -> bool:
    return call(url, nav, "isAdapterRegistered(address)(bool)", a) == "true"


def instances(url: str, nav: str, a: str) -> list[str]:
    return [x.lower() for x in re.findall(r"0x[0-9a-fA-F]{64}", call(url, nav, "getMetaInstances(address)(bytes32[])", a))]


def claimant(url: str, nav: str, coord: str) -> str:
    key = cast("keccak", cast("abi-encode", "f(bytes32,uint256)", coord, str(CLAIMANT_SLOT)))
    return slot_addr(url, nav, key)


def has_role(url: str, nav: str, role: str, who: str) -> bool:
    return call(url, nav, "hasRole(bytes32,address)(bool)", role, who) == "true"


def lib_pins() -> dict[str, str]:
    src = LIB_PINS_SOL.read_text()
    pins = dict(re.findall(r"address internal constant (\w+) = (0x[0-9a-fA-F]{40});", src))
    for k in ("PRICE_FEED_LIB", "NAV_REGISTRY_LIB"):
        if k not in pins:
            raise Fail(f"{LIB_PINS_SOL}: {k} not found")
    return pins


def enabled_keys(cid: int) -> tuple[list[str], list[str]]:
    p = META_CFG_DIR / f"{cid}.json"
    if not p.exists():
        return [], []
    cfg = json.loads(p.read_text())
    keys = [k for k, v in cfg.items() if not k.startswith("$") and isinstance(v, dict) and v.get("enabled")]
    return [k for k in keys if "Wallet" not in k], [k for k in keys if "Wallet" in k]


class Gate:
    def __init__(self) -> None:
        self.failed = 0
        self.passed = 0

    def check(self, ok: bool, what: str) -> None:
        if ok:
            self.passed += 1
            print(f"  PASS  {what}")
        else:
            self.failed += 1
            print(f"  FAIL  {what}")

    def done(self, label: str) -> int:
        print(f"{label}: {self.passed} pass, {self.failed} fail -> {'OK' if not self.failed else 'GATE FAILED'}")
        return 1 if self.failed else 0


# --- gates ----------------------------------------------------------------------------------------------

def gate_phase1(cid: int, url: str, pre_dir: Path) -> int:
    g, rec = Gate(), c.deployment(cid)
    h9(g, cid, url, rec["NAVCalculatorProxy"], pre_dir)
    impl = rec.get("NAVCalculatorImplementation") or ""
    g.check(c.is_address(impl) and impl.lower() != PRE_UPGRADE_IMPL.lower(),
            f"record impl {impl} is set and is not the pre-upgrade impl")
    g.check(c.is_address(impl) and has_code(url, impl), "new implementation has code")
    for name, a in lib_pins().items():
        g.check(has_code(url, a), f"{name} {a} has code")
    meta, wallet = enabled_keys(cid)
    pre_swap = c.DEPLOY_DIR / f"{cid}.pre-swap.json"
    old = (json.loads(pre_swap.read_text()).get("balanceAdapters") or {}) if pre_swap.exists() else {}
    if meta and not old:
        g.check(False, f"{pre_swap.name} exists (snapshot_and_clear_meta --apply ran)")
    for k in meta + wallet:
        a = (rec.get("balanceAdapters") or {}).get(k) or ""
        g.check(c.is_address(a) and has_code(url, a), f"{k}: recorded {a or '<blank>'} has code")
        if k in meta and old.get(k):
            g.check(a.lower() != old[k].lower(), f"{k}: at a NEW address (old {old[k]})")
    return g.done(f"phase1 chain {cid}")


def gate_upgrade(cid: int, eps: list[tuple[str, str]], pinned: bool, pre_dir: Path) -> int:
    g, rec = Gate(), c.deployment(cid)
    nav, impl = rec["NAVCalculatorProxy"], (rec.get("NAVCalculatorImplementation") or "").lower()
    for url, note in eps:
        got = slot_addr(url, nav, IMPL_SLOT).lower()
        g.check(got == impl, f"ERC-1967 impl == record ({note}): {got}")
    if not pinned:
        g.check(len(eps) >= 2, f"impl slot read on >=2 independent endpoints ({len(eps)} answered) — if only one "
                               f"exists, confirm by hand on a second RPC and re-run with --rpc-url to pin it")
    h9(g, cid, eps[0][0], nav, pre_dir)
    return g.done(f"upgrade chain {cid}")


def h9(g: Gate, cid: int, url: str, nav: str, pre_dir: Path) -> None:
    """H9: a chain with NO meta key live pre-swap gets no swap, so it must carry no meta set at all."""
    meta, _ = enabled_keys(cid)
    pre_p = pre_dir / f"{cid}.json"
    pre_keys = {x.get("configKey") for x in json.loads(pre_p.read_text()).get("adapters", [])} if pre_p.exists() else set()
    if any(k in pre_keys for k in meta):
        return  # a swap chain: the swap gate owns its meta sets
    carrying = [a for a in re.findall(r"0x[0-9a-fA-F]{40}", call(url, nav, "getAllAdapters()(address[])"))
                if instances(url, nav, a)]
    g.check(not carrying, "no-swap chain (H9): no registered adapter carries a meta set"
            + (f" ({carrying})" if carrying else ""))


def gate_swap(cid: int, url: str, pre_dir: Path, pre_swap_path: Path) -> int:
    g, rec = Gate(), c.deployment(cid)
    nav, adapters = rec["NAVCalculatorProxy"], rec.get("balanceAdapters") or {}
    g.check(slot_addr(url, nav, IMPL_SLOT).lower() == (rec.get("NAVCalculatorImplementation") or "").lower(),
            "upgrade landed")
    pre = json.loads((pre_dir / f"{cid}.json").read_text())
    pre_n = {x["address"].lower(): int(x.get("metaInstanceCount", 0)) for x in pre.get("adapters", [])}
    # The pre snapshot names every REGISTERED adapter by its config key — an OLD-address source independent of
    # `.pre-swap.json`, so a lost/regenerated snapshot file cannot make a live adapter look "not live".
    pre_by_key = {x["configKey"]: x["address"].lower() for x in pre.get("adapters", []) if x.get("configKey")}
    meta, wallet = enabled_keys(cid)
    old = (json.loads(pre_swap_path.read_text()).get("balanceAdapters") or {}) if pre_swap_path.exists() else {}
    if meta and not old:
        g.check(False, f"{pre_swap_path} readable (OLD addresses)")
    expected = {a.lower() for a in adapters.values() if isinstance(a, str) and c.is_address(a)}
    for k in meta:
        o, n = (old.get(k) or "").lower(), (adapters.get(k) or "").lower()
        if k in pre_by_key:
            g.check(o == pre_by_key[k], f"{k}: .pre-swap.json OLD agrees with the pre snapshot ({pre_by_key[k]})")
            o = pre_by_key[k]
        if not o or o not in pre_n:
            # Not registered pre-swap (pre-provisioned): plan() skips it, so its NEW twin must stay unregistered.
            g.check(not (n and reg(url, nav, n)), f"{k}: not live pre-swap -> NEW not registered either")
            continue
        g.check(not reg(url, nav, o), f"{k}: OLD {o} deregistered")
        g.check(not instances(url, nav, o), f"{k}: OLD set cleared")
        g.check(reg(url, nav, n), f"{k}: NEW {n} registered")
        inst = instances(url, nav, n)
        g.check(len(inst) == pre_n[o], f"{k}: set carried ({pre_n[o]} -> {len(inst)})")
        bad = [x for x in inst if claimant(url, nav, x) != n]
        g.check(not bad, f"{k}: every coordinate claimed by NEW" + (f" (not: {bad[:3]})" if bad else ""))
    default = adapters.get("ERC20Default") or ""
    if wallet and not c.is_address(default):
        raise Fail("record has no ERC20Default address")
    ncfg_p = NAV_META_CFG_DIR / f"{cid}.json"
    ncfg = json.loads(ncfg_p.read_text()) if ncfg_p.exists() else {}
    for k in wallet:
        a = (adapters.get(k) or "").lower()
        g.check(bool(a) and reg(url, nav, a), f"wallet {k} registered")
        for tok in (ncfg.get(k) or {}).get("instances") or []:
            coord = "0x" + "0" * 24 + tok[2:].lower()
            g.check(claimant(url, nav, coord) == a and
                    call(url, default, "isSupportedByDefault(address)(bool)", tok) == "false",
                    f"  {k} {tok}: claimed by the wallet adapter, not default-armed")
    live_pre = [pre_by_key[k] for k in meta if k in pre_by_key]
    still = [a for a in live_pre if reg(url, nav, a)]
    g.check(not still, f"every meta adapter registered pre-swap ({len(live_pre)}) is now deregistered"
            + (f" (still: {still})" if still else ""))
    stray = []
    for a in re.findall(r"0x[0-9a-fA-F]{40}", call(url, nav, "getAllAdapters()(address[])")):
        if a.lower() not in expected and instances(url, nav, a):
            stray.append(a)
    g.check(not stray, "no registered adapter outside the record carries a meta set" + (f": {stray}" if stray else ""))
    return g.done(f"swap chain {cid}")


def council_fingerprint(url: str, safe: str) -> tuple[str, str]:
    owners = sorted(x.lower() for x in re.findall(r"0x[0-9a-fA-F]{40}", call(url, safe, "getOwners()(address[])")))
    return ",".join(owners), call(url, safe, "getThreshold()(uint256)").split()[0]


def gate_council(cid: int, eps: list[tuple[str, str]], pinned: bool) -> int:
    """The Council Safe must be THE Council on this chain before it is handed ADMIN: code on every endpoint,
    and the same owner set + threshold as the chain-1 Council (the reference)."""
    g = Gate()
    council = c.chain_config(cid)["addresses"]["securityCouncil"]
    ref_url = endpoints(1, None)[0][0]
    ref = council_fingerprint(ref_url, c.chain_config(1)["addresses"]["securityCouncil"])
    for url, note in eps:
        g.check(has_code(url, council), f"Council {council} has code ({note})")
        if has_code(url, council):
            fp = council_fingerprint(url, council)
            g.check(fp == ref, f"Council owners+threshold == chain-1 Council ({note}): threshold {fp[1]}, "
                               f"{len(fp[0].split(','))} owners")
    if not pinned:
        g.check(len(eps) >= 2, f"Council checked on >=2 independent endpoints ({len(eps)} answered)")
    return g.done(f"council chain {cid}")


def role_holders(url: str, nav: str, from_block: int, step: int = 100_000) -> set[str]:
    """Every account ever granted a role on the proxy, from its RoleGranted logs.

    Bounded chunks (providers cap eth_getLogs ranges, and a fork proxies old ranges upstream), halved on error.
    """
    head = int(cast("block-number", "--rpc-url", url))
    seen: set[str] = set()
    stack = [(lo, min(lo + step - 1, head)) for lo in range(from_block, head + 1, step)][::-1]
    while stack:
        lo, hi = stack.pop()
        try:
            out = cast("logs", "--address", nav, "--from-block", str(lo), "--to-block", str(hi), "--json",
                       "RoleGranted(bytes32,address,address)", "--rpc-url", url)
        except Fail:
            if hi - lo < 1000:
                raise
            mid = (lo + hi) // 2
            stack += [(lo, mid), (mid + 1, hi)]
            continue
        for log in json.loads(out or "[]"):
            seen.add("0x" + log["topics"][2][-40:].lower())
    return seen


def deploy_block(url: str, a: str) -> int:
    lo, hi = 0, int(cast("block-number", "--rpc-url", url))
    while lo < hi:  # first block at which `a` has code (archive reads)
        mid = (lo + hi) // 2
        if cast("code", a, "--block", str(mid), "--rpc-url", url) in ("0x", ""):
            lo = mid + 1
        else:
            hi = mid
    return lo


def gate_roles(cid: int, url: str, ops: str, retains: bool, from_block: int | None, log_chunk: int = 100_000) -> int:
    g, rec = Gate(), c.deployment(cid)
    cfg = c.chain_config(cid)
    nav, tl = rec["NAVCalculatorProxy"], rec.get("TimelockController") or ""
    council, deployer = cfg["addresses"]["securityCouncil"], cfg["addresses"]["admin"]
    manager = cast("keccak", "MANAGER")
    g.check(has_code(url, council), f"Council {council} has code")
    g.check(c.is_address(tl) and has_code(url, tl), f"timelock {tl or '<unrecorded>'} recorded + has code")
    if not c.is_address(tl):
        return g.done(f"roles chain {cid}")
    for role, rn in ((ADMIN, "ADMIN"), (manager, "MANAGER")):
        g.check(has_role(url, nav, role, tl), f"timelock holds {rn}")
        g.check(not has_role(url, nav, role, deployer), f"deployer holds NO {rn}")
        g.check(not has_role(url, nav, role, ops), f"ops Safe holds NO {rn}")
        g.check(has_role(url, nav, role, council) == retains, f"Council {rn} == {retains} (SAFE_RETAINS_ROLES)")
    fb = from_block if from_block is not None else deploy_block(url, nav)
    # AssetKindRegistry holds MANAGER on the NAV BY DESIGN (it forwards registerAsset), and every one of its
    # mutators re-checks `NAV.hasRole(MANAGER, msg.sender)`, so it confers no authority of its own. Found by
    # the first live census on chain 1 (2026-09-29): the only non-deployer holder today.
    akr = (rec.get("AssetKindRegistry") or "").lower()
    allowed = {tl.lower()} | ({council.lower()} if retains else set())
    survivors = {a for a in role_holders(url, nav, fb, log_chunk)
                 if has_role(url, nav, ADMIN, a) or has_role(url, nav, manager, a)}
    if akr in survivors:
        g.check(not has_role(url, nav, ADMIN, akr), f"AssetKindRegistry {akr} holds MANAGER only (never ADMIN)")
        survivors.discard(akr)
    g.check(survivors == allowed, f"role-holder census (logs from block {fb} + hasRole), besides the registry: "
                                  f"{sorted(survivors)}")
    return g.done(f"roles chain {cid}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("gate", choices=["council", "phase1", "upgrade", "swap", "roles"])
    ap.add_argument("chain", type=int)
    ap.add_argument("--rpc-url", default=None)
    ap.add_argument("--pre", default=str(c.SNAPSHOT_DIR / "pre"))
    ap.add_argument("--pre-swap", default=None)
    ap.add_argument("--ops-safe", default=None)
    ap.add_argument("--council-retains", action="store_true")
    ap.add_argument("--from-block", type=int, default=None)
    # Some RPCs HANG (rather than error) on long eth_getLogs ranges — Berachain above ~1k blocks — so the
    # census can page in smaller chunks. Performance only: every block in the range is still read.
    ap.add_argument("--log-chunk", type=int, default=100_000)
    a = ap.parse_args()
    eps = endpoints(a.chain, a.rpc_url)
    url = eps[0][0]
    if int(cast("chain-id", "--rpc-url", url)) != a.chain:
        raise Fail(f"endpoint is not chain {a.chain}")
    pinned = a.rpc_url is not None
    if a.gate == "council":
        return gate_council(a.chain, eps, pinned)
    if a.gate == "phase1":
        return gate_phase1(a.chain, url, Path(a.pre))
    if a.gate == "upgrade":
        return gate_upgrade(a.chain, eps, pinned, Path(a.pre))
    if a.gate == "swap":
        ps = Path(a.pre_swap) if a.pre_swap else c.DEPLOY_DIR / f"{a.chain}.pre-swap.json"
        return gate_swap(a.chain, url, Path(a.pre), ps)
    if not a.ops_safe:
        ap.error("roles needs --ops-safe")
    return gate_roles(a.chain, url, a.ops_safe, a.council_retains, a.from_block, a.log_chunk)


if __name__ == "__main__":
    c.load_env()
    try:
        sys.exit(main())
    except Fail as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(2)
