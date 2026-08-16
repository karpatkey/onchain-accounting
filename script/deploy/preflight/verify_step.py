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
import re
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


def populated(d) -> dict:
    """Every address-shaped value anywhere in a record section, whatever shape the section is.

    SHAPE-AGNOSTIC ON PURPOSE. This took `dict` only, and the caller narrowed with
    `populated(block if isinstance(block, dict) else None)`, so a section that was a LIST of live
    pre-redeploy addresses scanned as empty and passed the gate clean. The second half of the rule
    is *the record must contain nothing populated*, and that holds whatever container the section
    turned out to be — a rule stated over one container type is not that rule. Lists and bare
    scalars are walked; keys are synthesised positionally so the caller can still name what it hit.
    """
    out: dict = {}

    def walk(node, path: str) -> None:
        if isinstance(node, dict):
            for k_, v_ in node.items():
                walk(v_, k_ if not path else path + "." + str(k_))
        elif isinstance(node, (list, tuple)):
            for i_, v_ in enumerate(node):
                walk(v_, (path or "") + "[" + str(i_) + "]")
        elif c.is_address(node):
            out[path or "<value>"] = node

    walk(d, "")
    return out


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


def expected_sections(chain_id: int) -> set[str]:
    """Which `CLEAR_SECTIONS` blocks this chain is SUPPOSED to carry, derived from CONFIG.

    Same oracle and same reasoning as `expected_clear_top`. The section -> config-directory mapping
    is an EXPLICIT table below, NOT derived from the name: deriving it found only `balance-adapters`
    and missed `meta-balance-adapters`, which is what made this check dead on chains 10/137/8453/42161.
    A third `CLEAR_SECTIONS` entry therefore needs a `producers` entry — without one,
    `producers.get(sec, ())` yields no expectation and the section fails open.
    """
    # `balanceAdapters` IS UNIVERSAL AND NO CONFIG DECLARES IT. Every deployed NAV carries
    # `ERC20Default`, minted by `initialize` and written by 02/02_2 — measured on all 24 in-scope
    # records (only out-of-scope 1101 lacks it, and its record is empty). An earlier revision derived
    # this section from the plain-adapter config alone, which under-expected it on every chain whose
    # adapters are all META (chain 10) or whose only entry is `ERC20Default` — so deleting the whole
    # section there passed gate 1.1 SILENTLY. That is the dangerous direction: the bug this file
    # fixes was a gate crying wolf, and a gate that stays quiet while the thing it guards is broken
    # gets trusted instead of ignored.
    out: set[str] = {"balanceAdapters"}

    # `balanceAdapters` is seeded above and never consulted here, so it gets NO `producers` entry —
    # an earlier version listed one and it was unreachable dead code, justified by seven lines of
    # comment for a lookup that never ran. The multi-producer fact is why the section is
    # UNCONDITIONAL rather than why it needs a table: measured across the 25 committed records, its
    # entries come from `balance-adapters` (12), `meta-balance-adapters` (33), and `ERC20Default`
    # (24, declared by no config), so no config-derived rule could ever cover it.
    #
    # `customPriceFeeds` IS config-derived, and its own count is 38 declared by `custom-price-feeds`
    # plus `stETH` on chain 1 declared nowhere — so this table is a lower bound on that section too,
    # and the archive is what covers the remainder.
    producers = {
        "customPriceFeeds": ("custom-price-feeds",),
    }
    for sec in rd.CLEAR_SECTIONS:
        if sec in out:
            continue
        for sub in producers.get(sec, ()):
            if pc.enabled_keys(pc.dcfg(sub, chain_id)):
                out.add(sec)
                break
    return out


def expected_entries(sec: str, chain_id: int, arch_block) -> set[str]:
    """The entries a section MUST carry, as a UNION over every oracle.

    A UNION, never a disjunction of guards. The rule this file kept getting wrong was written as
    `if <config says so> or <archive says so>:` — a condition, so making one oracle WORSE made the
    whole check skip. Measured: substituting another chain's archive took the failure count from 1
    to 0. Evidence subtracted. A union cannot do that: adding an oracle can only grow the set, and
    the set is what gets iterated, so adding an oracle can only add failures.
    """
    out: set[str] = set()
    if sec == "balanceAdapters":
        out.add("ERC20Default")          # on every deployed NAV; declared by no config
        for sub in ("balance-adapters", "meta-balance-adapters"):
            out |= set(pc.enabled_keys(pc.dcfg(sub, chain_id)))
    elif sec == "customPriceFeeds":
        out |= set(pc.enabled_keys(pc.dcfg("custom-price-feeds", chain_id)))
    if isinstance(arch_block, dict):
        out |= set(arch_block)
    return out


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
    stack that every in-scope chain gets.

    The adapter -> assistant mapping comes from `ASSISTED_PAIRS`, the SAME table gate 1.7 uses, so
    the two gates cannot silently disagree about which pairs exist. An earlier revision re-derived
    it by stem-prefix string surgery, which is a second source of truth for a fact the file already
    states once. Config loading goes through `preflight_config`, whose `enabled_keys` already
    mirrors `ConfigReader.isAdapterEnabled` (a MISSING `enabled` reads as false).
    """
    keys = {key for key in rd.CLEAR_TOP if not key.endswith("Assistant")}
    cfg = pc.dcfg("balance-adapters", chain_id)
    if not cfg:
        # SAY SO rather than silently shrinking the expectation. An absent or unreadable config is
        # the ORACLE being unavailable, not a chain legitimately carrying nothing — and that
        # difference decides whether an absent assistant is a deletion or a non-event. Returning the
        # universal keys is still safe because evidence is monotone: the archive independently
        # witnesses anything this misses. NOTHING SURFACES THIS TO THE OPERATOR — an earlier version
        # of this comment claimed it was "surfaced by the caller as a warning" and no such warning was
        # ever emitted. The bound is real; the mitigation was not. It bites only when the archive ALSO
        # lacks the key: a deletion predating the reset, on a chain with no readable config.
        return keys
    return keys


def expected_assistants(rec: dict, arch) -> set:
    """Which `*Assistant` keys this record should carry — from the RECORD, not from config.

    THE ORACLE HAD TO CHANGE, and this is what made the union honest. Config enabling an assisted
    adapter does not mean an assistant was ever deployed: `04._deployAssistantsIfEnabled`
    (`04_DeployBalanceAdapters.s.sol:251`) deploys one only once the paired ADAPTER'S ADDRESS is
    already in the record — which is what `ASSISTED_PAIRS` (:69) has said all along while
    `expected_clear_top` derived the opposite from config.

    Measured cost of the wrong oracle: the ordinary enable-before-deploy rollout order (edit config,
    run 04 later) made gate 1.1 demand a key that had never existed and instruct the operator to
    hand-insert it. A gate that cries wolf on a healthy chain gets waved through, which is a
    fail-open with extra steps.

    Presence is read as KEY presence, not address presence, because step 1.1 runs AFTER the clear:
    `reset_deployment_records.py` blanks values and keeps keys, so a deployed adapter reads as
    `"AdapterName": ""`.
    """
    out = set()
    for adapter_key, assistant_key in ASSISTED_PAIRS:
        for src in (rec, arch):
            block = src.get("balanceAdapters") if isinstance(src, dict) else None
            if isinstance(block, dict) and adapter_key in block:
                out.add(assistant_key)
                break
    return out


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
    # WHAT THIS CHECK PROVES, STATED NARROWLY, BECAUSE AN EARLIER VERSION CLAIMED MORE THAN IT DID.
    # It proves the archive is a deployment record OF THE GENERATION BEING REPLACED, sitting at the
    # path for this chain. It does NOT prove the CONTENT belongs to this chain, and it cannot:
    # `NAVCalculatorProxy` is the same CREATE2 address on all 24 chains, so a property that is
    # identical everywhere cannot distinguish anywhere. Copying chain 10's archive to
    # `archive/<tag>/100.json` passes this comparison — measured, not argued. The chain-keyed PATH
    # makes that harder to do by accident; it does not make the content chain-attested.
    #
    # KNOWN GAP, DELIBERATELY NOT CLOSED HERE: attesting chain provenance needs integrity metadata
    # written at ARCHIVE-CREATION time in `reset_deployment_records.do_clear` — there is nothing in
    # a deployment record that differs per chain and survives the clear. That is a change to the
    # writer, out of scope for a gate fix, and it is filed rather than silently skipped.
    #
    # WHY THE GAP IS TOLERABLE: nothing downstream depends on this verdict. Absence is decided by
    # CONFIG (per-chain, independent of the record), with the archive only ever ADDING failures.
    # A foreign archive therefore produces noise, never silence — verified by an arm below. This
    # check earns its place as a diagnostic: a wrong `--archive-tag` or a previous generation's
    # archive is worth reporting on its own, and that it CAN detect.
    #
    # (Coupling: re-capturing `snapshots/pre` after the cutover moves the baseline and makes this
    # report a mismatch. 1.3 (`step_new_proxy`) and 1.5 (`step_custom_price_feeds`) already read
    # `base`, so it is a pre-existing systemic dependency rather than one introduced here. Verified
    # by AST over this file, not asserted: 1.2 and 1.4 read it ZERO times, and an earlier version of
    # this comment named 1.4 — the justification for the coupling was itself unchecked.)
    old_proxy = (base.get(k.chain_id) or {}).get("proxy") if base else None
    if arch is not None:
        if not old_proxy:
            # WARN, NOT FAIL. This is the ORACLE being unavailable, not the record being wrong.
            # Measured: as a failure it turned gate 1.1 RED on 24 of 24 correctly-cleared chains
            # when `snapshots/pre/index.json` is missing or re-captured — reintroducing the exact
            # #299 mass-red this file exists to remove, from the check added to diagnose it.
            # Absence is judged from config, which does not need the baseline.
            k.warn.append(f"snapshots/pre/index.json has no baseline proxy for chain {k.chain_id}, so "
                          f"archive/{tag}/{k.chain_id}.json cannot be confirmed as the generation "
                          f"being replaced — absence is judged from config, so this is not a failure")
        elif str(arch.get("NAVCalculatorProxy", "")).lower() != str(old_proxy).lower():
            k.fail.append(f"archive/{tag}/{k.chain_id}.json records NAVCalculatorProxy "
                          f"{arch.get('NAVCalculatorProxy')!r}, but the committed pre-deploy snapshot "
                          f"records {old_proxy} — this archive is not the generation being replaced "
                          f"(wrong --archive-tag, or an earlier redeploy's archive). NOTE: this "
                          f"compares generation only; it cannot tell whether the file's CONTENT "
                          f"belongs to this chain, because the proxy address is identical on all "
                          f"chains by CREATE2 design")

    # EVIDENCE IS MONOTONE HERE, AND THAT IS THE WHOLE DESIGN. A key's absence is a failure if
    # ANY source says it belongs: CREATE_IF_ABSENT, this chain's CONFIG, or the archive. Adding a
    # source can only add failures, never excuse one — so a wrong-chain or wrong-generation archive
    # produces noise, never silence, and the generation check above is diagnostic rather than
    # load-bearing. That is what makes its known chain-provenance gap tolerable rather than a hole.
    #
    # That ordering was arrived at the hard way. An earlier revision made the ARCHIVE the sole
    # oracle, which produced two holes that both let a real deletion pass: the proxy it was
    # validated against is the same CREATE2 address on all 24 chains (so any chain's archive was
    # accepted), and the archive is a byte copy of the record taken at clear time (so a key deleted
    # BEFORE the reset was missing from both and looked like one that never existed). Config has
    # neither property: it is per-chain, and it is independent of the record.
    # EXPECTATION IS A UNION OVER ORACLES, and the union is the whole safety argument: adding an
    # oracle can only GROW this set, the check iterates the set, so adding an oracle can only ADD
    # failures and can never excuse one. Asserted, not merely stated — see the `monotonicity:` arms
    # in `--self-test`, which run one record against no archive, a correct archive and a foreign
    # archive and fail if any subject disappears.
    #
    # PRECONDITION ON EVERY ORACLE ADDED HERE: IT MUST BE SOUND. Monotonicity is only a virtue if
    # each oracle is right. Against an UNSOUND oracle the very same property guarantees the error
    # propagates into `expected` and NO other oracle can cancel it — a union has no way to outvote a
    # member. That is not hypothetical: the config-derived assistant oracle over-expected, and
    # because the union can only add, it turned three healthy chains red instead of being corrected
    # by the record. Before adding an oracle, establish that everything it claims is genuinely
    # REQUIRED, not merely correlated with being required. An oracle that is usually right is not
    # sound.
    expected = expected_clear_top(k.chain_id) | expected_assistants(rec, arch)
    section_expected = expected_sections(k.chain_id)

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
    # gnosis — a hole of exactly the kind it exists to catch. Deriving from CONFIG removes the class
    # instead of the instance. NOTE the limit, because an earlier version of this comment claimed
    # the opposite: a future chain-specific `*Assistant` key needs an `ASSISTED_PAIRS` entry (:72)
    # or it silently expects nothing, and a future chain-specific key NOT named `*Assistant` lands
    # in the universal set and goes red fleet-wide. Neither is handled "with no edit here".
    # UNIFORMITY WITH THE SECTION RULE — see the commit body: this is NOT a hole being closed. A
    # config-named key absent from both record and archive is already caught, measured. But a rule
    # that iterates its expected set at one level and gates on the record at the other is a rule
    # someone will later apply wrongly, so both levels now state the same shape.
    for key in sorted(set(rd.CLEAR_TOP) | expected):
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
        # A WHOLLY ABSENT SECTION IS NOT A CLEARED ONE — the same absent-vs-blank defect as the loop
        # above, one level up, and it hid a bigger loss: `populated(None)` is empty, so deleting the
        # entire `balanceAdapters` block (27 entries on mainnet) read as "correctly cleared" and
        # passed. `reset_deployment_records` blanks VALUES and preserves KEYS (`block[name] = ""`),
        # so it never removes a section. Same monotone rule: expected if config or the archive says
        # so, and either source can only add a failure.
        block = rec.get(sec)
        arch_block = arch.get(sec) if isinstance(arch, dict) else None
        want = expected_entries(sec, k.chain_id, arch_block)
        # ITERATE THE EXPECTED SET. Never gate a check on a property of the record — that is the
        # shape that produced four fail-opens here, most recently a foreign archive SILENCING the
        # section check instead of adding noise to it.
        if not isinstance(block, dict):
            if want or sec in section_expected:
                k.fail.append(f"{sec} is missing or is not an object ({block!r}) — this chain is "
                              f"expected to carry {len(want)} entr(y/ies) and "
                              f"`reset_deployment_records.py` blanks values while keeping keys, so "
                              f"it never removes or empties a section")
        else:
            missing = sorted(want - set(block))
            if missing:
                k.fail.append(f"{sec} is MISSING {len(missing)} expected entr(y/ies): "
                              f"{missing[:6]}{' …' if len(missing) > 6 else ''} — expected from "
                              f"config and/or archive/{tag}/{k.chain_id}.json; blanked values keep "
                              f"their keys, so these were deleted")
            elif not block and (want or sec in section_expected):
                # The justification must name a member THIS section actually has. It said "every
                # in-scope chain carries at least `ERC20Default` here" for BOTH sections;
                # `ERC20Default` is a `balanceAdapters` entry and appears in zero committed
                # `customPriceFeeds` blocks, so the message sent an operator hunting an entry that
                # cannot exist there. Conclusion right, stated reason false.
                k.fail.append(f"{sec} is EMPTY, but {len(want)} entr(y/ies) are expected here"
                              + (" (at least `ERC20Default`)" if sec == "balanceAdapters" else "")
                              + " — an empty section is a destroyed one, not a cleared one")
        # NOT narrowed to `dict`: a LIST of live pre-redeploy addresses is exactly what the old
        # narrowing read as empty and passed.
        still = populated(block)
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


def _declared_base_asset(chain_id: int, feed_name: str):
    """`(value, error)` for this feed's declared `baseAsset`. See `_declared_address`."""
    return _declared_address(chain_id, feed_name, "baseAsset")


def _asset_priced_by_feed(chain_id: int, feed_name: str):
    """`(address, error)` of the asset that nav-config says this Custom feed prices.

    Deliberately NOT read from the feed's own `constructor.underlyingAsset`: that key exists on only 8 of the
    26 enabled mainnet feeds, and each family names its underlying differently (`ethPlus`, `vault`, …), so a
    check keyed on it red-gates every feed of the majority shape — including `ETHPlus_CustomPriceFeed`, which
    declares neither `baseAsset` nor `underlyingAsset` and is exactly the feed class this evidence exists to
    vouch for. The asset->feed edge in `assets-and-price-feeds` is universal (a feed no asset references is
    never registered at all) and is the semantically right question anyway: does this contract price the asset
    the NAV is about to register it for?
    """
    try:
        assets = pc.cfg("assets-and-price-feeds", chain_id) or {}
    except Exception as e:  # noqa: BLE001 - surfaced to the operator by the caller
        return None, f"assets-and-price-feeds/{chain_id}.json unreadable ({type(e).__name__})"
    for sym, entry in assets.items():
        if sym.startswith("$") or not isinstance(entry, dict):
            continue
        for kind in ("priceFeeds", "monitorFeeds"):
            for fd in entry.get(kind) or []:
                if isinstance(fd, dict) and fd.get("type") == "Custom" and fd.get("feed") == feed_name:
                    addr = entry.get("address")
                    if not (isinstance(addr, str) and addr.startswith("0x") and len(addr) == 42):
                        return None, f"asset {sym!r} referencing this feed has no usable address ({addr!r})"
                    return addr, None
    return None, None


def _declared_address(chain_id: int, feed_name: str, key: str):
    """`(value, error)` for one declared address-valued config key on a custom price feed.

    `error` distinguishes "the config records no such key" (a legitimate no-opinion, `(None, None)`) from
    "the config could not be read or is malformed". Collapsing both to None — as the first version did —
    turned the config-vs-contract cross-check into a SILENT no-op for exactly the feed whose config is
    wrong, while still reporting PASS.
    """
    try:
        entry = (pc.dcfg("custom-price-feeds", chain_id) or {}).get(feed_name) or {}
    except Exception as e:  # noqa: BLE001 - surfaced to the operator below, never swallowed
        return None, f"custom-price-feeds/{chain_id}.json unreadable ({type(e).__name__})"
    if not isinstance(entry, dict):
        return None, f"config entry for {feed_name!r} is {type(entry).__name__}, not an object"
    # Resolved by the SHARED accessor, which is the one place this repo encodes what
    # `ConfigReader.readAdapterParam` does — top level, then `constructor`, then `initialize`. Open-coding it
    # here (as this did, and it stopped at two of the three scopes) is what made a key written under
    # `initialize` read as "no opinion recorded" while `03` happily deployed from it, so the cross-check
    # below reported PASS having compared nothing.
    raw = pc.resolve_param(entry, key)
    if raw is None:
        # A malformed `constructor` scope is NOT "no opinion recorded". `resolve_param` skips a non-dict
        # scope, so `""`/`null`/a list there resolves to None and would collapse into the legitimate
        # no-opinion path — turning the config-vs-contract cross-check into a silent no-op for exactly the
        # feed whose config is broken, while step 1.5 still printed PASS. That collapse is what this
        # function's `(value, error)` split exists to prevent.
        #
        # Only when the key resolved NOWHERE, though. A feed declaring the key at the TOP level with a
        # leftover malformed `constructor` deploys correctly (`readAdapterParam` checks the top level
        # first), and hard-failing on it red-gated a correct deployment — which is why the unconditional
        # shape gate that used to sit above was removed rather than kept.
        # A key PRESENT with a null value is a broken config, not silence. `resolve_param` returns
        # `entry[key]` whenever the key exists, so `"baseAsset": null` yields None and would otherwise
        # collapse into the legitimate no-opinion path — the exact collapse the `(value, error)` split
        # exists to prevent, printing PASS having compared nothing.
        if pc.has_param(entry, key):
            return None, (f"{key!r} for {feed_name!r} is declared with a null value — that states nothing, "
                          f"so the config-vs-contract cross-check cannot run. Give it an address, or "
                          f"remove the key")
        ctor = entry.get("constructor")
        if ctor is not None and not isinstance(ctor, dict):
            return None, (f"`constructor` for {feed_name!r} is {type(ctor).__name__}, not an object, and "
                          f"{key!r} is not declared at any other scope — so nothing can be cross-checked")
        return None, None                      # no opinion recorded; nothing to cross-check
    # Shape AND hex, mirroring preflight_config.is_address_shaped — a 42-char non-hex placeholder such as
    # "0xREPLACE_ME_WITH_THE_REAL_ADDR" passes a length check and then raises inside int(raw, 16) at the
    # call site, aborting the whole feed loop instead of reporting this one feed.
    if not (isinstance(raw, str) and raw.startswith("0x") and len(raw) == 42):
        return None, f"declared {key} {raw!r} is not a 20-byte address"
    try:
        int(raw, 16)
    except ValueError:
        return None, f"declared {key} {raw!r} is not hex"
    return raw, None


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
    # Initialised BEFORE the branches that set it: it is read far below, in the per-feed loop, and a name
    # bound only inside an `if` is an UnboundLocalError on the path where neither branch fires — the same
    # unbound-variable failure this file has already been bitten by once.
    weak_generation_evidence = False
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
        # STRONG only when we POSITIVELY established the previous-generation set came from a DIFFERENT
        # proxy. `base` (snapshots/pre/index.json) and the per-chain file `old` is built from are separate
        # files, so `old` can be non-empty while `snap_proxy` is None — and the flag was set inside the
        # `is_address` guard below, leaving it False in exactly that case. Default to weak and clear it only
        # on proof, rather than defaulting to strong and hoping the proof is readable.
        proven_different = (c.is_address(snap_proxy) and c.is_address(rec_proxy)
                            and lower(snap_proxy) != lower(rec_proxy))
        weak_generation_evidence = not proven_different
        if c.is_address(snap_proxy) and c.is_address(rec_proxy) and lower(snap_proxy) == lower(rec_proxy):
            # `old` is non-empty but derived from the CURRENT proxy, so it cannot show a
            # generation-2-vs-3 leftover. For BASE_ASSET() == 0 feeds that is the same dead end as `old`
            # being empty — no address comparison AND no NAV pointer — so the per-feed warning below must
            # fire here too, not only in the `else`.
            k.warn.append(
                f"the previous-generation feed set was derived from sources whose proxy ({snap_proxy}) is "
                f"still the one in the record, so this only shows the feeds are not stale by ONE generation. "
                f"If this is a second redeploy, refresh the snapshot/--archive-tag; the NAV() pointer check "
                f"below is the evidence that actually binds")
    else:
        weak_generation_evidence = True
        k.warn.append(f"no previous-generation feed addresses available for chain {k.chain_id} "
                      f"(no archive/{tag} record and no Custom feeds in the pre-snapshot), so "
                      f"'these feeds were actually redeployed' cannot be shown here — the NAV() "
                      f"pointer check below is the only remaining evidence, AND it does not apply to "
                      f"feeds answering BASE_ASSET() == 0 (they hold no NAV pointer). For those, see "
                      f"the per-feed warning below: this combination leaves them with no generation "
                      f"evidence at all")
    if not url or not feeds:
        return
    proxy = rec.get("NAVCalculatorProxy")
    names = sorted(feeds)
    # One batched round-trip for getCode + NAV() over every feed.
    codes = c.rpc_batch(url, [("eth_getCode", [feeds[n], "latest"]) for n in names])
    navs = c.rpc_batch(url, [("eth_call", [{"to": feeds[n], "data": sel("NAV()")}, "latest"])
                             for n in names])
    # BASE_ASSET() is the feed's own declaration of whether it reads a base price OUT of the NAV
    # (INavSourcedPriceFeed / ADR 0019). A feed answering address(0) has no NAV dependency and therefore
    # legitimately exposes no NAV() pointer — InvertedChainlinkCustomPriceFeed is the first such ENABLED
    # feed. Without this the NAV() check below red-gates a CORRECT deployment and sends the operator
    # hunting a leftover feed that does not exist.
    bases = c.rpc_batch(url, [("eth_call", [{"to": feeds[n], "data": sel("BASE_ASSET()")}, "latest"])
                              for n in names])
    # Substitute evidence for the feeds the BASE_ASSET() == 0 branch exempts from the NAV() pointer check —
    # see that branch for why removing evidence without replacing it is not an option.
    unders = c.rpc_batch(url, [("eth_call", [{"to": feeds[n], "data": sel("underlyingAssetSupported()")}, "latest"])
                               for n in names])
    # NB: the loop variable is `base_ret`, NOT `base` — `base` is this function's PARAMETER (the
    # pre-deploy snapshot index). Shadowing it was harmless only because its sole use sits above this
    # loop; any later read below would silently have got a hex string.
    for n, code, nav, base_ret, under_ret in zip(names, codes, navs, bases, unders):
        if isinstance(code, Exception) or code in (None, "0x", ""):
            k.fail.append(f"customPriceFeeds.{n} {feeds[n]} has NO CODE")
            continue

        # Cross-check the CONTRACT against what the CONFIG declared. Config-side, preflight treats a
        # declared address(0) as "not NAV-sourced" and skips its base/heartbeat checks entirely, so a feed
        # that is really NAV-sourced but records address(0) would pass preflight unexamined. This is the
        # only place the two can be compared, because it needs the deployed contract.
        declared, declared_err = _declared_base_asset(k.chain_id, n)
        if declared_err:
            k.fail.append(f"customPriceFeeds.{n}: {declared_err} — the config-vs-contract BASE_ASSET "
                          f"cross-check cannot run, so this feed is unverified rather than verified")
            continue
        # An UNREADABLE BASE_ASSET() is itself disqualifying, not a reason to skip ahead. Registration
        # calls `_validateFeedNotCircular`, which fails CLOSED on `!ok || ret.length != 32` — so a feed
        # that does not implement INavSourcedPriceFeed cannot be registered at all, however healthy its
        # NAV() pointer looks. Falling through to the NAV() check (as an earlier revision did) let such a
        # feed PASS step 1.5 and then be silently skipped by RegisterAssets, which exits 0 — the asset
        # never registers and every holding of it values at $0 on a live NAV.
        if isinstance(base_ret, Exception):
            # TRANSPORT, NOT A CONTRACT ANSWER. `rpc_batch` returns its errors IN BAND and fills the whole
            # 40-call window on one failed POST (chainlib.py:588-591), so this fires for EVERY feed in that
            # window. Still a FAIL — an unverified feed is not a verified one — but it must not assert the
            # contract fact. The old message told the operator these feeds "cannot be registered", which on
            # a rate-limit was simply false, about a whole window at once, and pointed at a redeploy.
            k.fail.append(f"customPriceFeeds.{n} {feeds[n]}: BASE_ASSET() could not be read — TRANSPORT "
                          f"error ({type(base_ret).__name__}), not an answer from the contract. This says "
                          f"nothing about the feed; re-run. If it persists for one address alone, then it "
                          f"is the contract")
            continue
        if not (isinstance(base_ret, str) and len(base_ret) >= 66):
            k.fail.append(f"customPriceFeeds.{n} {feeds[n]}: BASE_ASSET() unreadable ({base_ret}) — "
                          f"PriceFeedLib._validateFeedNotCircular fails closed on this, so the feed "
                          f"cannot be registered regardless of its NAV() pointer")
            continue
        if True:
            # Mirror BOTH clauses of the on-chain validator, not one. PriceFeedLib._validateFeedNotCircular
            # is `if (!ok || ret.length != 32) revert` — EXACTLY one word — and then rejects a dirty upper
            # 96 bits. Gating on ">= 32" while reading the dirty-bit check from word 0 and the address from
            # the LAST word means a 64-byte reply would be judged on two different words AND accepted here
            # while the chain refuses it.
            if len(base_ret) != 66:
                k.fail.append(f"customPriceFeeds.{n} {feeds[n]}: BASE_ASSET() returned "
                              f"{(len(base_ret) - 2) // 2} bytes; PriceFeedLib._validateFeedNotCircular "
                              f"requires exactly 32, so the feed cannot be registered")
                continue
            raw_word = int(base_ret[2:66], 16)
            if raw_word > (1 << 160) - 1:
                k.fail.append(f"customPriceFeeds.{n} {feeds[n]}: BASE_ASSET() returned {hex(raw_word)}, whose "
                              f"upper bits are dirty — PriceFeedLib._validateFeedNotCircular rejects this, so "
                              f"the feed cannot be registered")
                continue
            onchain = "0x" + base_ret[-40:]
            if declared is not None and lower(onchain) != lower(declared):
                k.fail.append(f"customPriceFeeds.{n} {feeds[n]}: config declares baseAsset {declared} but "
                              f"the deployed contract reports BASE_ASSET() {onchain} — one of them is "
                              f"wrong, and preflight's base/heartbeat checks were run against the config")
                continue
            if int(onchain, 16) == 0:
                # The NAV() pointer below is this step's ONLY per-address evidence that a recorded feed belongs
                # to the new stack, so exempting a class of feed from it has to SUBSTITUTE evidence rather than
                # simply remove it. An earlier revision exempted on the contract's zero word alone: a wrong
                # address recorded under a `customPriceFeeds.*` key — anything with a catch-all fallback
                # returning a zero word — then answered 0 here, reverted NAV(), and PASSED a step that used to
                # FAIL it, with `--require-current` also exiting 0. Two conditions now, both required:
                #
                # `underlyingAssetSupported()` must return the asset nav-config says this feed prices. A
                # contract answering for the right asset is the right contract, whatever it does or does not do
                # with NAV(). Note the config side is the asset->feed edge, NOT the feed's own
                # `constructor.underlyingAsset` — see `_asset_priced_by_feed` for why keying on that would
                # red-gate every feed of the majority shape, ETHPlus included.
                #
                # The config's own `baseAsset` declaration is deliberately NOT required here: the
                # declared-vs-onchain cross-check a few lines above already fails when config declares a
                # non-zero base against a contract reporting zero, so demanding the key again would only punish
                # the feeds (ETHPlus and any future USD/X inverter) that legitimately do not carry it.
                want, want_err = _asset_priced_by_feed(k.chain_id, n)
                if want_err or want is None:
                    k.fail.append(f"customPriceFeeds.{n} {feeds[n]}: BASE_ASSET() == 0, so the NAV() pointer "
                                  f"cannot vouch for this address and the asset it prices is the substitute "
                                  f"evidence — but nav-config names no asset for it "
                                  f"({want_err or 'no assets-and-price-feeds entry references this feed'}). A "
                                  f"deployed feed no asset references is never registered, so this is a "
                                  f"finding in its own right, not a reason to skip the check")
                    continue
                # Same two clauses the BASE_ASSET() read above applies, and for the same reason: this word is
                # now the ONLY thing establishing that this address is the intended contract, so a padded
                # reply whose low 20 bytes happen to match must not be accepted as proof of identity.
                got = None
                if isinstance(under_ret, str) and len(under_ret) == 66 and int(under_ret[2:66], 16) <= (1 << 160) - 1:
                    got = "0x" + under_ret[-40:]
                if got is None or lower(got) != lower(want):
                    k.fail.append(f"customPriceFeeds.{n} {feeds[n]}: BASE_ASSET() == 0, so "
                                  f"underlyingAssetSupported() is the only evidence this address is the right "
                                  f"contract — it returned {got or under_ret!r}, but nav-config registers this "
                                  f"feed against {want}")
                    continue
                # STATE THE LIMIT. `underlyingAssetSupported()` is generation-INVARIANT: a leftover
                # previous-generation feed for the same asset answers it identically, so this establishes
                # "right contract for the right asset" and NOT "right generation". For every other feed the
                # immutable NAV() pointer supplies the generation half; these have none. The
                # previous-generation ADDRESS comparison earlier in this step is what actually binds them —
                # so when that could not run, say so per feed rather than letting a green line imply cover.
                if weak_generation_evidence:
                    k.warn.append(f"customPriceFeeds.{n} {feeds[n]}: BASE_ASSET() == 0, so it holds no NAV "
                                  f"pointer, and no USABLE previous-generation address was available to "
                                  f"compare against — nothing in this step can tell a current deployment from a "
                                  f"leftover one for this feed. bytecode_audit cannot either (it masks "
                                  f"immutableReferences). Refresh the snapshot/--archive-tag to restore it")
                k.info.append(f"customPriceFeeds.{n} {feeds[n]}: BASE_ASSET() == 0 and "
                              f"underlyingAssetSupported() == {want}, the asset nav-config registers it for — "
                              f"the right contract for the right asset. NOTE this is asset identity, not "
                              f"generation: the NAV() pointer that proves generation elsewhere does not apply "
                              f"to this feed")
                continue

        # NO config-keyed downgrade here. An earlier revision warned-and-continued when NEITHER BASE_ASSET()
        # nor NAV() was readable, provided the CONFIG declared address(0) — which turned a red step GREEN for
        # a contract that answers neither selector and is therefore not a valid custom feed at all
        # (`PriceFeedLib._validateFeedNotCircular` rejects it with CustomFeedBaseUnreadable). The exemption
        # above is keyed on the CONTRACT's own BASE_ASSET() answer and stands; this one was keyed on
        # operator-editable config and is exactly the fail-open the block below forbids. A transport hiccup
        # here is a re-run, not a reason to pass.
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

    Records and archives are synthetic and the archive lives in a tempdir, but the EXPECTATION is
    resolved against the COMMITTED CONFIG TREE on purpose: `ALL_ASSIST/ONE_ASSIST/NO_ASSIST` are real
    chain ids and every arm routes `chain=` through `expected_clear_top`. The rule under test is
    "what should this chain carry", and a synthetic answer to that tests the fixture, not the rule.
    The consequence belongs here rather than in a surprise: enabling or disabling an assisted adapter
    in `contracts-deployment-config/` changes what these arms assert, so a config edit can turn
    `--self-test` red. That is the coupling working.
    """
    import tempfile
    from pathlib import Path

    ADDR = "0x80eD5cc6cEbAe4fEE1eD8687279aa492A50afa8d"
    OTHER_GEN = "0xE745B83C1B0B24E4A2B0Cf0Ec5B2c2f7c4B5A6d1"
    UNIVERSAL = ["PriceFeedLib", "NavRegistryLib", "NAVCalculatorImplementation", "NAVCalculatorProxy"]
    # The committed pre-deploy baseline the archive must match to count as this record's pre-image.
    # Real chain ids, chosen from config: chain 1 enables all three assisted adapters, chain 100
    # enables StakeWise only, chain 10 enables none. The rule is per-chain now, so the arms must be.
    ALL_ASSIST, ONE_ASSIST, NO_ASSIST, META_WITH_FEEDS = 1, 100, 10, 42161
    # A chain with NO balance-adapters config at all, which takes `expected_clear_top`'s
    # missing-config fallback. That is not a corner: 17 of the 24 in-scope chains have no such file,
    # so the fallback decides expectations for MOST of the fleet — and until this arm existed it was
    # pinned by nothing (mutating `return keys` to `return set()` left the suite at 21/21).
    NO_CONFIG = 5000
    BASE = {ALL_ASSIST: {"proxy": ADDR}, ONE_ASSIST: {"proxy": ADDR},
            NO_ASSIST: {"proxy": ADDR}, META_WITH_FEEDS: {"proxy": ADDR},
            NO_CONFIG: {"proxy": ADDR}}
    results: list[tuple[bool, str]] = []
    # ARM DISTINCTNESS, ENFORCED RATHER THAN CHECKED BY HAND. TWICE in this suite's history two arms
    # have been byte-identical while advertising different cases: an arm duplicating another AND
    # mislabelled, and later HOLE 6 duplicating HOLE 7 because
    # `{...UNIVERSAL} | {"NAVCalculatorProxy": ADDR}` is a NO-OP merge — UNIVERSAL already holds that
    # key — so the same fixture was built twice. Both times the tally counted an arm that modelled
    # nothing. (Two OTHER fixture defects are a related but different class and this check does not
    # catch them: every arm once hardcoded chain 1, and the base fixture once set sections to `{}`.
    # Those are wrong fixtures, not duplicate ones.) A count of arms is not coverage, so the suite
    # proves distinctness rather than asserting it: every arm's full input signature is recorded and
    # any collision fails.
    #
    # WHAT THIS PROVES, EXACTLY, AND WHAT IT DOES NOT. It proves BYTE-distinctness of arm INPUTS. It
    # does NOT prove distinct BEHAVIOUR: two arms differing only in a field `step_record_cleared`
    # never reads hash differently and both pass, so the same code path can still be covered twice
    # while the tally counts two. Demonstrated, not assumed — adding an arm identical but for an
    # unread `rec` key yields "no two arms build identical fixtures: ok" at 23/23.
    #
    # The cheap property is asserted here because it is the one that has actually bitten twice.
    # Distinct-BEHAVIOUR needs branch or path coverage, which is a different and more expensive
    # instrument, and is the honest next step rather than a stronger reading of this one. Do not
    # trust this check for more than it says.
    seen_sigs: dict[str, str] = {}
    dupes: list[tuple[str, str]] = []

    def run(rec: dict, arch: dict | None, label: str, must_fail: bool, expect_in: str = "",
            base: dict | None = None, chain: int = NO_ASSIST, expect_warn: str = "") -> None:
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
        # THE SIGNATURE IS THE INPUT THE ARM FEEDS THE RULE, AND NOTHING ELSE. It used to include
        # `must_fail`/`expect_in`/`expect_warn` too, on the stated ground that "arms that share a
        # fixture but assert different things are legitimately distinct". That ground is wrong, and
        # it made this check blind to the exact defect it was written for: two arms feeding
        # BYTE-IDENTICAL inputs exercise the SAME code path, so the second adds no coverage
        # whatever it asserts — while the tally counts two. Demonstrated: collapse HOLE 6's archive
        # into HOLE 7's and change only its `expect_in`, and the old signature reported "ok, no two
        # arms build identical fixtures" at 27/27 with HOLE 6 modelling no foreign archive at all.
        # That is finding C's shape reappearing THROUGH the instrument built to prevent it, and it
        # is the likelier real-world path than a wholesale duplicate: a fixture gets changed, the
        # arm goes red, and it is "fixed" by adjusting the assertion.
        #
        # Asserting two properties of one scenario is legitimate — as TWO ASSERTIONS IN ONE ARM, not
        # as two arms inflating the count. A count of arms is not coverage.
        sig = json.dumps({"rec": rec, "arch": arch, "chain": chain,
                          "base": BASE if base is None else base},
                         sort_keys=True, default=str)
        if sig in seen_sigs:
            dupes.append((seen_sigs[sig], label))
        else:
            seen_sigs[sig] = label

        failed = bool(k.fail)
        joined = " | ".join(k.fail)
        warned = " | ".join(k.warn)
        ok = (failed == must_fail) and (not expect_in or expect_in in joined) \
            and (not expect_warn or expect_warn in warned)
        # Built by concatenation, NOT a nested f-string reusing the outer quote: that construct is
        # PEP 701 and only parses on Python 3.12+, and a SyntaxError here is raised at IMPORT, which
        # would take out every gate 1.1-1.8 on an older interpreter rather than just --self-test.
        # No Python floor is pinned anywhere in this repo, so it must parse on 3.9+.
        line = ("ok   " if ok else "FAIL ") + label
        if not ok:
            wanted = "fail" if must_fail else "pass"
            line += "  -> expected " + wanted + ", got: " + (joined or "pass")
        results.append((ok, line))

    def cleared_for(chain_: int) -> dict:
        """A REALISTIC post-clear record for `chain_`: every key a live record carries, blanked.

        THE FIXTURE THIS REPLACES COULD NOT EXPRESS THE FAILURE MODE THIS GATE EXISTS TO CATCH.
        It was four universal keys plus `AssetKindRegistry` — no `balanceAdapters` section, no
        `customPriceFeeds` section, no `*Assistant` keys at all. So an arm labelled "a DELETED
        assistant is caught" was not modelling a deletion: the key it claimed had been deleted was
        never in the fixture. Absence was baked in, and the arm went green without the gate ever
        distinguishing DELETED from NEVER-EXISTED. That distinction is the gate's entire subject —
        the file states it twice, "DESTROYED IS NOT THE SAME AS DELETED" and "a DELETED key cannot
        be told apart from one that never existed on this chain" — and the suite asserting it could
        not represent it.

        Verified against reality before being trusted: on chains 1/10/100/8453/42161 every
        config-named adapter is present in the committed record, and the record carries exactly one
        key config never declares (`ERC20Default`). This reproduces that shape. Arms that model a
        deletion must now DELETE something from it, explicitly, which is the point.
        """
        out = {key: "" for key in UNIVERSAL}
        out["AssetKindRegistry"] = ""
        ba = {"ERC20Default": ""}
        for sub_ in ("balance-adapters", "meta-balance-adapters"):
            for name_ in pc.enabled_keys(pc.dcfg(sub_, chain_)):
                ba[name_] = ""
        out["balanceAdapters"] = ba
        if "customPriceFeeds" in expected_sections(chain_):
            out["customPriceFeeds"] = {n_: "" for n_
                                       in pc.enabled_keys(pc.dcfg("custom-price-feeds", chain_))}
        # An assistant is deployed only where its paired adapter was, so a realistic record carries
        # one exactly there. Derived from ASSISTED_PAIRS — the table gate 1.7 uses — rather than
        # from config, so the fixture does not encode the oracle question the rule is about.
        for adapter_key_, assistant_key_ in ASSISTED_PAIRS:
            if adapter_key_ in ba:
                out[assistant_key_] = ""
        return out

    cleared = {key: "" for key in UNIVERSAL}
    cleared["AssetKindRegistry"] = ""
    # Sections PRESENT and EMPTY is what "cleared" means — `reset` blanks values and keeps keys.
    # Omitting them made arms on a chain whose config expects sections fail for the wrong reason.
    # Blanked-but-POPULATED, which is what a cleared section looks like: `reset` sets values to ""
    # and keeps keys. An empty dict is a DESTROYED section and the rule now says so, so an empty
    # fixture would make every arm fail for the wrong reason.
    cleared["balanceAdapters"] = {"ERC20Default": "", "AaveV3InstancesMeta": ""}
    cleared["customPriceFeeds"] = {"wstETH": ""}
    # A chain that never deployed assistants: the archive has none either. THE #299 CASE.
    # WRITTEN PLAINLY, because the merge that used to be here was the exact idiom this file blames
    # for HOLE 6 above: `{... UNIVERSAL} | {"NAVCalculatorProxy": ADDR}` is a NO-OP, since UNIVERSAL
    # already holds that key. It was harmless where it sat — `arch_plain` is the same dict either
    # way — but it is a loaded trap in a file that has already been shot by it once, and it reads as
    # though the merge distinguishes this fixture from a bare one. It does not.
    arch_plain = {key: ADDR for key in UNIVERSAL}

    run(cleared_for(NO_ASSIST), dict(arch_plain), "a chain that never had assistants passes",
        must_fail=False, chain=NO_ASSIST)

    # …and the same fixture must still FAIL for every real defect.
    run({k_: v for k_, v in cleared_for(NO_ASSIST).items() if k_ != "NAVCalculatorProxy"}, dict(arch_plain),
        "a core NAV key deleted fails", must_fail=True,
        expect_in="every in-scope chain carries it")
    run({k_: v for k_, v in cleared_for(NO_ASSIST).items() if k_ != "AssetKindRegistry"}, dict(arch_plain),
        "a deleted CREATE_IF_ABSENT key fails", must_fail=True, expect_in="CREATE_IF_ABSENT")
    run(cleared_for(NO_ASSIST) | {"NAVCalculatorProxy": ADDR}, dict(arch_plain),
        "a still-populated key fails", must_fail=True, expect_in="still populated")
    run(cleared_for(NO_ASSIST), None,
        "a missing archive fails", must_fail=True, expect_in="no rollback archive")
    run(cleared_for(NO_ASSIST) | {"balanceAdapters": {"ERC20Default": ADDR}}, dict(arch_plain),
        "a still-populated CLEAR_SECTIONS entry fails", must_fail=True, expect_in="balanceAdapters")

    # THE ARM THAT KILLS THE NARROW FIX. Chain 100 carries StakeWiseV3ExitQueueAssistant, so
    # "exempt the assistants off chain 1" would have blinded this check to a real deletion there.
    sw = "StakeWiseV3ExitQueueAssistant"
    run(cleared_for(ONE_ASSIST) | {sw: ""}, dict(arch_plain) | {sw: ADDR},
        "a blanked assistant on a chain that HAS one passes", must_fail=False, chain=ONE_ASSIST)
    run({k_: v for k_, v in cleared_for(ONE_ASSIST).items() if k_ != sw}, dict(arch_plain) | {sw: ADDR},
        "a DELETED assistant on a chain that HAS one fails", must_fail=True,
        expect_in="config enables the adapter", chain=ONE_ASSIST)

    # THE PROMOTION ARMS. Making the archive an oracle made its provenance load-bearing, so each way
    # it can be the WRONG archive must push the check back to strict rather than excuse an absence.
    wrong_gen = {key: OTHER_GEN for key in UNIVERSAL}
    run(cleared_for(NO_ASSIST), wrong_gen,
        "an archive from ANOTHER generation is reported", must_fail=True,
        expect_in="not the generation being replaced")
    run({k_: v for k_, v in cleared_for(ONE_ASSIST).items() if k_ != sw}, wrong_gen,
        "...and a wrong-generation archive cannot excuse an expected key", must_fail=True,
        expect_in="config enables the adapter", chain=ONE_ASSIST)
    # PINS THE MISSING-CONFIG FALLBACK. On a chain with no balance-adapters config the universal
    # NAV keys must still be expected, or absence goes unreported on 17 of 24 in-scope chains. The
    # archive is deliberately ALSO missing the key, so config is the only thing that can catch it —
    # which is what makes this arm discriminate rather than pass on the archive's evidence.
    no_pricefeedlib = {key: val for key, val in cleared.items() if key != "PriceFeedLib"}
    run(no_pricefeedlib, {key: ADDR for key in UNIVERSAL if key != "PriceFeedLib"},
        "a universal key deleted on a chain with NO config is still caught", must_fail=True,
        expect_in="every in-scope chain carries it", chain=NO_CONFIG)

    # PINS #6: a missing baseline must WARN, never FAIL. As a failure it turned 24 of 24
    # correctly-cleared chains red — the #299 mass-red, reintroduced by the diagnostic added to
    # detect it. If someone re-promotes this to k.fail, this arm goes red.
    run(cleared_for(NO_ASSIST), dict(arch_plain),
        "a missing baseline WARNS and does not fail the gate", must_fail=False,
        expect_warn="no baseline proxy", base={})

    # HOLES 6 AND 7 — both let a real deletion pass while the archive was the SOLE oracle. These
    # arms are the regression guards for the config-derived rule that replaced it. Chain 1 is used
    # because its config enables all three assisted adapters, so config expects the key regardless
    # of what any archive says.
    # A genuinely FOREIGN archive: chain 10's adapter set (no assistants, meta-only) standing in
    # for chain 1's. An earlier version passed `{key: ADDR for key in UNIVERSAL}`, which is
    # byte-identical to `arch_plain` — the `| {"NAVCalculatorProxy": ADDR}` merge is a NO-OP because
    # UNIVERSAL already contains that key — so this arm duplicated HOLE 7 and modelled no foreign
    # archive at all while reporting itself green.
    foreign_arch = dict(arch_plain) | {"balanceAdapters": {
        "ERC20Default": ADDR, "AaveV3InstancesMeta": ADDR, "CompoundV3CometsMeta": ADDR}}
    assert foreign_arch != arch_plain, "foreign archive fixture must differ from arch_plain"
    run({k_: v for k_, v in cleared_for(ALL_ASSIST).items() if not k_.endswith("Assistant")}, foreign_arch,
        "HOLE 6: a wrong-CHAIN archive can no longer excuse a deletion", must_fail=True,
        expect_in="config enables the adapter that deploys it", chain=ALL_ASSIST)
    run({k_: v for k_, v in cleared_for(ALL_ASSIST).items() if not k_.endswith("Assistant")}, dict(arch_plain),
        "HOLE 7: a deletion PREDATING the reset (absent from the archive too) is caught",
        must_fail=True, expect_in="config enables the adapter that deploys it", chain=ALL_ASSIST)
    # The same absent-vs-blank defect one level up: a WHOLLY deleted section read as "cleared"
    # because `populated(None)` is empty. Chain 1's config enables both sections.
    no_section = {k_: v for k_, v in cleared_for(ALL_ASSIST).items() if k_ != "balanceAdapters"}
    no_section_10 = {k_: v for k_, v in cleared_for(NO_ASSIST).items() if k_ != "balanceAdapters"}
    no_section_meta = {k_: v for k_, v in cleared_for(META_WITH_FEEDS).items() if k_ != "balanceAdapters"}
    run(no_section, dict(arch_plain) | {"balanceAdapters": {"ERC20Default": ADDR}},
        "a WHOLLY ABSENT CLEAR_SECTIONS block is caught, not read as cleared",
        must_fail=True, expect_in="is missing or is not an object", chain=ALL_ASSIST)

    # PINS THE STATED LIMITATION. The generation check cannot attest chain provenance, so a foreign
    # archive passes it silently — that is documented, not fixed. What must hold is that the verdict
    # is NOT load-bearing: a real deletion is still caught, by config. If a future edit makes
    # absence depend on the archive again, this arm fails.
    run({k_: v for k_, v in cleared_for(ONE_ASSIST).items() if not k_.endswith("Assistant")}, dict(arch_plain),
        "a FOREIGN archive passes the generation check yet cannot hide a deletion",
        must_fail=True, expect_in="config enables the adapter that deploys it", chain=ONE_ASSIST)

    # THE FAIL-OPEN ARM. Chain 10 has NO enabled plain adapter — its adapters are all meta, plus the
    # universal ERC20Default that no config declares — so an expectation derived from the
    # plain-adapter config alone was EMPTY there and a deleted section passed silently. This arm ran
    # only on chain 1 before, where config does declare, so the suite shared the blind spot it was
    # meant to catch. It now runs where the hole actually was.
    run(no_section_10, dict(arch_plain), "a deleted section on a META-ONLY chain is caught",
        must_fail=True, expect_in="is missing or is not an object", chain=NO_ASSIST)
    # %24's formulation of this defect named FOUR chains — 10, 137, 8453, 42161 — all with zero
    # enabled PLAIN adapters. Chain 10 alone under-specifies it: 8453/42161 also expect
    # `customPriceFeeds`, so they exercise the config-DERIVED section on a meta-only chain, which
    # chain 10 cannot. A per-chain arm is not redundant while the two sections resolve differently.
    run(no_section_meta, dict(arch_plain), "a deleted section on a meta-only chain WITH feeds is caught",
        must_fail=True, expect_in="is missing or is not an object", chain=META_WITH_FEEDS)

    # DESTROYED != DELETED. null / {} / [] each destroy the key set without removing the name, and
    # an earlier revision keyed on `sec not in rec` and passed all three.
    arch_full = dict(arch_plain) | {"balanceAdapters": {"ERC20Default": ADDR, "AaveV3InstancesMeta": ADDR}}
    for bad, tag_ in ((None, "null"), ({}, "an empty object"), ([], "a list")):
        run(cleared_for(ALL_ASSIST) | {"balanceAdapters": bad}, arch_full,
            f"a section set to {tag_} is caught, not read as cleared", must_fail=True,
            # With an archive holding entries, an emptied section trips LOST before EMPTY —
            # EMPTY is only reachable when no archive witnesses the lost keys.
            # Under the re-derived rule an emptied section reports its MISSING expected entries
            # rather than "LOST", because expectation now comes from the union rather than from the
            # archive's contents alone.
            expect_in="is MISSING" if bad == {} else "is missing or is not an object",
            chain=ALL_ASSIST)

    # ------------------------------------------------------------------------------------------
    # MONOTONICITY. The re-derivation's whole safety argument is that expectation is a UNION over
    # oracles, so adding an oracle can only GROW the expected set, hence only ADD failures, hence
    # never excuse a defect. That argument is a claim about behaviour and it was false at the head
    # these arms were written against: substituting a FOREIGN archive for the correct one took the
    # failure count from 1 to 0 — evidence SUBTRACTED. Asserted here rather than commented, because
    # the previous four fail-opens in this gate were all excused by a comment claiming the property
    # the code did not have.
    #
    # WHAT THE COMPARISON IS OVER, AND WHY IT IS NOT THE MESSAGE TEXT. Failure strings embed counts
    # ("MISSING 27 entr(y/ies)") that legitimately change when an oracle contributes more, so a
    # naive string-set subset would fail on a correct implementation. The comparison is therefore
    # over the SUBJECT of each failure — the leading token, which is the section or key the failure
    # is about. That is weaker than comparing whole messages and stronger than comparing counts:
    # it catches a subject DISAPPEARING, which is what "evidence subtracts" means, and tolerates a
    # subject being reported in more detail.
    def _subjects(rec_: dict, arch_: dict | None, chain_: int, base_: dict | None = None) -> set:
        real_dir_ = rd.ARCHIVE_DIR
        with tempfile.TemporaryDirectory() as td_:
            rd.ARCHIVE_DIR = Path(td_)
            if arch_ is not None:
                (Path(td_) / "selftest").mkdir(parents=True)
                (Path(td_) / "selftest" / (str(chain_) + ".json")).write_text(json.dumps(arch_))
            try:
                k_ = Chk(chain_, "selftest")
                step_record_cleared(k_, rec_, {}, None,
                                    BASE if base_ is None else base_, "selftest")
            finally:
                rd.ARCHIVE_DIR = real_dir_
        # EXCLUDE the archive-availability failure. "no rollback archive at …" is a statement about
        # the ORACLE, not about the record, and it disappears precisely BECAUSE the oracle became
        # available — which is the opposite of evidence subtracting. Counting it would make every
        # monotonicity arm falsely red. This exclusion is deliberately narrow: it drops exactly the
        # missing-archive report and nothing else, so a real subject vanishing still fails the arm.
        return {f.split(" ", 1)[0] for f in k_.fail if "rollback archive at" not in f}

    def monotone(rec_: dict, chain_: int, correct_: dict, foreign_: dict, label: str,
                 base_: dict | None = None) -> None:
        none_ = _subjects(rec_, None, chain_, base_)
        corr_ = _subjects(rec_, correct_, chain_, base_)
        forg_ = _subjects(rec_, foreign_, chain_, base_)
        lost_corr = sorted(none_ - corr_)
        lost_forg = sorted(none_ - forg_)
        # The third comparison is the one that caught the live defect: a foreign archive must not be
        # QUIETER than a correct one. Adding a wrong oracle may add noise; it may never remove a
        # subject the correct oracle reported.
        lost_swap = sorted(corr_ - (forg_ | none_))
        ok_ = not lost_corr and not lost_forg and not lost_swap
        line_ = ("ok   " if ok_ else "FAIL ") + label
        if not ok_:
            line_ += "  -> subjects lost by adding an oracle: correct=" + str(lost_corr) \
                     + " foreign=" + str(lost_forg) + "; lost by SWAPPING correct->foreign=" \
                     + str(lost_swap)
        results.append((ok_, line_))

    # The fixture with teeth: an ENTRY deleted before the reset, so the record and the archive are
    # both blind to it and only CONFIG still says it belongs. Under an archive-gated rule the
    # deletion is invisible; under a union rule config alone carries it.
    _plain_enabled = sorted(pc.enabled_keys(pc.dcfg("balance-adapters", ALL_ASSIST)))
    _victim = _plain_enabled[0] if _plain_enabled else "ERC20Default"
    _blk_full = {"ERC20Default": "", _victim: ""}
    _blk_lost = {"ERC20Default": ""}                      # `_victim` deleted, not blanked
    _rec_entry_lost = cleared_for(ALL_ASSIST) | {"balanceAdapters": dict(_blk_lost)}
    _arch_blind = dict(arch_plain) | {"balanceAdapters": dict(_blk_lost)}
    _arch_sees = dict(arch_plain) | {"balanceAdapters": dict(_blk_full)}

    run(_rec_entry_lost, _arch_blind,
        "an ENTRY deleted BEFORE the reset, named by config, is caught", must_fail=True,
        expect_in=_victim, chain=ALL_ASSIST)
    monotone(_rec_entry_lost, ALL_ASSIST, _arch_sees, dict(arch_plain),
             "monotonicity: no archive can REMOVE a failure another oracle supplied")

    # A section that is a LIST of live pre-redeploy addresses, on a chain whose config does not
    # expect the section and with no archive witnessing it. `populated(block if isinstance(block,
    # dict) else None)` reads that as `populated(None)` — empty — so a record still holding
    # old-generation addresses passes clean.
    # NOTE THE ARCHIVE IS SUPPLIED AND THE SUBJECT IS PINNED, both deliberately. Passing `arch=None`
    # makes "no rollback archive at …" fire, which satisfies `must_fail=True` on its own — the arm
    # then goes green without ever testing its own subject. That is the vacuous-arm shape this
    # suite has already been bitten by twice, so every arm here supplies an archive that does NOT
    # witness the section and asserts the SUBJECT by name.
    run(cleared_for(NO_ASSIST) | {"customPriceFeeds": [ADDR]},
        dict(arch_plain), "a section that is a LIST of live old addresses is caught",
        must_fail=True, expect_in="customPriceFeeds", chain=NO_ASSIST)

    # THE SAME HOLE ONE LEVEL UP, on CLEAR_TOP keys rather than sections. `if key in rec:` /
    # `elif arch is not None and key in arch:` means a key absent from BOTH record and archive is
    # never checked at all, even when config names it. A section-scoped re-derivation leaves this.
    _ct_missing = {k_: v for k_, v in cleared_for(ALL_ASSIST).items() if k_ != "NAVCalculatorProxy"}
    # The key must be absent from the ARCHIVE TOO, or `elif arch is not None and key in arch:`
    # catches it and the arm tests the branch above the hole rather than the hole. An earlier
    # revision of this arm left the key in the archive with a null value — `key in arch` is True
    # for that — so it went green while modelling nothing.
    _arch_no_ct = {k_: v for k_, v in arch_plain.items() if k_ != "NAVCalculatorProxy"}
    assert "NAVCalculatorProxy" not in _arch_no_ct, "CLEAR_TOP arm needs the key absent from the archive"
    # ASSERT THE MESSAGE, NOT THE NAME. Removing the key from the archive is required to get past
    # `elif arch is not None and key in arch:`, but it also trips two archive-PROVENANCE failures
    # ("has no NAVCalculatorProxy — it is not a pre-clear record", and the generation mismatch), and
    # both contain the bare key name. So `expect_in="NAVCalculatorProxy"` stayed green even with the
    # absence rule silenced — the arm could not detect the regression it exists to detect. Measured:
    # silencing the rule turns 10 arms red and left this one green on the name, RED on the message.
    # The earlier fix here MOVED the defect rather than removing it, swapping "key present in the
    # archive with a null value" for "key absent from the archive" while keeping a bare-name
    # assertion that cannot tell the two apart.
    run(_ct_missing, dict(_arch_no_ct),
        "a CLEAR_TOP key absent from BOTH record and archive is caught", must_fail=True,
        expect_in="is ABSENT from the record", chain=ALL_ASSIST)
    monotone(_ct_missing, ALL_ASSIST, dict(arch_plain), dict(foreign_arch),
             "monotonicity: CLEAR_TOP failures survive an archive swap")

    # R1 — THE RECORD-DRIVEN ASSISTANT ORACLE, ASSERTED. The change was correct and unasserted: the
    # negation sweep reported it "caught" because reverting it turns OTHER arms red, which is
    # coverage of those arms, not of this property. A future revert to a config-derived oracle would
    # go unnoticed by anything that names it. This pins it directly.
    #
    # ENABLE-BEFORE-DEPLOY: config enables an assisted adapter, `04` has not run, so the record
    # carries NEITHER the adapter entry NOR its assistant. The entry is legitimately reported (config
    # names it and the union expects it); the ASSISTANT must NOT be, because nothing deployed it.
    # Asserted on the failure SUBJECTS rather than through `run`, because the property is the ABSENCE
    # of a specific failure and `expect_in` can only assert presence.
    _pair_adapter, _pair_assistant = ASSISTED_PAIRS[0]
    _rec_predeploy = cleared_for(ALL_ASSIST)
    _rec_predeploy["balanceAdapters"] = {k_: v for k_, v in _rec_predeploy["balanceAdapters"].items()
                                         if k_ != _pair_adapter}
    _rec_predeploy.pop(_pair_assistant, None)
    _subj_predeploy = _subjects(_rec_predeploy, dict(arch_plain), ALL_ASSIST)
    # GUARD THE ABSENCE ASSERTION ON A NAMED SIGNAL. `x not in set()` is TRUE, so without this the
    # arm passes whenever the expected failure is absent — whether the fixture produced nothing at
    # all, or produced something UNRELATED. A bare `bool(subjects)` guard would catch only the first
    # and then misreport the second as "no failures at all", which is false: it produced one, just
    # not the one that makes this scenario the scenario. Requiring the balanceAdapters subject by
    # NAME is what ties the guard to the case being modelled.
    # It is non-vacuous today only INCIDENTALLY: the fixture deletes the adapter entry, so the set
    # happens to hold `balanceAdapters`, which nothing asserted. An arm meaningful by accident goes
    # meaningless on the next edit, silently — and this is the arm written to close the previous
    # instance of exactly that defect, so it is the last place it should be allowed to recur.
    _r1_reached = "balanceAdapters" in _subj_predeploy
    _r1_ok = _r1_reached and _pair_assistant not in _subj_predeploy
    # TWO FAILURE MODES, TWO MESSAGES. One diagnostic for both would name the wrong cause half the
    # time, and a guard that fires correctly while misdiagnosing sends the next reader after a
    # defect that is not there — which has cost this repo real hours already.
    if _r1_ok:
        _r1_why = ""
    elif not _r1_reached:
        _r1_why = ("  -> did not produce the expected balanceAdapters failure, so the scenario was "
                   "not modelled: this arm is not passing, it is vacuous")
    else:
        _r1_why = ("  -> " + _pair_assistant + " was demanded from config alone; the oracle has "
                   "reverted to config-driven")
    results.append((_r1_ok,
                    ("ok   " if _r1_ok else "FAIL ")
                    + "an assistant config ENABLES but nothing DEPLOYED is not demanded" + _r1_why))

    # Reported as its own arm so a collision shows up in the tally and the exit code, not just in
    # a comment nobody reads. Two arms sharing a fixture AND an expectation are the same test twice;
    # arms that share a fixture but assert different things are legitimately distinct and pass.
    results.append((not dupes,
                    ("ok   " if not dupes else "FAIL ") + "no two arms build identical fixtures"
                    + ("" if not dupes else " -> " + "; ".join(f"{a!r} duplicates {b!r}"
                                                               for a, b in dupes))))

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
              "in 1.3/1.5 will be skipped, and 1.1 will report that it cannot confirm the archive "
              "is this record's pre-image (absence is still judged from config, so it stays sound).")

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
