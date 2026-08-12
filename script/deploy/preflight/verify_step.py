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
  python3 verify_step.py 1.8 --json out.json
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

STEPS = ["1.1", "1.2", "1.3", "1.4", "1.5", "1.6", "1.7", "1.8"]
STEP_TITLE = {
    "1.1": "deployment record cleared",
    "1.2": "01_2 — libraries + NAV implementation",
    "1.3": "02_2 — new proxy + ERC20Default",
    "1.4": "08 — asset-kind registry: MANAGER grant AND classification",
    "1.5": "03 — custom price feeds",
    "1.6": "RegisterAssets — assets on the new NAV (registers THROUGH the registry)",
    "1.7": "04 — balance adapters + assistants",
    "1.8": "06 — registration + meta-instance reconcile",
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


def expected_clear_top(chain_id: int) -> set[str]:
    """Which `CLEAR_TOP` keys this chain is SUPPOSED to carry, derived from CONFIG.

    Config is the right oracle here and the archive is not, for two reasons that cost this PR two
    holes before landing on it:

      * it is PER-CHAIN by construction, where the deployment record's `NAVCalculatorProxy` is the
        same CREATE2 address on all 24 chains and so cannot distinguish one chain from another;
      * it is INDEPENDENT of the deployment record, where the archive is a byte copy of it taken at
        clear time — so a key deleted BEFORE the reset ran is missing from the archive too, and the
        archive can never witness its own corruption.

    The three `*Assistant` keys exist only where the matching assisted adapter is enabled (today:
    chain 1 all three, chain 100 StakeWise only). Every other `CLEAR_TOP` key is part of the NAV
    stack that every in-scope chain gets. The `…Assistant` record key maps to the `…Assisted*`
    config key by stem; the mapping is derived here rather than hard-coded so a fourth assisted
    protocol needs no edit.
    """
    keys = {k for k in rd.CLEAR_TOP if not k.endswith("Assistant")}
    cfg_path = c.CONTRACTS_CONFIG_DIR / "balance-adapters" / f"{chain_id}.json"
    if not cfg_path.is_file():
        return keys
    try:
        cfg = json.loads(cfg_path.read_text())
    except (OSError, ValueError):
        return keys
    enabled = {name for name, v in cfg.items() if isinstance(v, dict) and v.get("enabled") is True}
    for key in rd.CLEAR_TOP:
        if not key.endswith("Assistant"):
            continue
        stem = key[: -len("Assistant")]
        if any(name.startswith(stem) and "Assisted" in name for name in enabled):
            keys.add(key)
    return keys


def previous_generation_feeds(chain_id: int, tag: str) -> tuple[set[str], list[str]]:
    """Custom-feed addresses belonging to the OLD NAV generation, as (addresses, sources).

    Two independent sources, unioned, because either can be absent:
      * `archive/<tag>/<chainId>.json` — the pre-clear deployment record, present only if the reset
        was run through `reset_deployment_records.py --apply`.
      * `snapshots/pre/<chainId>.json` — the Custom-type feeds actually registered on the old NAV.

    This exists because "the record holds an address" is NOT evidence a feed was redeployed. Every
    `_deploy*` in `03_DeployPriceFeeds` opens with a skip-if-deployed guard that returns early
    (32 of them, `03:233-237` and alike), so a surviving `customPriceFeeds` record makes `03` a
    silent no-op on every feed while still exiting 0 — leaving all of them bound to the OLD proxy
    through their `immutable NAV` (ADR 0019). When the old proxy is eventually decommissioned,
    `NavBaseUsdLib`'s catch drops every custom-priced asset to $0 at once.
    """
    old: set[str] = set()
    sources: list[str] = []
    arch = archived(tag, chain_id)
    if arch:
        vals = {lower(v) for v in (arch.get("customPriceFeeds") or {}).values() if c.is_address(v)}
        if vals:
            old |= vals
            sources.append(f"archive/{tag}/{chain_id}.json")
    snap = c.SNAPSHOT_DIR / "pre" / f"{chain_id}.json"
    if snap.is_file():
        doc = json.loads(snap.read_text())
        vals = set()
        for a in doc.get("assets", []) or []:
            for f in (a.get("priceFeeds") or []) + (a.get("monitorFeeds") or []):
                # Only Custom feeds are ours to redeploy; Chainlink/Redstone addresses are third-party
                # and legitimately unchanged, so including them would be a false positive waiting.
                if f.get("priceType") == "Custom" and c.is_address(f.get("priceFeed")):
                    vals.add(lower(f["priceFeed"]))
        if vals:
            old |= vals
            sources.append(f"snapshots/pre/{chain_id}.json")
    return old, sources


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

def step_record_cleared(k: Chk, rec: dict, exp: dict, url, base, tag) -> None:
    """The record must be cleared, the bridge must NOT be, and a rollback must exist."""
    # The archive is read FIRST because the absence check below needs it as its oracle.
    # reset_deployment_records.py --apply writes it before clearing, so its absence also means the
    # clear was done some other way and there is no rollback.
    arch = archived(tag, k.chain_id)
    if k.require(arch is not None,
                 f"no rollback archive at archive/{tag}/{k.chain_id}.json — the pre-clear record was "
                 f"not captured, so there is nothing to restore, and a DELETED key cannot be told "
                 f"apart from one that never existed on this chain"):
        k.require(c.is_address(arch.get("NAVCalculatorProxy")),
                  f"archive/{tag}/{k.chain_id}.json has no NAVCalculatorProxy — it is not a "
                  f"pre-clear record")

    # THE ARCHIVE IS NOW EVIDENCE, NOT JUST A ROLLBACK COPY — so it must be shown to be THIS
    # record's pre-image before it is allowed to excuse an absent key. Promoting an artefact to an
    # oracle turns every casual property of it into a correctness property, and `--archive-tag` is
    # casual: it defaults to `pre-redeploy` and is chosen independently of
    # `reset_deployment_records.py --tag`. Worse, `do_clear` REFUSES to write into a non-empty
    # archive dir, so a second redeploy is forced onto a new tag while `archive/pre-redeploy/` still
    # holds the PREVIOUS generation — which this check would otherwise read as authoritative.
    #
    # The witness is the committed pre-deploy snapshot, which this function already receives as
    # `base` and never used: the archive's `NAVCalculatorProxy` must be the proxy that
    # `snapshots/pre/index.json` records for this chain. A wrong tag, an earlier generation's
    # archive, a hand-edited file or another chain's file all fail that.
    #
    # WHEN IT CANNOT BE CONFIRMED THE CHECK GETS STRICTER, NOT LOOSER: absence is then judged by the
    # old flat rule and reported. That is noisy, which is the correct direction for a gate — the bug
    # this fixes was noise, and the cure must not be silence. (Note the coupling: re-capturing
    # `snapshots/pre` after the cutover would move the baseline and force this strict path. Steps
    # 1.3 and 1.4 already depend on the same baseline, so that is a pre-existing systemic
    # dependency rather than one introduced here.)
    old_proxy = (base.get(k.chain_id) or {}).get("proxy") if base else None
    archive_is_preimage = False
    if arch is not None:
        if not old_proxy:
            k.fail.append(f"snapshots/pre/index.json has no baseline proxy for chain {k.chain_id}, so "
                          f"archive/{tag}/{k.chain_id}.json cannot be confirmed as this record's "
                          f"pre-image — absence is judged strictly below rather than excused")
        elif str(arch.get("NAVCalculatorProxy", "")).lower() != str(old_proxy).lower():
            k.fail.append(f"archive/{tag}/{k.chain_id}.json records NAVCalculatorProxy "
                          f"{arch.get('NAVCalculatorProxy')!r}, but the committed pre-deploy snapshot "
                          f"records {old_proxy} — this is not the pre-image of the generation being "
                          f"replaced (wrong --archive-tag, an earlier redeploy's archive, or an edited "
                          f"file). Absence is judged strictly below rather than excused")
        else:
            archive_is_preimage = True

    # EVIDENCE IS MONOTONE HERE, AND THAT IS THE WHOLE DESIGN. A key's absence is a failure if
    # ANY source says it belongs: CREATE_IF_ABSENT, this chain's CONFIG, or the archive. Adding a
    # source can only add failures, never excuse one — so a wrong-chain or wrong-generation archive
    # produces noise, never silence, and the provenance check above is diagnostic rather than
    # load-bearing.
    #
    # That ordering was arrived at the hard way. An earlier revision made the ARCHIVE the sole
    # oracle, which produced two holes that both let a real deletion pass: the proxy it was
    # validated against is the same CREATE2 address on all 24 chains (so any chain's archive was
    # accepted), and the archive is a byte copy of the record taken at clear time (so a key deleted
    # BEFORE the reset was missing from both and looked like one that never existed). Config has
    # neither property: it is per-chain, and it is independent of the record.
    expected = expected_clear_top(k.chain_id)

    # ABSENCE IS ONLY A DEFECT WHERE THE KEY WAS SUPPOSED TO BE. This asserts the post-condition
    # `reset_deployment_records.plan_for` actually establishes:
    #
    #     key in record  <=>  key was in the pre-clear record  OR  key in CREATE_IF_ABSENT
    #
    # rather than the flat "every CLEAR_TOP key on every chain", which this check used to assert.
    # CLEAR_TOP carries three `*Assistant` keys that exist only where the assisted adapters are
    # deployed — today chain 1 (all three) and chain 100 (StakeWise only) — so the flat rule reported
    # ABSENT on 23 of the 24 in-scope chains for keys that had legitimately never existed there.
    # A gate that is red on almost every chain for a non-condition is a gate operators learn to
    # override, and the next real absence it reports gets overridden with it. Issue #299.
    #
    # Deliberately NOT "exempt the assistants off chain 1": chain 100 carries
    # StakeWiseV3ExitQueueAssistant, so that rule would blind this check to a real deletion on
    # gnosis — a hole of exactly the kind it exists to catch. Deriving from the archive removes the
    # class instead of the instance: any future chain-specific key is handled with no edit here.
    for key in rd.CLEAR_TOP:
        if key in rec:
            k.require(not c.is_address(rec[key]),
                      f"{key} is still populated ({rec[key]}) — 03/04 will skip-if-deployed and 06 "
                      f"will register the OLD contracts on the NEW proxy")
            continue
        if key in rd.CREATE_IF_ABSENT:
            k.fail.append(f"{key} is ABSENT from the record. `reset_deployment_records.py --apply` "
                          f"creates it blank on every chain (CREATE_IF_ABSENT), so its absence means "
                          f"the clear did not run or the key was deleted afterwards; restore it "
                          f"as \"\" rather than deleting it")
        elif key in expected:
            # Two different reasons a key is expected, and the message must not claim the wrong one:
            # the core NAV keys are on every in-scope chain, while an `*Assistant` key is expected
            # only because THIS chain's config enables the adapter that deploys it.
            why = ("this chain's config enables the adapter that deploys it"
                   if key.endswith("Assistant")
                   else "every in-scope chain carries it as part of the NAV stack")
            k.fail.append(f"{key} is ABSENT from the record, but {why}, so it is expected here — it "
                          f"was deleted rather than blanked; restore it as \"\" rather than "
                          f"deleting it")
        elif arch is not None and key in arch:
            k.fail.append(f"{key} is ABSENT from the record but PRESENT in "
                          f"archive/{tag}/{k.chain_id}.json — it was DELETED, not blanked, so this "
                          f"record reads as cleared while having lost a key it had; restore it as "
                          f"\"\" rather than deleting it")
        # else: config does not expect it here and no archive witnesses it — never existed. Correct.

    for sec in rd.CLEAR_SECTIONS:
        still = populated(rec.get(sec))
        k.require(not still,
                  f"{sec} still holds {len(still)} address(es): {sorted(still)[:6]}"
                  f"{' …' if len(still) > 6 else ''}")

    # The bridge stack is explicitly out of scope for this redeploy.
    for key in ("BridgeEscrowImplementation", "BridgeEscrowProxy"):
        if arch and c.is_address(arch.get(key)) and not c.is_address(rec.get(key)):
            k.fail.append(f"{key} was cleared but the bridge is deferred — restore it from "
                          f"archive/{tag}/{k.chain_id}.json")


def step_impl_and_libraries(k: Chk, rec: dict, exp: dict, url, base, tag) -> None:
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


def step_new_proxy(k: Chk, rec: dict, exp: dict, url, base, tag) -> None:
    """The new proxy: fresh address, correct impl, version 1, roles on the deployer, fresh ERC20Default."""
    proxy = rec.get("NAVCalculatorProxy")
    if not k.require(c.is_address(proxy),
                     "NAVCalculatorProxy is not in the record — 02_2 did not run, or ran without "
                     "PERSIST_DEPLOYMENTS=1"):
        return
    # The freshness proof needs a baseline to compare against. Without one the comparison is
    # vacuous — `lower(None)` is None and `addr != None` is always true — so a chain missing from
    # the pre-snapshot would PASS 1.3 while still pointing at the old proxy. Say so instead.
    old = base.get(k.chain_id)
    if old is None:
        k.fail.append(f"chain {k.chain_id} is not in snapshots/pre/index.json, so there is no "
                      f"pre-deploy proxy to compare against and 'the proxy actually moved' cannot "
                      f"be shown. Capture it (snapshot_production.py) or accept 1.3 unverified here")
        old = {}
    else:
        k.require(lower(proxy) != lower(old.get("proxy")),
                  f"NAVCalculatorProxy {proxy} is the SAME as the pre-deploy proxy — "
                  f"DeploySalts.NAV_PROXY was not bumped, so 02_2 skipped the deploy (runbook 0.2)")
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
    k.require(c.is_address(erc20), f"erc20DefaultBalanceAdapter() returned {erc20}")
    if c.is_address(old.get("erc20Default")):
        k.require(lower(erc20) != lower(old["erc20Default"]),
                  f"erc20DefaultBalanceAdapter() is {erc20}, the SAME as the pre-deploy one — a fresh "
                  f"ERC20Default is minted inside initialize() (NAVCalculator.sol:77), so this means "
                  f"the proxy is the old one")
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


def step_custom_price_feeds(k: Chk, rec: dict, exp: dict, url, base, tag) -> None:
    """Every configured custom feed deployed, with code, pointing at the NEW proxy."""
    feeds = populated(rec.get("customPriceFeeds"))
    # Names, not just cardinality — a stale record key surviving a rename, or one feed substituted
    # for another, keeps the count intact. 1.5 is the only step covering feeds, and a swapped
    # monitor feed is not caught by 1.6 either, since RegisterAssets registers off the primary.
    want = set(pc.enabled_keys(pc.dcfg("custom-price-feeds", k.chain_id)))
    got = set(feeds)
    missing, extra = sorted(want - got), sorted(got - want)
    k.require(not missing, f"{len(missing)} configured custom feed(s) NOT in the record: {missing}")
    k.require(not extra, f"{len(extra)} recorded custom feed(s) are not enabled in config: {extra}")
    k.require(len(feeds) == exp["customFeeds"],
              f"{len(feeds)} custom price feed(s) in the record, config expects "
              f"{exp['customFeeds']}")

    # Every recorded address must be NEW, not merely non-zero. This is the check that catches a
    # partial or skipped reset: `03` skips any feed whose record survived, exits 0, and leaves it
    # bound to the old proxy. Name and count checks cannot see that — the names and count are
    # IDENTICAL to the previous generation, which is exactly what makes the failure quiet.
    old, sources = previous_generation_feeds(k.chain_id, tag)
    if old:
        stale = sorted(n for n, a in feeds.items() if lower(a) in old)
        k.require(not stale,
                  f"{len(stale)} feed(s) still hold their PREVIOUS-GENERATION address "
                  f"{stale[:6]} (per {', '.join(sources)}) — 03 skip-if-deployed'd them, so they "
                  f"remain bound to the OLD proxy via their immutable NAV. Clear the record "
                  f"(step 1.1) and re-run 03")
    if old:
        # `old` being non-empty proves only that the feeds are not generation-1 stale. On a SECOND redeploy,
        # feeds left bound to the generation-2 proxy are absent from `old`, so nothing is flagged -- and the
        # warn below is skipped precisely because `old` is non-empty, so the operator gets a silent clean pass
        # on this axis. Reachable by default: reset_deployment_records refuses to reuse a non-empty archive
        # tag, so a second redeploy must pass a new --tag, while this tool still defaults to `pre-redeploy`.
        snap_proxy = (base.get(k.chain_id) or {}).get("proxy")
        rec_proxy = rec.get("NAVCalculatorProxy")
        if c.is_address(snap_proxy) and c.is_address(rec_proxy) and lower(snap_proxy) == lower(rec_proxy):
            k.warn.append(
                f"the previous-generation feed set was derived from sources whose proxy ({snap_proxy}) is "
                f"still the one in the record, so this only shows the feeds are not stale by ONE generation. "
                f"If this is a second redeploy, refresh the snapshot/--archive-tag; the NAV() pointer check "
                f"below is the evidence that actually binds")
    else:
        k.warn.append(f"no previous-generation feed addresses available for chain {k.chain_id} "
                      f"(no archive/{tag} record and no Custom feeds in the pre-snapshot), so "
                      f"'these feeds were actually redeployed' cannot be shown here — the NAV() "
                      f"pointer check below is the only remaining evidence")
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
            # MUST fail, not warn. `NAV` is a public immutable on every custom feed (ADR 0019), so
            # an unreadable NAV() is either a leftover feed from the old stack — exactly what this
            # step hunts — or an RPC failure, and `rpc_batch` returns its errors IN-BAND, filling a
            # whole window with RpcError on one transport hiccup. Warning meant the heavier `navs`
            # batch could fail wholesale and the chain still printed PASS with zero pointers
            # verified. bytecode_audit treats the same evidence as CURRENT_CODE_STALE_POINTER.
            k.fail.append(f"customPriceFeeds.{n} {feeds[n]}: NAV() unreadable ({nav}) — cannot show "
                          f"this feed points at the new proxy, so the step is not satisfied")
            continue
        ptr = "0x" + nav[-40:]
        k.require(lower(ptr) == lower(proxy),
                  f"customPriceFeeds.{n} {feeds[n]} points at NAV {ptr}, not the new proxy {proxy} — "
                  f"the NAV address is an immutable (ADR 0019), so it must be redeployed")


def step_register_assets(k: Chk, rec: dict, exp: dict, url, base, tag) -> None:
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
    # Set EQUALITY, both directions. An extra registered asset is priced and summed into NAV like
    # any other, so it is not cosmetic; the runbook post-condition is equality, not containment.
    k.require(not extra, f"{len(extra)} registered asset(s) are not in config: {extra[:6]}")


def step_balance_adapters(k: Chk, rec: dict, exp: dict, url, base, tag) -> None:
    """Every adapter deployed, plus an assistant correctly paired to each assisted adapter."""
    adapters = populated(rec.get("balanceAdapters"))
    # +1 for ERC20Default, which every chain gets from initialize() rather than from config.
    want_n = exp["plainAdapters"] + exp["metaAdapters"] + 1
    k.require(len(adapters) == want_n,
              f"{len(adapters)} balance adapter(s) in the record, expected {want_n} "
              f"({exp['plainAdapters']} plain + {exp['metaAdapters']} meta + ERC20Default)")
    k.require("ERC20Default" in adapters, "balanceAdapters.ERC20Default is missing from the record")

    # NAMES, not just cardinality. preflight_config errors on "enabled in nav-config but absent from
    # deploy-config" and only warns on the reverse, so a chain can have one adapter missing and a
    # different one extra — same count, wrong set, and 04 deployed the wrong one. 1.8 catches it
    # only afterwards and only because 06 declines to register the unconfigured adapter.
    want_names = {"ERC20Default"}
    want_names |= set(pc.enabled_keys(pc.cfg("balance-adapters", k.chain_id)))
    want_names |= set(pc.enabled_keys(pc.cfg("meta-balance-adapters", k.chain_id)))
    missing = sorted(want_names - set(adapters))
    extra = sorted(set(adapters) - want_names)
    k.require(not missing, f"{len(missing)} configured adapter(s) NOT deployed: {missing}")
    k.require(not extra, f"{len(extra)} recorded adapter(s) are not enabled in nav-config: {extra}")

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


def step_configure(k: Chk, rec: dict, exp: dict, url, base, tag) -> None:
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
    # An adapter registered on the NAV but absent from the record contributes positions to every NAV
    # read while being invisible to the deployment record — the only place addresses live — so it
    # escapes the bytecode audit and every later migration. The post-condition is equality.
    k.require(not (onchain - recorded),
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
        raw_insts = entry.get("instances") or []
        raw_bytes = entry.get("instancesRaw") or []
        want = {widen(a) for a in raw_insts if c.is_address(a)}
        want |= {lower(b) for b in raw_bytes if pc.is_bytes32(b)}
        # Malformed entries would silently drop out of `want` above and make the comparison narrower
        # than the config it claims to check.
        bad = ([a for a in raw_insts if not c.is_address(a)]
               + [b for b in raw_bytes if not pc.is_bytes32(b)])
        k.require(not bad, f"{name} has {len(bad)} malformed instance coordinate(s): {bad[:3]}")
        # An enabled meta adapter with no instances would make the set comparison vacuously true —
        # {} == {} — while the adapter reports nothing at all on the NAV.
        k.require(want, f"{name} is enabled in nav-config with an EMPTY instance set — it would "
                        f"register and report nothing, and a set comparison against it proves "
                        f"nothing")
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
    # `total` counts DEDUPED coordinates while preflight_config counts raw list lengths, so this
    # also catches a coordinate repeated within one adapter's config — which would otherwise collapse
    # invisibly into the set above and, on the deploy side, revert 06 with DuplicateMetaInstance.
    k.require(total == exp["metaInstances"],
              f"summed configured instances {total} != the {exp['metaInstances']} preflight_config "
              f"counts — a duplicate coordinate in config collapses in the set comparison above")


# How many configured assets to sample for classification. Bounded because this is one eth_call each and
# the point is to detect "setAssetKinds never landed", which is all-or-nothing per batch — not to audit
# every asset's kind, which `08 --verify` and the registry's own tests do.
ASSET_KIND_SAMPLE = 8


def step_asset_kind_registry(k: Chk, rec: dict, exp: dict, url, base, tag) -> None:
    """08 WILL deploy an AssetKindRegistry, grant it MANAGER on the NAV, and classify the assets.

    WRITTEN IN THE FUTURE TENSE ON PURPOSE. As of `main` = c056414c, neither
    `script/deploy/08_DeployAssetKindRegistry.s.sol` nor `src/nav/AssetKindRegistry.sol` exists —
    `git ls-tree origin/main` returns nothing for either path. They ship with PR #241, still open. This
    post-condition lands first so the step cannot arrive without a gate in front of it.

    WHAT IT DEFENDS, and why a comment could not. 08's broadcast dispatches FOUR sequential
    transactions — `new AssetKindRegistry`, `setAssetKindRegistry(registry)`, `grantRole(MANAGER, registry)`,
    `setAssetKinds` — and they can diverge. The dangerous divergence is silent: if `grantRole` never lands while `setAssetKinds` does,
    the result is a FULLY CLASSIFIED registry whose facade is dead, because every registry write gates on
    `NAV.hasRole(MANAGER, msg.sender)`. The script still exits 0, and nothing inside 08 can detect it
    afterwards. 08's own docstring says "verify after broadcasting that BOTH the classification and the
    grant landed" — this is the thing that does that.

    THE TWO HALVES ARE ASSERTED JOINTLY, deliberately. Pinning them separately is exactly what lets the
    partial state through: classification is the half that SUCCEEDS, so on its own it reads as a clean
    deploy, and the grant is the half that dies quietly. A check that can be satisfied by either one
    alone would pass on the precise state this exists to catch.

    AN ABSENT REGISTRY IS A SKIP, NOT A FAIL — and never a silent one. 08 is a late step that many chains
    will legitimately not have run; failing here would turn `verify_step all` red everywhere, which is
    the cry-wolf failure that gets a gate bypassed rather than satisfied. It is reported as INFO so the
    absence is visible and cannot be mistaken for a pass. ONE CASE THIS CANNOT SEE, stated so nobody
    assumes otherwise: a real `--broadcast` without `PERSIST_DEPLOYMENTS=1` deploys a live registry and
    records no address, so there is nothing here to check.
    """
    registry = rec.get("AssetKindRegistry")
    if not c.is_address(registry):
        k.info.append("step 1.4 asserts NOTHING on this chain: no `AssetKindRegistry` in the deployment "
                      "record, i.e. 08 has not run here (or ran without PERSIST_DEPLOYMENTS=1, which "
                      "deploys a live registry and records nothing — invisible to this check)")
        return
    proxy = rec.get("NAVCalculatorProxy")
    if not url or not k.require(c.is_address(proxy), "no NAVCalculatorProxy in the record"):
        return
    if not k.require(code_at(url, registry), f"AssetKindRegistry {registry} has NO code on-chain"):
        return

    # The registry must be bound to the NAV it was handed MANAGER on. 08 records the address before the
    # grant, so a re-run against a NEW proxy can otherwise grant the new NAV's MANAGER to a registry
    # still pointing at the old one — a live facade writing to the wrong NAV.
    bound = call1(url, registry, "NAV()", "address")
    k.require(lower(bound) == lower(proxy),
              f"AssetKindRegistry {registry} is bound to NAV {bound}, not the recorded proxy {proxy} — "
              f"it would hold MANAGER on one NAV while forwarding writes to another")

    # HALF 0 — the READ direction, and the one that was missing entirely.
    #
    # Read off the NAV, not inferred from the registry's side. The whole defect is that the two directions
    # were assumed symmetric and are not: `registry.NAV()` above proves the registry knows the NAV, and says
    # NOTHING about whether the NAV knows the registry. `setAssetKindRegistry` shipped with the read surface
    # and was called by nothing outside tests — no deploy script, no runbook line, no gate — so every deploy
    # left this slot at address(0) and every `getAssetInfo` reverting, while all the checks below passed.
    #
    # Compared by EQUALITY, not against zero. A re-run against a NAV still pointing at a PREVIOUS registry is
    # the likeliest way to be wrong here, and a non-zero check waves exactly that through.
    pointed = call1(url, proxy, "assetKindRegistry()", "address")
    points_back = c.is_address(pointed) and lower(pointed) == lower(registry)
    if not c.is_address(pointed):
        # `is_address` is False for address(0) as well as for an unreadable reply, and BOTH mean the read
        # surface is dead — so they share a verdict. The message names both causes rather than asserting
        # one, because this check cannot tell them apart and guessing is how a guard prescribes the wrong
        # remedy (the #241 lesson: a guard may only prescribe for a cause it can identify).
        k.require(False,
                  f"the NAV {proxy} has NO usable AssetKindRegistry — `assetKindRegistry()` returned "
                  f"{pointed!r}. Either it was never set (address(0)) or the getter is unreadable at this "
                  f"address. Either way EVERY `getAssetInfo` call REVERTS and the read surface is dead on "
                  f"arrival. `setAssetKindRegistry` is the 1st of 08's three post-deploy transactions; "
                  f"re-run 08 — the guarded call is idempotent")
    else:
        k.require(points_back,
                  f"the NAV {proxy} points at AssetKindRegistry {pointed}, NOT the recorded {registry} — a "
                  f"STALE pointer from a previous run. This is WORSE than an unset pointer: reads resolve "
                  f"against the wrong registry and ANSWER, with whatever that one was classified with, "
                  f"rather than reverting. Re-run 08")

    # HALF 1 — the half that dies silently.
    granted = has_role(url, proxy, MANAGER_ROLE, registry)
    k.require(granted,
              f"AssetKindRegistry {registry} does NOT hold MANAGER on the NAV — every registry write "
              f"gates on `NAV.hasRole(MANAGER, msg.sender)`, so the facade is DEAD. `grantRole` is the "
              f"2nd of 08's three transactions and its failure does not stop the 3rd")

    # HALF 2 — the half that succeeds, and therefore the half that makes a broken deploy look fine.
    want = sorted({lower(e.get("address"))
                   for e in pc.cfg("assets-and-price-feeds", k.chain_id).values()
                   if isinstance(e, dict) and c.is_address(e.get("address"))})
    sample = want[:ASSET_KIND_SAMPLE]
    unclassified = [a for a in sample if not is_classified(url, registry, a)]
    k.require(not unclassified,
              f"{len(unclassified)} of {len(sample)} sampled asset(s) are NOT classified: "
              f"{unclassified[:4]} — `setAssetKinds` is the 3rd of 08's three transactions")

    # THE JOINT STATEMENT. Named explicitly because the combination is the hazard, and because a reader
    # seeing only the grant failure above may not realise the classification SUCCEEDING is what makes it
    # dangerous rather than obviously broken.
    if not granted and not unclassified:
        k.fail.append(
            f"PARTIAL STATE — this is the exact divergence 08 cannot detect in itself: the registry is "
            f"fully classified ({len(sample)}/{len(sample)} sampled) but holds NO MANAGER, so 08 exited 0 "
            f"having produced a complete-looking registry with a dead facade. Re-run 08: the guarded "
            f"grant is idempotent and the re-run will land it")

    # THE MIRROR-IMAGE PARTIAL STATE, named separately because it reads completely differently to an
    # operator. Above, writes are dead and reads work. Here, writes work and READS are dead: assets can be
    # registered and classified all day while every consumer of `getAssetInfo` gets a revert. That is the
    # state every deploy of this feature was in until the pointer transaction existed.
    if not points_back and granted and not unclassified:
        k.fail.append(
            f"PARTIAL STATE — the WRITE direction is wired and the READ direction is not: the registry "
            f"holds MANAGER and is fully classified ({len(sample)}/{len(sample)} sampled), but the NAV "
            f"points at {pointed} instead of {registry}. Writes succeed, every `getAssetInfo` fails. "
            f"Re-run 08: the guarded `setAssetKindRegistry` is idempotent")


# ⚠️ **Step NUMBERS are positions in the runbook and they MOVE; the checks are bound to MEANING, not position.**
# `08_DeployAssetKindRegistry` moved from 1.8 to 1.4 when asset registration began routing through the facade: the
# registry must exist, and must hold MANAGER on the NAV, BEFORE `RegisterAssets` runs, because an asset's primary
# registration goes through it and is what classifies and labels the asset atomically.
#
# The dead-facade gate travels with it. `step_asset_kind_registry` is the mechanical check for the
# `grantRole`-never-landed hazard (a fully classified registry whose facade reverts, with `08` exiting 0), and it is
# now MORE load-bearing than before: under the old order a dead facade was merely undetected, whereas now it also
# blocks every subsequent asset registration. Naming the functions semantically is what stops a renumber from
# silently pointing a number at the wrong body — the failure the old positional names invited.
CHECKS = {"1.1": step_record_cleared, "1.2": step_impl_and_libraries, "1.3": step_new_proxy,
          "1.4": step_asset_kind_registry, "1.5": step_custom_price_feeds, "1.6": step_register_assets,
          "1.7": step_balance_adapters, "1.8": step_configure}

NEEDS_RPC = {"1.2", "1.3", "1.4", "1.5", "1.6", "1.7", "1.8"}


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


def is_classified(url: str, registry: str, asset: str) -> bool:
    data = sel("isClassified(address)") + abi_encode(["address"], [asset.lower()]).hex()
    return int(c.eth_call(url, registry, data), 16) == 1


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


def _self_test() -> int:
    """Prove step 1.1's absence check discriminates, in BOTH directions.

    A gate is only worth having if it still fails when it should. The bug this covers (#299) was a
    check that fired on almost every chain for a non-condition; the obvious fix — stop firing — is
    one edit away from a check that never fires at all. So every arm below is paired: for each case
    that must PASS there is a mutation of the same fixture that must FAIL.

    Driven against synthetic records and a tempdir archive rather than the committed ones, because an
    arm reading real config would pass or fail for reasons that have nothing to do with the rule.
    """
    import tempfile
    from pathlib import Path

    ADDR = "0x80eD5cc6cEbAe4fEE1eD8687279aa492A50afa8d"
    OTHER_GEN = "0xE745B83C1B0B24E4A2B0Cf0Ec5B2c2f7c4B5A6d1"
    UNIVERSAL = ["PriceFeedLib", "NavRegistryLib", "NAVCalculatorImplementation", "NAVCalculatorProxy"]
    # The committed pre-deploy baseline the archive must match to count as this record's pre-image.
    # Real chain ids, chosen from config: chain 1 enables all three assisted adapters, chain 100
    # enables StakeWise only, chain 10 enables none. The rule is per-chain now, so the arms must be.
    ALL_ASSIST, ONE_ASSIST, NO_ASSIST = 1, 100, 10
    BASE = {ALL_ASSIST: {"proxy": ADDR}, ONE_ASSIST: {"proxy": ADDR}, NO_ASSIST: {"proxy": ADDR}}
    results: list[tuple[bool, str]] = []

    def run(rec: dict, arch: dict | None, label: str, must_fail: bool, expect_in: str = "",
            base: dict | None = None, chain: int = NO_ASSIST) -> None:
        # The chain id is a REAL one and it matters: expectation is now derived per chain from
        # config, so an arm modelling "a chain that never had assistants" must not be run against a
        # chain whose config enables three of them. An earlier revision of this suite hardcoded
        # chain 1 for every arm and silently tested the opposite of what its labels claimed.
        real_dir = rd.ARCHIVE_DIR
        with tempfile.TemporaryDirectory() as td:
            rd.ARCHIVE_DIR = Path(td)
            tag = "selftest"
            if arch is not None:
                (Path(td) / tag).mkdir(parents=True)
                (Path(td) / tag / f"{chain}.json").write_text(json.dumps(arch))
            try:
                k = Chk(chain, "selftest")
                step_record_cleared(k, rec, {}, None,
                                    BASE if base is None else base, tag)
            finally:
                rd.ARCHIVE_DIR = real_dir
        failed = bool(k.fail)
        joined = " | ".join(k.fail)
        ok = (failed == must_fail) and (not expect_in or expect_in in joined)
        # Built by concatenation, NOT a nested f-string reusing the outer quote: that construct is
        # PEP 701 and only parses on Python 3.12+, and a SyntaxError here is raised at IMPORT, which
        # would take out every gate 1.1-1.8 on an older interpreter rather than just --self-test.
        # No Python floor is pinned anywhere in this repo, so it must parse on 3.9+.
        line = ("ok   " if ok else "FAIL ") + label
        if not ok:
            wanted = "fail" if must_fail else "pass"
            line += "  -> expected " + wanted + ", got: " + (joined or "pass")
        results.append((ok, line))

    cleared = {key: "" for key in UNIVERSAL}
    cleared["AssetKindRegistry"] = ""
    # A chain that never deployed assistants: the archive has none either. THE #299 CASE.
    arch_plain = {key: ADDR for key in UNIVERSAL} | {"NAVCalculatorProxy": ADDR}

    run(dict(cleared), dict(arch_plain), "a chain that never had assistants passes",
        must_fail=False, chain=NO_ASSIST)

    # …and the same fixture must still FAIL for every real defect.
    run({k_: v for k_, v in cleared.items() if k_ != "NAVCalculatorProxy"}, dict(arch_plain),
        "a core NAV key deleted fails", must_fail=True,
        expect_in="every in-scope chain carries it")
    run({k_: v for k_, v in cleared.items() if k_ != "AssetKindRegistry"}, dict(arch_plain),
        "a deleted CREATE_IF_ABSENT key fails", must_fail=True, expect_in="CREATE_IF_ABSENT")
    run(dict(cleared) | {"NAVCalculatorProxy": ADDR}, dict(arch_plain),
        "a still-populated key fails", must_fail=True, expect_in="still populated")
    run(dict(cleared), None,
        "a missing archive fails", must_fail=True, expect_in="no rollback archive")
    run(dict(cleared) | {"balanceAdapters": {"ERC20Default": ADDR}}, dict(arch_plain),
        "a still-populated CLEAR_SECTIONS entry fails", must_fail=True, expect_in="balanceAdapters")

    # THE ARM THAT KILLS THE NARROW FIX. Chain 100 carries StakeWiseV3ExitQueueAssistant, so
    # "exempt the assistants off chain 1" would have blinded this check to a real deletion there.
    sw = "StakeWiseV3ExitQueueAssistant"
    run(dict(cleared) | {sw: ""}, dict(arch_plain) | {sw: ADDR},
        "a blanked assistant on a chain that HAS one passes", must_fail=False, chain=ONE_ASSIST)
    run(dict(cleared), dict(arch_plain) | {sw: ADDR},
        "a DELETED assistant on a chain that HAS one fails", must_fail=True,
        expect_in="config enables the adapter", chain=ONE_ASSIST)

    # THE PROMOTION ARMS. Making the archive an oracle made its provenance load-bearing, so each way
    # it can be the WRONG archive must push the check back to strict rather than excuse an absence.
    wrong_gen = {key: OTHER_GEN for key in UNIVERSAL}
    run(dict(cleared), wrong_gen,
        "an archive from ANOTHER generation is rejected as a pre-image", must_fail=True,
        expect_in="not the pre-image")
    run(dict(cleared), wrong_gen,
        "...and a wrong-generation archive cannot excuse an expected key", must_fail=True,
        expect_in="config enables the adapter", chain=ONE_ASSIST)
    run(dict(cleared), dict(arch_plain),
        "no baseline for the chain => reported, absence judged on config", must_fail=True,
        expect_in="no baseline proxy", base={})

    # HOLES 6 AND 7 — both let a real deletion pass while the archive was the SOLE oracle. These
    # arms are the regression guards for the config-derived rule that replaced it. Chain 1 is used
    # because its config enables all three assisted adapters, so config expects the key regardless
    # of what any archive says.
    run(dict(cleared), {key: ADDR for key in UNIVERSAL},
        "HOLE 6: a wrong-CHAIN archive can no longer excuse a deletion", must_fail=True,
        expect_in="config enables the adapter that deploys it", chain=ALL_ASSIST)
    run(dict(cleared), dict(arch_plain),
        "HOLE 7: a deletion PREDATING the reset (absent from the archive too) is caught",
        must_fail=True, expect_in="config enables the adapter that deploys it", chain=ALL_ASSIST)

    for ok, line in results:
        print(line)
    bad = [line for ok, line in results if not ok]
    print(f"\n{len(results) - len(bad)}/{len(results)} arms passed")
    return 1 if bad else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("step", nargs="?", help="one of " + ", ".join(STEPS) + ", or 'all'")
    ap.add_argument("chains", nargs="*", type=int)
    ap.add_argument("--archive-tag", default="pre-redeploy",
                    help="reset_deployment_records.py --tag used for the pre-clear archive")
    ap.add_argument("--self-test", action="store_true",
                    help="prove step 1.1's absence check still fails when it should (no network)")
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

    # MUTUALLY EXCLUSIVE, not "the flag wins". `verify_step.py 1.1 --self-test` must never print
    # "8/8 arms passed" and exit 0 while naming a gate it did not run: this module exists because a
    # clean exit has to mean work happened, and a self-test that silently replaces a 24-chain step
    # is that exact failure wearing the tool's own output.
    if args.self_test and args.step:
        ap.error(f"--self-test runs no chain checks, so it cannot be combined with a step "
                 f"(got {args.step!r}). Run them as two commands.")
    if args.self_test:
        return _self_test()
    if not args.step:
        ap.error("step is required (one of " + ", ".join(STEPS) + ", or 'all') unless --self-test")

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
