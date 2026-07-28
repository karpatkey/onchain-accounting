#!/usr/bin/env python3
"""Assert the runbook's per-step post-conditions, because the deploy scripts' exit codes do not.

WHY THIS EXISTS
---------------
`REDEPLOY_RUNBOOK.md` states a post-condition for every step of the seven-step sequence and warns, in
section 3, that **exit status 0 does not mean work happened**. Several scripts return cleanly when a
precondition is unmet — `03`/`04` print `Already deployed at:` and skip, `06` does
`if (deployed == address(0)) continue;` (06_Configure.s.sol:113), `RegisterAssets` prints
`NAVCalculator not deployed for this chain` and returns, and `01_2`/`02_2` only *log* their addresses
unless `PERSIST_DEPLOYMENTS=1` (BaseDeployScript.sol:33). In the fork rehearsal, `RegisterAssets`,
`04` and `06` all reported success having done nothing at all, purely because `01_2` had reverted
upstream.

So the post-conditions are the only real signal — and they were 24 chains' worth of hand-run
`cast call`s, which is where a silent miss on chain 19 of 24 was going to land. This runs them.

WHAT IT DELIBERATELY DOES NOT DO
--------------------------------
It does not check that on-chain code matches the current build — that is `bytecode_audit.py`, which
needs a clean full-project `forge build` to index `out/`. This tool reads only the deployment records
and the chains, so it stays usable *between* deploy steps without a rebuild. The two are
complementary: this one answers "is the shape right", the audit answers "is the code right".

USAGE
-----
  python3 verify_step.py 1.2                  # one step, the whole redeploy scope
  python3 verify_step.py 1.3 1 42161          # one step, named chains
  python3 verify_step.py all 1                # every step, one chain
  python3 verify_step.py 1.7 --json out.json
  python3 verify_step.py all 1 --rpc-url http://127.0.0.1:8545   # against the fork rehearsal

Exit status is 0 only when every check on every chain passed. `--allow-partial` downgrades an
unreachable chain to a warning; by default it is a failure, because "found no problem" is worthless
on a chain that was never read.
"""
from __future__ import annotations

import argparse
import json
import sys
from concurrent.futures import ThreadPoolExecutor

from eth_abi import decode as abi_decode
from eth_abi import encode as abi_encode
from eth_utils import keccak

import chainlib as c
import preflight_config as pc
import reset_deployment_records as rd

STEPS = ["1.1", "1.2", "1.3", "1.4", "1.5", "1.6", "1.7"]
STEP_TITLE = {
    "1.1": "deployment record cleared",
    "1.2": "01_2 — libraries + NAV implementation",
    "1.3": "02_2 — new proxy + ERC20Default",
    "1.4": "03 — custom price feeds",
    "1.5": "RegisterAssets — assets on the new NAV",
    "1.6": "04 — balance adapters + assistants",
    "1.7": "06 — registration + meta-instance reconcile",
}

IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
DEFAULT_ADMIN_ROLE = bytes(32)
MANAGER_ROLE = keccak(text="MANAGER")

# The three assisted adapters and their paired assistants. `04._deployAssistantsIfEnabled`
# (04_DeployBalanceAdapters.s.sol:251) deploys an assistant iff its adapter's address is already in
# the record, so the expectation is record-driven, not config-driven.
ASSISTED_PAIRS = [
    ("EtherFiWithdrawalQueueAssisted", "EtherFiWithdrawalQueueAssistant"),
    ("NexusMutualStakingPoolsAssisted", "NexusMutualStakingPoolsAssistant"),
    ("StakeWiseV3ExitQueueAssisted", "StakeWiseV3ExitQueueAssistant"),
]

LIB_KEYS = {"PriceFeedLib": "PRICE_FEED_LIB", "NavRegistryLib": "NAV_REGISTRY_LIB"}


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def sel(sig: str) -> str:
    return "0x" + keccak(text=sig)[:4].hex()


def addr_arg(a: str) -> str:
    return abi_encode(["address"], [a.lower()]).hex()


def lower(v) -> str:
    return v.lower() if isinstance(v, str) else v


def widen(a: str) -> str:
    """An address instance coordinate as the bytes32 the NAV stores (left-zero-padded)."""
    return "0x" + "0" * 24 + a.lower()[2:]


def populated(d: dict) -> dict:
    """The subset of a record section that actually holds an address."""
    return {k: v for k, v in (d or {}).items() if c.is_address(v)}


def read_pins() -> tuple[dict[str, str], list[str]]:
    """Both canonical copies of the library pins: LibraryPins.sol and foundry.toml [libraries].

    Read-only. A pin regeneration is PR #185's alone; this only reports disagreement, which is the
    exact failure mode that produced a stale-from-birth pin in `6b7e4851`.
    """
    import re
    problems: list[str] = []
    sol = (c.REPO / "script/utils/LibraryPins.sol").read_text()
    pins: dict[str, str] = {}
    for const, name in (("PRICE_FEED_LIB", "PriceFeedLib"), ("NAV_REGISTRY_LIB", "NAVRegistryLib")):
        m = re.search(rf"{const}\s*=\s*(0x[0-9a-fA-F]{{40}})", sol)
        if m:
            pins[name] = m.group(1)
        else:
            problems.append(f"LibraryPins.sol: could not read {const}")

    toml = (c.REPO / "foundry.toml").read_text()
    # Every profile's entries at once, then require one distinct address per library. `[profile.dev]`
    # deliberately sets `libraries = []` (auto-deploy on dev forks), which contributes nothing here.
    found: dict[str, set[str]] = {}
    for m in re.finditer(r'"src/[^"]+:([A-Za-z0-9_]+):(0x[0-9a-fA-F]{40})"', toml):
        found.setdefault(m.group(1), set()).add(m.group(2).lower())
    for name, pin in pins.items():
        got = found.get(name, set())
        if not got:
            problems.append(f"foundry.toml [libraries] has no entry for {name}")
        elif len(got) > 1:
            problems.append(f"foundry.toml pins {name} to {len(got)} different addresses: {sorted(got)}")
        elif pin.lower() not in got:
            problems.append(f"{name}: LibraryPins.sol says {pin} but foundry.toml says "
                            f"{sorted(got)[0]} — the two canonical copies disagree")
    return pins, problems


def baseline() -> dict[int, dict]:
    """The OLD stack, per chain, from the committed pre-deploy snapshot index.

    Used to prove the new addresses actually moved. Reading it from the snapshot rather than
    hard-coding `0x80eD5cc6…` keeps this correct if the snapshot is ever recaptured.
    """
    idx = c.SNAPSHOT_DIR / "pre" / "index.json"
    if not idx.is_file():
        return {}
    return {int(e["chainId"]): e for e in json.loads(idx.read_text()).get("chains", [])
            if e.get("chainId")}


def archived(tag: str, chain_id: int) -> dict | None:
    p = rd.ARCHIVE_DIR / tag / f"{chain_id}.json"
    return json.loads(p.read_text()) if p.is_file() else None


class Chk:
    """Accumulates findings for one chain. `ok` is the whole point: no finding means it passed."""

    def __init__(self, chain_id: int, name: str):
        self.chain_id = chain_id
        self.name = name
        self.fail: list[str] = []
        self.warn: list[str] = []
        self.info: list[str] = []
        self.unreachable: str | None = None

    def require(self, cond, msg: str) -> bool:
        if not cond:
            self.fail.append(msg)
        return bool(cond)

    def expect(self, cond, msg: str) -> bool:
        if not cond:
            self.warn.append(msg)
        return bool(cond)

    @property
    def ok(self) -> bool:
        return not self.fail and self.unreachable is None


# ---------------------------------------------------------------------------
# Per-step checks
# ---------------------------------------------------------------------------

def step_1_1(k: Chk, rec: dict, exp: dict, url, base, tag) -> None:
    """The record must be cleared, the bridge must NOT be, and a rollback must exist."""
    for key in rd.CLEAR_TOP:
        if key in rec:
            k.require(not c.is_address(rec[key]),
                      f"{key} is still populated ({rec[key]}) — 03/04 will skip-if-deployed and 06 "
                      f"will register the OLD contracts on the NEW proxy")
    for sec in rd.CLEAR_SECTIONS:
        still = populated(rec.get(sec))
        k.require(not still,
                  f"{sec} still holds {len(still)} address(es): {sorted(still)[:6]}"
                  f"{' …' if len(still) > 6 else ''}")

    # The archive is the only way back. reset_deployment_records.py --apply writes it before
    # clearing, so its absence means the clear was done some other way and there is no rollback.
    arch = archived(tag, k.chain_id)
    if k.require(arch is not None,
                 f"no rollback archive at archive/{tag}/{k.chain_id}.json — the pre-clear record was "
                 f"not captured, so there is nothing to restore"):
        k.require(c.is_address(arch.get("NAVCalculatorProxy")),
                  f"archive/{tag}/{k.chain_id}.json has no NAVCalculatorProxy — it is not a "
                  f"pre-clear record")

    # The bridge stack is explicitly out of scope for this redeploy.
    for key in ("BridgeEscrowImplementation", "BridgeEscrowProxy"):
        if arch and c.is_address(arch.get(key)) and not c.is_address(rec.get(key)):
            k.fail.append(f"{key} was cleared but the bridge is deferred — restore it from "
                          f"archive/{tag}/{k.chain_id}.json")


def step_1_2(k: Chk, rec: dict, exp: dict, url, base, tag) -> None:
    """Both libraries and the NAV implementation, at the pinned addresses, with code."""
    pins, pin_problems = read_pins()
    for p in pin_problems:
        k.fail.append(p)

    for key in ("PriceFeedLib", "NavRegistryLib", "NAVCalculatorImplementation"):
        if not k.require(c.is_address(rec.get(key)),
                         f"{key} is not in the record — either 01_2 did not run or it ran without "
                         f"PERSIST_DEPLOYMENTS=1 (BaseDeployScript.sol:33), which only logs"):
            continue
        if url and not code_at(url, rec[key]):
            k.fail.append(f"{key} {rec[key]} has NO CODE on chain {k.chain_id}")

    # Recorded library addresses must be the pins the implementation is linked against. A mismatch
    # means the NAV DELEGATECALLs a different address than the one that was deployed.
    for key, _const in LIB_KEYS.items():
        want = pins.get("PriceFeedLib" if key == "PriceFeedLib" else "NAVRegistryLib")
        got = rec.get(key)
        if want and c.is_address(got):
            k.require(lower(got) == lower(want),
                      f"{key} recorded as {got} but the pin is {want} — the impl is linked against "
                      f"the pin, so the deployed library is unreachable")

    # Proof the redeploy happened at all: the addresses must differ from the archived old ones.
    arch = archived(tag, k.chain_id)
    if arch:
        for key in ("PriceFeedLib", "NavRegistryLib", "NAVCalculatorImplementation"):
            if c.is_address(rec.get(key)) and lower(rec[key]) == lower(arch.get(key)):
                k.warn.append(f"{key} is unchanged from the pre-clear record ({rec[key]}) — expected "
                              f"if the pin regen genuinely did not move it, otherwise 01_2 no-op'd")


def step_1_3(k: Chk, rec: dict, exp: dict, url, base, tag) -> None:
    """The new proxy: fresh address, correct impl, version 1, roles on the deployer, fresh ERC20Default."""
    proxy = rec.get("NAVCalculatorProxy")
    if not k.require(c.is_address(proxy),
                     "NAVCalculatorProxy is not in the record — 02_2 did not run, or ran without "
                     "PERSIST_DEPLOYMENTS=1"):
        return
    old = base.get(k.chain_id, {})
    k.require(lower(proxy) != lower(old.get("proxy")),
              f"NAVCalculatorProxy {proxy} is the SAME as the pre-deploy proxy — DeploySalts.NAV_PROXY "
              f"was not bumped, so 02_2 skipped the deploy (runbook 0.2)")
    if not url:
        return
    if not k.require(code_at(url, proxy), f"proxy {proxy} has NO CODE on chain {k.chain_id}"):
        return

    slot = c.rpc(url, "eth_getStorageAt", [proxy, IMPL_SLOT, "latest"])
    impl = "0x" + slot[-40:]
    k.require(lower(impl) == lower(rec.get("NAVCalculatorImplementation")),
              f"proxy's EIP-1967 implementation is {impl} but the record says "
              f"{rec.get('NAVCalculatorImplementation')}")

    ver = call1(url, proxy, "version()", "uint64")
    k.require(ver == 1, f"version() is {ver}, expected 1 — initialize() did not run as expected")

    erc20 = call1(url, proxy, "erc20DefaultBalanceAdapter()", "address")
    recorded = (rec.get("balanceAdapters") or {}).get("ERC20Default")
    k.require(c.is_address(erc20) and lower(erc20) != lower(old.get("erc20Default")),
              f"erc20DefaultBalanceAdapter() is {erc20}, the SAME as the pre-deploy one — a fresh "
              f"ERC20Default is minted inside initialize() (NAVCalculator.sol:77), so this means the "
              f"proxy is the old one")
    k.require(lower(erc20) == lower(recorded),
              f"erc20DefaultBalanceAdapter() is {erc20} but the record says {recorded} — 02_2 did not "
              f"persist it (PERSIST_DEPLOYMENTS=1 gates that write too)")

    # Role layout. Step 07 is deliberately EXCLUDED from this deploy, so the deployer keeps admin and
    # the security council must NOT have it — asserting both directions catches an accidental handoff.
    addrs = c.chain_config(k.chain_id).get("addresses", {}) or {}
    for who in ("admin", "manager"):
        a = addrs.get(who)
        if not c.is_address(a):
            continue
        for rname, rval in (("DEFAULT_ADMIN_ROLE", DEFAULT_ADMIN_ROLE), ("MANAGER", MANAGER_ROLE)):
            has = has_role(url, proxy, rval, a)
            k.require(has, f"addresses.{who} ({a}) does NOT hold {rname} on the new proxy")
    sc = addrs.get("securityCouncil")
    if c.is_address(sc) and lower(sc) not in {lower(addrs.get("admin")), lower(addrs.get("manager"))}:
        k.expect(not has_role(url, proxy, DEFAULT_ADMIN_ROLE, sc),
                 f"securityCouncil ({sc}) holds DEFAULT_ADMIN_ROLE — step 07 is excluded from this "
                 f"deploy, so this was not supposed to happen yet")


def step_1_4(k: Chk, rec: dict, exp: dict, url, base, tag) -> None:
    """Every configured custom feed deployed, with code, pointing at the NEW proxy."""
    feeds = populated(rec.get("customPriceFeeds"))
    k.require(len(feeds) == exp["customFeeds"],
              f"{len(feeds)} custom price feed(s) in the record, config expects "
              f"{exp['customFeeds']}")
    if not url or not feeds:
        return
    proxy = rec.get("NAVCalculatorProxy")
    names = sorted(feeds)
    # One batched round-trip for getCode + NAV() over every feed.
    codes = c.rpc_batch(url, [("eth_getCode", [feeds[n], "latest"]) for n in names])
    navs = c.rpc_batch(url, [("eth_call", [{"to": feeds[n], "data": sel("NAV()")}, "latest"])
                             for n in names])
    for n, code, nav in zip(names, codes, navs):
        if isinstance(code, Exception) or code in (None, "0x", ""):
            k.fail.append(f"customPriceFeeds.{n} {feeds[n]} has NO CODE")
            continue
        if isinstance(nav, Exception) or not isinstance(nav, str) or len(nav) < 66:
            k.warn.append(f"customPriceFeeds.{n}: NAV() unreadable ({nav}) — not every feed exposes "
                          f"it; bytecode_audit.py is the authority here")
            continue
        ptr = "0x" + nav[-40:]
        k.require(lower(ptr) == lower(proxy),
                  f"customPriceFeeds.{n} {feeds[n]} points at NAV {ptr}, not the new proxy {proxy} — "
                  f"the NAV address is an immutable (ADR 0019), so it must be redeployed")


def step_1_5(k: Chk, rec: dict, exp: dict, url, base, tag) -> None:
    """The configured asset set registered on the new NAV — by identity, not just by count."""
    proxy = rec.get("NAVCalculatorProxy")
    if not url or not k.require(c.is_address(proxy), "no NAVCalculatorProxy in the record"):
        return
    n = call1(url, proxy, "getAssetCount()", "uint256")
    k.require(n == exp["assets"],
              f"getAssetCount() is {n}, config expects {exp['assets']} — RegisterAssets skips a "
              f"Custom feed it cannot resolve with `[skip] primary feed unresolved`, so run 03 first")

    want = {lower(e.get("address")) for e in pc.cfg("assets-and-price-feeds", k.chain_id).values()
            if isinstance(e, dict) and c.is_address(e.get("address"))}
    raw = c.eth_call(url, proxy, sel("getRegisteredAssets()"))
    got = {lower(a[0]) for a in abi_decode([f"{pc_asset()}[]"], bytes.fromhex(raw[2:]))[0]}
    missing, extra = sorted(want - got), sorted(got - want)
    k.require(not missing, f"{len(missing)} configured asset(s) NOT registered: {missing[:6]}")
    k.expect(not extra, f"{len(extra)} registered asset(s) are not in config: {extra[:6]}")


def step_1_6(k: Chk, rec: dict, exp: dict, url, base, tag) -> None:
    """Every adapter deployed, plus an assistant correctly paired to each assisted adapter."""
    adapters = populated(rec.get("balanceAdapters"))
    # +1 for ERC20Default, which every chain gets from initialize() rather than from config.
    want = exp["plainAdapters"] + exp["metaAdapters"] + 1
    k.require(len(adapters) == want,
              f"{len(adapters)} balance adapter(s) in the record, expected {want} "
              f"({exp['plainAdapters']} plain + {exp['metaAdapters']} meta + ERC20Default)")
    k.require("ERC20Default" in adapters, "balanceAdapters.ERC20Default is missing from the record")

    if url and adapters:
        names = sorted(adapters)
        codes = c.rpc_batch(url, [("eth_getCode", [adapters[n], "latest"]) for n in names])
        for n, code in zip(names, codes):
            if isinstance(code, Exception) or code in (None, "0x", ""):
                k.fail.append(f"balanceAdapters.{n} {adapters[n]} has NO CODE")

    for adapter_key, assistant_key in ASSISTED_PAIRS:
        adapter = adapters.get(adapter_key)
        assistant = rec.get(assistant_key)
        if not c.is_address(adapter):
            k.require(not c.is_address(assistant),
                      f"{assistant_key} is recorded but its adapter {adapter_key} is not — the "
                      f"assistant is an orphan by construction")
            continue
        if not k.require(c.is_address(assistant),
                         f"{adapter_key} is deployed but {assistant_key} is NOT — 04 skips an "
                         f"assistant whose key is already populated, so check 1.1 cleared it"):
            continue
        if not url:
            continue
        ptr = call1(url, assistant, "ADAPTER()", "address")
        k.require(c.is_address(ptr) and lower(ptr) == lower(adapter),
                  f"{assistant_key} {assistant} has ADAPTER() = {ptr}, but {adapter_key} is "
                  f"{adapter} — feeding this assistant writes into a cache the NAV never reads "
                  f"(the live PR #141 orphan failure)")


def step_1_7(k: Chk, rec: dict, exp: dict, url, base, tag) -> None:
    """Registration on the NAV, and meta-instance sets equal to config."""
    proxy = rec.get("NAVCalculatorProxy")
    if not url or not k.require(c.is_address(proxy), "no NAVCalculatorProxy in the record"):
        return
    adapters = populated(rec.get("balanceAdapters"))

    n = call1(url, proxy, "getAdapterCount()", "uint256")
    k.require(n == len(adapters),
              f"getAdapterCount() is {n} but {len(adapters)} adapter(s) are in the record — 06 does "
              f"`if (deployed == address(0)) continue;` (06_Configure.s.sol:113) and skips silently")

    raw = c.eth_call(url, proxy, sel("getAllAdapters()"))
    onchain = {lower(a) for a in abi_decode(["address[]"], bytes.fromhex(raw[2:]))[0]}
    recorded = {lower(v) for v in adapters.values()}
    unreg = sorted({key for key, v in adapters.items() if lower(v) not in onchain})
    k.require(not unreg, f"{len(unreg)} recorded adapter(s) NOT registered on the NAV: {unreg[:8]}")
    k.expect(not (onchain - recorded),
             f"{len(onchain - recorded)} adapter(s) registered on the NAV are not in the record: "
             f"{sorted(onchain - recorded)[:6]}")

    # Meta instances, per adapter, as sets. A count-only check passes when one instance is swapped
    # for another — and #172's operator note is precisely about a wrong instance (Aave V3 exposes two
    # DataProviders; registering both double-counts).
    meta_cfg = pc.cfg("meta-balance-adapters", k.chain_id)
    total = 0
    for name, entry in meta_cfg.items():
        if entry.get("enabled") is not True:
            continue
        want = {widen(a) for a in (entry.get("instances") or []) if c.is_address(a)}
        want |= {lower(b) for b in (entry.get("instancesRaw") or []) if pc.is_bytes32(b)}
        total += len(want)
        addr = adapters.get(name)
        if not c.is_address(addr):
            k.fail.append(f"meta adapter {name} is enabled in nav-config but has no deployed address")
            continue
        raw = c.eth_call(url, proxy, sel("getMetaInstances(address)") + addr_arg(addr))
        got = {"0x" + b.hex() for b in abi_decode(["bytes32[]"], bytes.fromhex(raw[2:]))[0]}
        missing, extra = sorted(want - got), sorted(got - want)
        k.require(not missing and not extra,
                  f"{name} meta instances differ from config: {len(missing)} missing "
                  f"{missing[:3]}, {len(extra)} unexpected {extra[:3]}")
    k.require(total == exp["metaInstances"],
              f"internal: summed configured instances {total} != preflight_config count "
              f"{exp['metaInstances']}")


CHECKS = {"1.1": step_1_1, "1.2": step_1_2, "1.3": step_1_3, "1.4": step_1_4,
          "1.5": step_1_5, "1.6": step_1_6, "1.7": step_1_7}

NEEDS_RPC = {"1.2", "1.3", "1.4", "1.5", "1.6", "1.7"}


# ---------------------------------------------------------------------------
# Chain plumbing
# ---------------------------------------------------------------------------

def pc_asset() -> str:
    """INAVCalculator.Asset — kept here so this tool does not import the snapshot module."""
    return "(address,string,uint8)"


def code_at(url: str, addr: str) -> bool:
    code = c.get_code(url, addr)
    return bool(code) and code != "0x"


def call1(url: str, to: str, sig: str, ret: str):
    raw = c.eth_call(url, to, sel(sig))
    return abi_decode([ret], bytes.fromhex(raw[2:]))[0]


def has_role(url: str, proxy: str, role: bytes, who: str) -> bool:
    data = sel("hasRole(bytes32,address)") + abi_encode(["bytes32", "address"],
                                                        [role, who.lower()]).hex()
    return int(c.eth_call(url, proxy, data), 16) == 1


def verify_chain(chain_id: int, steps: list[str], tag: str, base: dict,
                 rpc_override: str | None = None) -> Chk:
    name = c.chain_config(chain_id).get("name", "?")
    k = Chk(chain_id, name)
    rec = c.deployment(chain_id)
    if not rec:
        k.fail.append(f"no deployment record at script/config/deployments/{chain_id}.json")
        return k
    exp = pc.counts(chain_id)

    url = None
    if any(s in NEEDS_RPC for s in steps):
        if rpc_override:
            url, note, rejected = rpc_override, "--rpc-url", []
        else:
            url, note, rejected = c.probe_rpc(chain_id)
        if not url:
            k.unreachable = f"{note} | {' ; '.join(rejected)}"
            return k
        k.info.append(f"rpc: {note}")

    for s in steps:
        try:
            CHECKS[s](k, rec, exp, url, base, tag)
        except Exception as e:  # noqa: BLE001 — one broken check must not hide the others
            k.fail.append(f"step {s} check raised: {type(e).__name__}: {e}")
    return k


def cross_chain_identity(results: list[Chk], steps: list[str], chains: list[int]) -> list[str]:
    """CREATE2 puts the libraries, the implementation and the proxy at the SAME address everywhere.

    A chain that disagrees was deployed from a different build or a different submodule set, which no
    per-chain check can see — it is only visible by comparing chains, so it lives outside `Chk`.
    """
    out: list[str] = []
    keys = []
    if "1.2" in steps:
        keys += ["PriceFeedLib", "NavRegistryLib", "NAVCalculatorImplementation"]
    if "1.3" in steps:
        keys += ["NAVCalculatorProxy"]
    reachable = [r.chain_id for r in results if r.unreachable is None]
    for key in keys:
        by_addr: dict[str, list[int]] = {}
        for cid in reachable:
            v = c.deployment(cid).get(key)
            if c.is_address(v):
                by_addr.setdefault(lower(v), []).append(cid)
        if len(by_addr) > 1:
            detail = "; ".join(f"{a} on {v}" for a, v in sorted(by_addr.items()))
            out.append(f"{key} is NOT identical across chains — CREATE2 means it must be: {detail}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("step", help="one of " + ", ".join(STEPS) + ", or 'all'")
    ap.add_argument("chains", nargs="*", type=int)
    ap.add_argument("--archive-tag", default="pre-redeploy",
                    help="reset_deployment_records.py --tag used for the pre-clear archive")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--json", help="write the full report here")
    ap.add_argument("--allow-partial", action="store_true",
                    help="treat an unreachable chain as a warning instead of a failure")
    ap.add_argument("--rpc-url",
                    help="read every chain through this endpoint instead of probing. For the fork "
                         "rehearsal, which forks as the real chain id on a loopback anvil — so pass "
                         "exactly one chain id with it, or you will read one chain's state and "
                         "compare it against another's config.")
    args = ap.parse_args()
    c.load_env()

    if args.rpc_url and len(args.chains) != 1:
        print("ERROR: --rpc-url applies one endpoint to every chain, so it needs exactly one chain id.",
              file=sys.stderr)
        return 2

    steps = STEPS if args.step == "all" else [args.step]
    for s in steps:
        if s not in CHECKS:
            print(f"ERROR: unknown step {s!r}; expected one of {', '.join(STEPS)} or 'all'",
                  file=sys.stderr)
            return 2

    chains, scope_src = c.resolve_chains(args.chains)
    base = baseline()
    if not base:
        print("WARNING: snapshots/pre/index.json is missing — the 'address actually moved' checks "
              "in 1.2/1.3 will be skipped.")

    print(f"scope: {len(chains)} chain(s) from {scope_src}")
    for s in steps:
        print(f"step {s}: {STEP_TITLE[s]}")
    print()

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(
            lambda cid: verify_chain(cid, steps, args.archive_tag, base, args.rpc_url), chains))
    results.sort(key=lambda r: r.chain_id)

    n_fail = n_warn = n_unreachable = 0
    for r in results:
        if r.unreachable:
            n_unreachable += 1
            print(f"  {r.chain_id:8} {r.name:16} UNREACHABLE — {r.unreachable[:120]}")
            continue
        status = "PASS" if r.ok else f"FAIL ({len(r.fail)})"
        extra = f" {len(r.warn)} warn" if r.warn else ""
        print(f"  {r.chain_id:8} {r.name:16} {status}{extra}")
        for m in r.fail:
            print(f"           [FAIL] {m}")
        for m in r.warn:
            print(f"           [warn] {m}")
        n_fail += len(r.fail)
        n_warn += len(r.warn)

    cross = cross_chain_identity(results, steps, chains)
    for m in cross:
        print(f"  {'ALL':8} {'cross-chain':16} [FAIL] {m}")
    n_fail += len(cross)

    print(f"\n{n_fail} failure(s), {n_warn} warning(s), {n_unreachable} unreachable chain(s) "
          f"across {len(chains)} chain(s)")

    if args.json:
        json.dump({"steps": steps, "scope": chains, "crossChain": cross,
                   "chains": [{"chainId": r.chain_id, "name": r.name,
                               "unreachable": r.unreachable, "fail": r.fail,
                               "warn": r.warn, "info": r.info} for r in results]},
                  open(args.json, "w"), indent=1)
        print(f"wrote {args.json}")

    if n_unreachable and not args.allow_partial:
        print("FAIL: a chain that was never read cannot be said to have passed. Fix the endpoint or "
              "pass --allow-partial.")
        return 1
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
