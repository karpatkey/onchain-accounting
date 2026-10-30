#!/usr/bin/env python3
"""Prove — or disprove — that every deployed address runs code from the CURRENT build.

This is the acceptance test for "production is on the latest code". Run it before the redeploy to
see the full extent of the drift, and again after to confirm nothing was missed.

WHY NAIVE EQUALITY ALWAYS FAILS
-------------------------------
Immutables are baked into runtime code at construction, so two deployments of the same contract with
different constructor args have different runtime bytes. The artifact records exactly where those
bytes sit, in `deployedBytecode.immutableReferences` ({astId: [{start, length}, ...]}). Both sides
must have those ranges zeroed before comparing.

WHY MATCHING IS BY BYTECODE, NOT BY NAME
----------------------------------------
Deployment-record keys are operator-facing shorthand ("AaveV3InstancesMeta", "osGNO") and do not map
mechanically onto artifact names ("AaveV3InstancesMetaBalanceAdapter", "osToken_CustomPriceFeed"). Any
name table is a second thing to keep in sync and a second thing to get wrong. So the audit indexes
EVERY artifact under out/ by its immutable-zeroed runtime code and looks the on-chain code up in that
index. The question it answers is the one that matters — "is this exact code in the current build?" —
and as a bonus it names the contract it matched. An address that matches nothing is, by definition,
running code this build does not produce, and must be redeployed.

Because the zeroing mask is per-artifact, candidates are pre-filtered by byte length (immutable
zeroing never changes length) and each same-length artifact is then tested with its own mask.

The build MUST be a clean, full-project one: `forge clean && forge build`. Under via_ir the whole
program is one compilation unit, so an incremental build yields stale artifacts — the exact trap that
cost a deploy detour in PR #155 (see reference_pricefeedlib_pin_drift).

usage:
  python3 bytecode_audit.py --self-test              # verify the comparator itself
  python3 bytecode_audit.py                          # audit all deployed chains
  python3 bytecode_audit.py 1 42161 --json out.json
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import chainlib as c

OUT_DIR = c.REPO / "out"


# ---------------------------------------------------------------------------
# Artifact index
# ---------------------------------------------------------------------------

def _obj(v):
    """forge stores bytecode as {"object": "0x..."} (sometimes a bare string)."""
    if isinstance(v, dict):
        return v.get("object", "")
    return v if isinstance(v, str) else ""


def mask(code: bytes, refs: dict) -> bytes:
    """Zero every immutableReferences range. `refs` is {astId: [{start, length}, ...]}."""
    if not refs:
        return code
    out = bytearray(code)
    for spans in refs.values():
        for s in spans:
            start, length = s["start"], s["length"]
            if start + length <= len(out):
                out[start:start + length] = b"\x00" * length
    return bytes(out)


def load_artifacts() -> list[dict]:
    """Every artifact under out/ that has non-empty deployed bytecode."""
    arts = []
    for path in OUT_DIR.rglob("*.json"):
        if path.name.endswith(".metadata.json"):
            continue
        try:
            a = json.loads(path.read_text())
        except Exception:  # noqa: BLE001 — build-info and friends are not artifacts
            continue
        if not isinstance(a, dict) or "deployedBytecode" in a is None:
            continue
        db = a.get("deployedBytecode")
        if not isinstance(db, dict):
            continue
        hexcode = _obj(db)
        if not hexcode or hexcode == "0x" or "__$" in hexcode:
            # "__$…$__" = unlinked library placeholder. foundry.toml [libraries] pins both libs, so a
            # placeholder here means the artifact was built without them — not comparable to chain.
            continue
        try:
            raw = bytes.fromhex(hexcode[2:])
        except ValueError:
            continue
        name = path.stem
        arts.append({
            "name": name,
            "path": str(path.relative_to(c.REPO)),
            "source": (a.get("metadata") or {}).get("settings", {}).get(
                "compilationTarget", {}) or {},
            "code": raw,
            "refs": db.get("immutableReferences") or {},
        })
    return arts


class Index:
    def __init__(self, artifacts: list[dict]):
        self.by_len: dict[int, list[dict]] = defaultdict(list)
        for a in artifacts:
            self.by_len[len(a["code"])].append(a)
        # Exact (no-immutable) fast path.
        self.exact: dict[bytes, list[dict]] = defaultdict(list)
        for a in artifacts:
            if not a["refs"]:
                self.exact[a["code"]].append(a)

    def match(self, onchain: bytes) -> list[dict]:
        """Artifacts whose masked runtime code equals the masked on-chain code."""
        hits = []
        for a in self.exact.get(onchain, []):
            hits.append(a)
        for a in self.by_len.get(len(onchain), []):
            if not a["refs"]:
                continue  # already covered by the exact path
            if mask(a["code"], a["refs"]) == mask(onchain, a["refs"]):
                hits.append(a)
        # de-dup by name, keep order
        seen, out = set(), []
        for a in hits:
            if a["name"] not in seen:
                seen.add(a["name"])
                out.append(a)
        return out


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

def self_test(index: Index, artifacts: list[dict]) -> int:
    """Verify the comparator on real artifacts before trusting it on real chains."""
    checks, failures = 0, []

    def check(label, cond):
        nonlocal checks
        checks += 1
        if not cond:
            failures.append(label)

    # --- the ENFORCEMENT decision --------------------------------------------------------------
    # These cover `evaluate_drift`, which is what actually decides pass/fail. The loader arms below
    # do NOT cover this: a review of the first version pointed out that every test exercised the
    # baseline PARSER while nothing exercised the decision, and it was right — an exemption scoped
    # to one chain, for an address deployed identically on 23, passes every parser test and still
    # leaves the scheduled all-chain run red. That case is the last arm here.
    def _res(chain_id, *entries):
        return {"chainId": chain_id, "name": f"c{chain_id}", "error": None,
                "entries": [{"address": a, "status": st, "key": k} for a, st, k in entries]}

    A, B = "0xAaAa", "0xBbBb"
    bl_ok, unacc, hits = evaluate_drift([_res(1, (A, "CURRENT", "K"))], {})
    check("a CURRENT address with no baseline is not a failure", (bl_ok, unacc) == ([], []))

    bl_ok, unacc, hits = evaluate_drift([_res(1, (A, "STALE", "K"))], {})
    check("an undeclared STALE address IS a failure", len(unacc) == 1 and bl_ok == [])

    bl_ok, unacc, hits = evaluate_drift([_res(1, (A, "STALE", "K"))], {"1:0xaaaa": {"reason": "r"}})
    check("a declared STALE address is accepted, not failed", (bl_ok, unacc) == ([], []) and len(hits) == 1)

    bl_ok, unacc, hits = evaluate_drift([_res(1, (A, "CURRENT", "K"))], {"1:0xaaaa": {"reason": "r"}})
    check("a baselined address that is now CURRENT fails (baseline rot)", len(bl_ok) == 1)

    bl_ok, unacc, hits = evaluate_drift([_res(1, (A, "CURRENT", "K"))], {"1:0xzzzz": {"reason": "r"}})
    check("a baseline entry for an un-audited address fails (dangling)", len(bl_ok) == 1)

    # The hand decoder behind the retired-registration check: offset, length, 4-word tuples, address first.
    _a1, _a2 = "11" * 20, "22" * 20
    _arr = ("20".rjust(64, "0") + "2".rjust(64, "0")
            + _a1.rjust(64, "0") + "8".rjust(64, "0") + "3".rjust(64, "0") + "e10".rjust(64, "0")
            + _a2.rjust(64, "0") + "8".rjust(64, "0") + "0".rjust(64, "0") + "15180".rjust(64, "0"))
    check("PriceFeedConfig[] decodes to its feed addresses", _feed_addresses("0x" + _arr) == {"0x" + _a1, "0x" + _a2})
    check("an empty PriceFeedConfig[] decodes to no addresses",
          _feed_addresses("0x" + "20".rjust(64, "0") + "0".rjust(64, "0")) == set())
    try:
        _feed_addresses("0x" + "20".rjust(64, "0") + "2".rjust(64, "0"))
        _trunc = False
    except ValueError:
        _trunc = True
    check("a truncated PriceFeedConfig[] raises instead of reading as unregistered", _trunc)
    # A retired feed still registered on the live NAV is NOT exempt.
    bl_ok, unacc, hits = evaluate_drift([_res(1, (A, "RETIRED_BUT_REGISTERED", "retiredCustomPriceFeeds.OETH"))], {})
    check("a retired feed still registered on the live NAV fails", len(unacc) == 1)
    # A RETIRED feed's drift is expected (an older generation can never match this tree): reported, not failed.
    bl_ok, unacc, hits = evaluate_drift([_res(1, (A, "STALE", "retiredCustomPriceFeeds.OETH"))], {})
    check("a STALE retired feed is reported but is not a failure", unacc == [] and len(hits) == 1)
    bl_ok, unacc, hits = evaluate_drift([_res(1, (A, "NO_CODE", "retiredCustomPriceFeeds.OETH"))], {})
    check("a retired feed with NO code still fails (the record is wrong)", len(unacc) == 1)
    bl_ok, unacc, hits = evaluate_drift([_res(1, (A, "STALE", "customPriceFeeds.retiredCustomPriceFeedsX"))], {})
    check("the retired exemption is anchored to the section, not a substring", len(unacc) == 1)
    # A status that is neither CURRENT nor STALE must be treated as a failure, not silently ignored.
    bl_ok, unacc, hits = evaluate_drift([_res(1, (A, "UNKNOWN", "K"))], {})
    check("a non-CURRENT status other than STALE also fails", len(unacc) == 1)

    # THE CHAIN-SCOPE CASE. One address, same bytecode, recorded on two chains; the exemption names
    # only the first. The second must still fail — this is the bug the loader tests could not see.
    bl_ok, unacc, hits = evaluate_drift(
        [_res(1, (A, "STALE", "K")), _res(10, (A, "STALE", "K"))], {"1:0xaaaa": {"reason": "r"}})
    check("an exemption scoped to one chain does NOT excuse the same address on another",
          len(unacc) == 1 and unacc[0].startswith("10:"))

    # And the same address declared on both chains passes on both.
    bl_ok, unacc, hits = evaluate_drift(
        [_res(1, (A, "STALE", "K")), _res(10, (A, "STALE", "K"))],
        {"1:0xaaaa": {"reason": "r"}, "10:0xaaaa": {"reason": "r"}})
    check("declaring every affected chain passes", (bl_ok, unacc) == ([], []) and len(hits) == 2)

    # SCOPED AUDIT. Declaring 23 chains and auditing one must NOT report the other 22 as dangling —
    # auditing a subset is the common case, and the first version failed exactly there.
    bl_ok, unacc, hits = evaluate_drift(
        [_res(1, (A, "STALE", "K"))], {"1:0xaaaa": {"reason": "r"}, "10:0xaaaa": {"reason": "r"}})
    check("a baseline entry for an OUT-OF-SCOPE chain is not dangling", (bl_ok, unacc) == ([], []))

    # But an in-scope chain that no longer records the address still IS dangling.
    bl_ok, unacc, hits = evaluate_drift(
        [_res(1, (B, "CURRENT", "K2"))], {"1:0xaaaa": {"reason": "r"}})
    check("an in-scope chain missing the address IS dangling", len(bl_ok) == 1)

    # A chain that ERRORED is not in scope either — its entries prove nothing.
    errored = {"chainId": 10, "name": "c10", "error": "rpc down", "entries": []}
    bl_ok, unacc, hits = evaluate_drift(
        [_res(1, (A, "STALE", "K")), errored], {"1:0xaaaa": {"reason": "r"}, "10:0xaaaa": {"reason": "r"}})
    check("an entry for a chain that ERRORED is not dangling", (bl_ok, unacc) == ([], []))

    bl_ok, unacc, hits = evaluate_drift([_res(1, (A, "STALE", "K"), (B, "STALE", "K2"))],
                                        {"1:0xaaaa": {"reason": "r"}})
    check("one declared and one undeclared on the same chain fails only the undeclared",
          len(unacc) == 1 and B.lower() in unacc[0])

    # --- the accepted-drift baseline -------------------------------------------------------------
    # These pin the LOADER, which is the half that decides whether an exemption is honoured at all.
    # A baseline that silently loads as empty flips the gate red for the wrong reason; one that
    # silently loads as "everything exempt" flips it green for a far worse one.
    import tempfile as _tf

    def _bl(text: str):
        # Write, CLOSE, then read. Reading inside the `with` returns an unflushed (empty) file, which
        # loads as a JSON error and makes every positive arm below fail for the wrong reason — the
        # first run of these arms did exactly that.
        fh = _tf.NamedTemporaryFile("w", suffix=".json", delete=False)
        try:
            fh.write(text)
        finally:
            fh.close()
        return _load_baseline(fh.name)

    check("no --baseline means no exemptions and no complaint", _load_baseline(None) == ({}, []))
    check("a NAMED baseline that does not exist is a FAILURE, not an empty exemption set",
          bool(_load_baseline("/nonexistent/accepted.json")[1]))
    check("malformed JSON fails rather than loading as empty", bool(_bl("{not json")[1]))
    check("a non-object 'accepted' fails", bool(_bl('{"accepted": []}')[1]))
    ok_entry = '{"accepted": {"1:0xAbC": {"reason": "because", "key": "K"}}}'
    check("a well-formed entry loads, lowercased", _bl(ok_entry)[0].get("1:0xabc") is not None)
    check("a well-formed entry raises no problem", _bl(ok_entry)[1] == [])
    check("an entry WITHOUT a reason is rejected — an exemption with no reason is not a decision",
          bool(_bl('{"accepted": {"1:0xAbC": {"key": "K"}}}')[1]))
    check("a key that is not '<chainId>:<address>' is rejected",
          bool(_bl('{"accepted": {"nochain": {"reason": "r"}}}')[1]))
    check("$-prefixed doc keys are ignored, not parsed as entries",
          _bl('{"accepted": {"$note": "prose", "1:0xAbC": {"reason": "r"}}}')[1] == []
          and len(_bl('{"accepted": {"$note": "prose", "1:0xAbC": {"reason": "r"}}}')[0]) == 1)

    # The shipped file must itself be loadable and non-empty of reasons — a baseline that fails to
    # parse would otherwise only be discovered on a live run.
    shipped = Path(__file__).with_name("accepted-bytecode-drift.json")
    if shipped.is_file():
        entries, problems = _load_baseline(str(shipped))
        check("the shipped accepted-drift file parses with no problems", problems == [])
        check("every shipped entry carries a reason", all(e.get("reason") for e in entries.values()))

    with_imm = [a for a in artifacts if a["refs"]]
    without_imm = [a for a in artifacts if not a["refs"]]
    check("build contains artifacts with immutables", bool(with_imm))
    check("build contains artifacts without immutables", bool(without_imm))

    if with_imm:
        a = max(with_imm, key=lambda x: sum(len(v) for v in x["refs"].values()))
        # 1. Same contract, different constructor args -> different raw bytes, must still match.
        fake = bytearray(a["code"])
        n = 0
        for spans in a["refs"].values():
            for s in spans:
                fake[s["start"]:s["start"] + s["length"]] = bytes(
                    (i * 7 + 3) % 256 for i in range(s["length"]))
                n += s["length"]
        fake = bytes(fake)
        check(f"immutables actually differ for {a['name']}", fake != a["code"])
        check(f"naive equality FAILS on {a['name']} (this is why masking exists)",
              fake != a["code"])
        names = [h["name"] for h in index.match(fake)]
        check(f"masked match recovers {a['name']} from mutated immutables "
              f"(got {names[:3]})", a["name"] in names)

        # 2. A byte changed OUTSIDE the immutable ranges must NOT match.
        protected = set()
        for spans in a["refs"].values():
            for s in spans:
                protected.update(range(s["start"], s["start"] + s["length"]))
        idx = next((i for i in range(len(a["code"])) if i not in protected), None)
        if idx is not None:
            broken = bytearray(a["code"])
            broken[idx] ^= 0xFF
            check(f"a non-immutable byte flip in {a['name']} does NOT match",
                  a["name"] not in [h["name"] for h in index.match(bytes(broken))])

    if without_imm:
        b = without_imm[0]
        check(f"immutable-free {b['name']} matches itself exactly",
              b["name"] in [h["name"] for h in index.match(b["code"])])

    # 3. Garbage matches nothing.
    check("random bytes match nothing", index.match(bytes(os.urandom(1234))) == [])
    # 4. Truncation is caught (length pre-filter must not be the only guard).
    if without_imm:
        b = without_imm[0]
        check("truncated code does not match", index.match(b["code"][:-1]) == [])

    for label in failures:
        print(f"  FAIL  {label}")
    print(f"\nself-test: {checks - len(failures)}/{checks} checks passed "
          f"over {len(artifacts)} artifacts")
    return 1 if failures else 0


# ---------------------------------------------------------------------------
# Audit
# ---------------------------------------------------------------------------

def _sel(sig: str) -> str:
    from eth_utils import keccak
    return "0x" + keccak(text=sig)[:4].hex()


def check_immutable_pointers(chain_id: int, url: str, res: dict) -> None:
    """Bytecode-CURRENT is necessary but NOT sufficient — this is the complement.

    Masking `immutableReferences` is what makes the comparison work at all, and it is also what hides
    the single most important reason a contract needs redeploying here: an immutable that POINTS at
    something. Every custom price feed holds `INAVCalculator public immutable NAV` (ADR 0019,
    e.g. TwoFeedChainlinkPriceFeed.sol:43) and every assistant holds `address public immutable
    ADAPTER` (BalanceAdapterAssistant.sol:27). A feed whose code this build reproduces exactly is
    still wrong if its NAV pointer is the OLD proxy.

    So for every feed we read NAV() and compare against the recorded NAVCalculatorProxy, and for every
    assistant we read ADAPTER() and check it is a recorded assisted adapter on this chain.
    """
    rec = c.deployment(chain_id)
    proxy = (rec.get("NAVCalculatorProxy") or "").lower()
    adapters = {v.lower() for v in (rec.get("balanceAdapters") or {}).values() if c.is_address(v)}
    by_addr = {e["address"].lower(): e for e in res["entries"]}

    targets: list[tuple[str, str, str]] = []   # (address, selector, kind)
    for e in res["entries"]:
        if e["key"].startswith("customPriceFeeds."):
            targets.append((e["address"], _sel("NAV()"), "feed"))
        elif e["key"].endswith("Assistant"):
            targets.append((e["address"], _sel("ADAPTER()"), "assistant"))
    if not targets:
        return

    # A custom feed that reads no base price out of the NAV has NO `NAV` immutable to point anywhere —
    # `InvertedChainlinkCustomPriceFeed` is the first such ENABLED feed, and `ETHPlus_CustomPriceFeed`
    # has the same shape. Without this second probe such a feed records `UNREADABLE` forever, which is
    # indistinguishable from the stale old-generation pointer this check exists to catch.
    #
    # **A DECLARED GAP, stated because the alternative is an operator inferring cover that is not there.**
    # This exemption is keyed on the CONTRACT's zero word alone. `verify_step` 1.5 exempts the same feed
    # class on strictly stronger evidence — it additionally requires `underlyingAssetSupported()` to equal
    # the asset nav-config registers the feed against. So the two tools do NOT cross-confirm each other
    # here, and an earlier version of this comment claiming they "must agree" was simply wrong. For this
    # feed class `--require-current` cannot detect a leftover old-generation feed on its own: the tool
    # masks `immutableReferences` before comparing, so a previous deployment carrying a different band or
    # underlying reproduces the current build's masked code exactly and tallies as CURRENT. **verify_step
    # 1.5 is the binding gate for these feeds; a clean run here is not evidence about them.**
    feed_addrs = [a for a, _d, kind in targets if kind == "feed"]
    bases: dict[str, object] = {}
    if feed_addrs:
        base_out = c.rpc_batch(url, [("eth_call", [{"to": a, "data": _sel("BASE_ASSET()")}, "latest"])
                                     for a in feed_addrs])
        bases = dict(zip((a.lower() for a in feed_addrs), base_out))

    out = c.rpc_batch(url, [("eth_call", [{"to": a, "data": d}, "latest"]) for a, d, _ in targets])
    for (addr, _d, kind), val in zip(targets, out):
        e = by_addr[addr.lower()]
        if isinstance(val, Exception) or not isinstance(val, str) or len(val) < 66:
            base_val = bases.get(addr.lower())
            if (kind == "feed" and isinstance(base_val, str) and len(base_val) == 66
                    and int(base_val, 16) == 0):
                # Declared, by the CONTRACT, to have no NAV dependency. Non-applicable, not unreadable.
                e["pointerCheck"] = "N/A (BASE_ASSET() == 0, no NAV dependency)"
                continue
            # `rpc_batch` returns its errors IN BAND and fills a whole window with them on one failed POST,
            # so a BASE_ASSET() window that errored makes `base_val` an exception rather than a zero word —
            # and the exemption above cannot fire. Say TRANSPORT explicitly: for a feed with no NAV member
            # RECORD, DO NOT ESCALATE — this is origin/main behaviour, deliberately restored. An
            # escalation to CURRENT_CODE_STALE_POINTER was added here and produced a defect in three
            # consecutive review rounds: it red-gated correct deploys on one dropped POST, then (once
            # transport was excluded) suppressed itself on a genuine revert whenever the SEPARATE
            # BASE_ASSET window happened to fail, letting `--require-current` exit 0 on the very
            # leftover-feed case it was added for. Two `rpc_batch` windows cannot be combined into one
            # verdict this way, and the gate that actually binds these addresses is `verify_step` 1.5,
            # which reads them itself and says so. Withdrawn rather than patched a fourth time.
            e["pointerCheck"] = f"UNREADABLE ({val})"
            continue

        ptr = "0x" + val[-40:]
        e["pointer"] = ptr
        if kind == "feed":
            e["pointerCheck"] = "OK" if ptr.lower() == proxy else f"STALE_NAV (-> {ptr})"
        else:
            # Two conditions, and the second is the one that matters. Being in the deployment record
            # is not enough — the adapter must be REGISTERED on the NAV, or the coordinate cache the
            # assistant feeds is never read. On the live stack all four assistants fail exactly here:
            # they point at adapters the PR #141 swap left behind, which have code but are not
            # registered, so submitted coordinates go into a cache the NAV ignores.
            recorded = ptr.lower() in adapters
            registered = None
            if proxy:
                try:
                    reg = c.eth_call(
                        url, proxy,
                        _sel("isAdapterRegistered(address)") + "0" * 24 + ptr[2:].lower())
                    registered = int(reg, 16) == 1
                except Exception:  # noqa: BLE001
                    registered = None
            e["adapterRegisteredOnNav"] = registered
            if not recorded:
                e["pointerCheck"] = f"STALE_ADAPTER (-> {ptr}, not in deployment record)"
            elif registered is False:
                e["pointerCheck"] = f"ORPHAN (-> {ptr} recorded but NOT registered on the NAV)"
            elif registered is None:
                # The registration call failed. Do NOT fall through to OK: the orphan case is
                # precisely what this check exists to catch, and an unanswered question is not a
                # clean answer. `--require-current` reads this status for its exit code.
                e["pointerCheck"] = (f"UNKNOWN (-> {ptr} recorded, but isAdapterRegistered could not "
                                     f"be read; re-run before trusting this)")
            else:
                e["pointerCheck"] = "OK"
        # A contract whose code is current but whose pointer is stale still has to be redeployed.
        # Reached only by entries that produced a READABLE pointer above; the N/A and UNREADABLE branches
        # both `continue` before here and set their own status (N/A deliberately leaves it CURRENT — a
        # contract that declares no NAV pointer has nothing that could be stale). An earlier revision added
        # an `N/A` exemption to THIS condition, which was dead code: the comment claimed the exemption
        # would otherwise be inert, but the `continue` already skipped this line entirely.
        if e["pointerCheck"] != "OK" and e["status"].startswith("CURRENT"):
            e["status"] = "CURRENT_CODE_STALE_POINTER"


def _feed_addresses(ret_hex: str) -> set[str]:
    """Decode a `PriceFeedConfig[]` return (static tuples of 4 words; priceFeed is the first) to its addresses.

    Decoded by hand because the drift job installs no ABI library. Raises on a malformed payload, so a reply this
    cannot read is never mistaken for an empty (unregistered) list.
    """
    raw = bytes.fromhex(ret_hex[2:] if ret_hex.startswith("0x") else ret_hex)
    if len(raw) < 64:
        raise ValueError(f"short PriceFeedConfig[] return ({len(raw)} bytes)")
    off = int.from_bytes(raw[0:32], "big")
    if off + 32 > len(raw):
        # An offset past the payload would read `n = 0` and look like an empty (unregistered) list — refuse it.
        raise ValueError(f"PriceFeedConfig[] offset {off} out of range ({len(raw)} bytes)")
    n = int.from_bytes(raw[off:off + 32], "big")
    start = off + 32
    if len(raw) < start + n * 128:
        raise ValueError(f"truncated PriceFeedConfig[] return ({n} elements, {len(raw)} bytes)")
    return {"0x" + raw[start + i * 128 + 12:start + i * 128 + 32].hex() for i in range(n)}


def check_retired_registration(chain_id: int, url: str, res: dict) -> None:
    """A STALE `retiredCustomPriceFeeds` entry is exempt from the drift gate ONLY if the live NAV no longer uses it.

    The exemption trusts the record's section label, and the record can run ahead of the chain: a feed retired in
    the record whose swap never executed (or reverted) is still a primary or monitor on the live NAV, which is
    exactly the drift this gate exists for. So for each such entry read the feed's `underlyingAssetSupported()`,
    then the NAV's `getPriceFeeds` and `getMonitorFeeds` for that asset (both return an empty array for an
    unregistered asset, never revert). Still registered -> `RETIRED_BUT_REGISTERED`; any read that fails ->
    `RETIRED_REGISTRATION_UNKNOWN`. Both are non-STALE statuses, so neither is exempt.
    """
    proxy = (c.deployment(chain_id).get("NAVCalculatorProxy") or "").lower()
    for e in res["entries"]:
        if e["status"] != "STALE" or not e["key"].startswith(f"{RETIRED_SECTION}."):
            continue
        try:
            if not c.is_address(proxy):
                raise ValueError("no NAVCalculatorProxy in the deployment record")
            word = c.eth_call(url, e["address"], _sel("underlyingAssetSupported()"))
            # Strict, like verify_step's address reads: exactly one clean, non-zero address word. A short reply or a
            # catch-all fallback returning junk would otherwise name some other asset, whose empty feed lists would
            # wrongly pass the exemption.
            if not (isinstance(word, str) and len(word) == 66 and 0 < int(word, 16) < 2**160):
                raise ValueError(f"underlyingAssetSupported() returned {word!r}, not one address word")
            asset = "0x" + word[-40:]
            arg = asset[2:].rjust(64, "0")
            live = _feed_addresses(c.eth_call(url, proxy, _sel("getPriceFeeds(address)") + arg))
            live |= _feed_addresses(c.eth_call(url, proxy, _sel("getMonitorFeeds(address)") + arg))
        except Exception as exc:  # noqa: BLE001 - an unverifiable exemption must not pass
            e["status"] = "RETIRED_REGISTRATION_UNKNOWN"
            e["detail"] = f"could not confirm the retired feed is unregistered: {exc}"
            continue
        if e["address"].lower() in live:
            e["status"] = "RETIRED_BUT_REGISTERED"
            e["detail"] = (f"retired in the record but still a feed of asset {asset} on the live NAV — the swap "
                           f"has not executed")


def audit_chain(chain_id: int, index: Index) -> dict:
    url, note, _rejected = c.probe_rpc(chain_id)
    name = c.chain_config(chain_id).get("name", "?")
    res = {"chainId": chain_id, "name": name, "rpc": note, "entries": [],
           "error": None if url else f"no RPC: {note}"}
    if not url:
        return res
    for t in c.enumerate_deployed(chain_id):
        entry = {"key": t["key"], "address": t["addr"], "expected": t.get("name")}
        try:
            code_hex = c.get_code(url, t["addr"])
        except Exception as e:  # noqa: BLE001
            entry["status"] = "RPC_ERROR"
            entry["detail"] = str(e)
            res["entries"].append(entry)
            continue
        code = bytes.fromhex(code_hex[2:]) if code_hex and code_hex != "0x" else b""
        entry["codeSize"] = len(code)
        if not code:
            entry["status"] = "NO_CODE"
        else:
            hits = index.match(code)
            entry["matched"] = [h["name"] for h in hits]
            if not hits:
                entry["status"] = "STALE"      # not produced by the current build
            elif entry["expected"] and entry["expected"] not in entry["matched"]:
                # Only the canonical top-level keys carry a real artifact-name expectation. Nested
                # keys ("customPriceFeeds.wstETH_L2") are operator config names, never contract names.
                entry["status"] = "CURRENT_UNEXPECTED_NAME"
            else:
                entry["status"] = "CURRENT"
            if len(hits) > 1:
                # Many custom feeds differ only in their immutables, so masked code is genuinely
                # shared. Ambiguity is expected and is not a failure.
                entry["ambiguous"] = True
        res["entries"].append(entry)
    check_immutable_pointers(chain_id, url, res)
    check_retired_registration(chain_id, url, res)
    return res


# Deployment-record section holding retired custom feeds (see `retire_custom_feeds.py`); its STALE verdicts are
# expected and never fail the gate.
RETIRED_SECTION = "retiredCustomPriceFeeds"


def evaluate_drift(results: list[dict], accepted: dict) -> tuple[list[str], list[str], list[str]]:
    """Decide, from audit results plus the accepted-drift map, what fails.

    Extracted from `main` so `--self-test` can exercise it offline. That split is not cosmetic: the
    first version of this guard tested only the baseline LOADER, and a review pointed out that
    nothing covered the decision — which is where the interesting mistakes live. It was right: an
    exemption written for one chain, on an address deployed identically to 23, would have passed
    every loader test while leaving the scheduled all-chain run red.

    Returns (baseline_failures, unaccepted, accepted_hits).
    """
    audited: dict[str, str] = {}
    # Chains that produced a verdict. A baseline entry for a chain OUTSIDE this set is not dangling —
    # we simply have no information about it, which is the normal case when auditing a subset
    # (`bytecode_audit.py 1`). Treating out-of-scope entries as dangling made a correct baseline fail
    # the moment anyone audited one chain, which is how this is run most of the time.
    audited_chains = {r["chainId"] for r in results if not r.get("error")}
    for r in results:
        for e in r.get("entries", []):
            audited[f"{r['chainId']}:{e['address'].lower()}"] = e["status"]

    baseline_failures: list[str] = []
    for ref, meta in sorted(accepted.items()):
        if int(ref.split(":", 1)[0]) not in audited_chains:
            continue
        status = audited.get(ref)
        if status is None:
            baseline_failures.append(
                f"baseline entry {ref} ({meta.get('key', '?')}) was not audited at all — the address is "
                f"gone from the deployment records, or its chain was out of scope. Remove the entry, or "
                f"widen the scope so it is checked.")
        elif status == "CURRENT":
            baseline_failures.append(
                f"baseline entry {ref} ({meta.get('key', '?')}) is now CURRENT — the drift it accepted is "
                f"fixed. DELETE the entry; leaving it would silently accept a FUTURE drift at this address.")

    unaccepted: list[str] = []
    accepted_hits: list[str] = []
    for r in results:
        for e in r.get("entries", []):
            if e["status"] == "CURRENT":
                continue
            ref = f"{r['chainId']}:{e['address'].lower()}"
            if e["status"] == "STALE" and str(e.get("key", "")).startswith(f"{RETIRED_SECTION}."):
                # A retired feed is kept in the record as history and is, by definition, an older generation:
                # once its feed class changes it can never match a build of this tree again. Its drift is
                # therefore expected, reported, and never a failure. Only STALE is exempt: NO_CODE or an RPC
                # error on a retired address still fails, because those mean the record itself is wrong.
                accepted_hits.append(f"{ref} {e['key']} — retired feed (older generation, expected drift)")
            elif ref in accepted:
                accepted_hits.append(f"{ref} {e['key']} — {accepted[ref].get('reason', 'no reason given')}")
            else:
                unaccepted.append(f"{ref} {e['key']} [{e['status']}]")
    return baseline_failures, unaccepted, accepted_hits


def _load_baseline(path: str | None) -> tuple[dict, list[str]]:
    """Read the accepted-drift file. Returns (entries, structural failures).

    A malformed or missing-but-named baseline is a FAILURE, never an empty dict: silently treating an
    unreadable exemption file as "nothing is exempt" would flip the gate red for the wrong reason, and
    treating it as "everything is exempt" would flip it green for a far worse one.
    """
    if not path:
        return {}, []
    f = Path(path)
    if not f.is_file():
        return {}, [f"baseline file {path} does not exist"]
    try:
        raw = json.loads(f.read_text())
    except json.JSONDecodeError as exc:
        return {}, [f"baseline file {path} is not valid JSON: {exc}"]
    entries = raw.get("accepted", raw)
    if not isinstance(entries, dict):
        return {}, [f"baseline file {path}: expected an object of '<chainId>:<address>' -> {{reason, ...}}"]
    out, problems = {}, []
    for ref, meta in entries.items():
        if ref.startswith("$"):
            continue
        if not isinstance(meta, dict) or not meta.get("reason"):
            problems.append(f"baseline entry {ref} has no 'reason' — an exemption without one is not a decision")
            continue
        try:
            cid, addr = ref.split(":", 1)
            int(cid)
        except ValueError:
            problems.append(f"baseline key {ref!r} is not '<chainId>:<address>'")
            continue
        out[f"{int(cid)}:{addr.lower()}"] = meta
    return out, problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("chains", nargs="*", type=int)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--json", help="write the full report here")
    ap.add_argument("--baseline",
                    help="JSON file of ACCEPTED drift: addresses known not to be reproduced by this build, "
                         "each with a reason. Enforced in BOTH directions — an un-baselined STALE fails, and "
                         "a baselined address that has become CURRENT also fails, so the file cannot rot into "
                         "a rubber stamp. Only meaningful with --require-current.")
    ap.add_argument("--require-current", action="store_true",
                    help="exit non-zero unless every audited address is CURRENT and every chain was "
                         "reachable — the runbook 2.2 acceptance gate. Omit for the pre-deploy run, "
                         "where widespread STALE is the expected finding, not a failure.")
    args = ap.parse_args()
    c.load_env()

    if not OUT_DIR.is_dir():
        print(f"ERROR: {OUT_DIR} not found — run `forge clean && forge build` first.")
        return 2
    artifacts = load_artifacts()
    index = Index(artifacts)
    print(f"indexed {len(artifacts)} artifacts from {OUT_DIR}")

    if args.self_test:
        return self_test(index, artifacts)

    chains, scope_src = c.resolve_chains(args.chains)
    print(f"scope: {len(chains)} chain(s) from {scope_src}")
    results = []
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for res in pool.map(lambda cid: audit_chain(cid, index), chains):
            results.append(res)
    results.sort(key=lambda r: r["chainId"])

    tally = defaultdict(int)
    for r in results:
        if r["error"]:
            print(f"  {r['chainId']:8} {r['name']:16} SKIP — {r['error']}")
            continue
        per = defaultdict(int)
        for e in r["entries"]:
            per[e["status"]] += 1
            tally[e["status"]] += 1
        summary = " ".join(f"{k}={v}" for k, v in sorted(per.items()))
        print(f"  {r['chainId']:8} {r['name']:16} {len(r['entries']):3} addrs   {summary}")
        for e in r["entries"]:
            if e["status"] not in ("CURRENT",):
                print(f"           [{e['status']}] {e['key']} {e['address']}"
                      + (f" -> {e.get('matched')}" if e.get("matched") else "")
                      + (f" ({e.get('detail')})" if e.get("detail") else ""))

    print("\n--- totals ---")
    for k, v in sorted(tally.items()):
        print(f"  {k:24} {v}")
    print("\nCURRENT = on-chain runtime code (immutables masked) is reproduced by this build.")
    print("STALE   = it is not; that address must be redeployed.")

    if args.json:
        json.dump({"results": results, "totals": dict(tally),
                   "artifactCount": len(artifacts)}, open(args.json, "w"), indent=1)
        print(f"wrote {args.json}")

    if not args.require_current:
        return 0

    # The post-deploy gate. A chain that produced no verdict counts as a failure: "no address was
    # found STALE" is worthless if the chain was never read — and equally worthless if it WAS read
    # but contributed zero addresses, which is what an empty deployment record looks like. Checking
    # only `r["error"]` misses that second case entirely: a chain whose record never got written
    # (PERSIST_DEPLOYMENTS unset, or a deploy that silently no-op'd) answers RPC fine, yields
    # `entries: []`, and would ride to PASS on the other chains' addresses.
    # ACCEPTED DRIFT. A permanently-red gate is worse than no gate: this repo has already had a check
    # that cried wolf on correct trees and taught the fleet to merge past it, which is the state in
    # which a REAL finding sails through. So known drift is declared, with a reason, and everything
    # else fails. The file is enforced BOTH ways — the same rule `undispatched-adapters.json` uses —
    # because a baseline nobody prunes stops being a record of accepted risk and becomes a blindfold.
    accepted, baseline_failures = _load_baseline(args.baseline)
    extra_failures, unaccepted, accepted_hits = evaluate_drift(results, accepted)
    baseline_failures.extend(extra_failures)
    for line in accepted_hits:
        print(f"  ACCEPTED-STALE {line}")

    skipped = [r for r in results if r["error"]]
    empty = [r for r in results if not r["error"] and not r["entries"]]
    tally_total = 0
    for v in tally.values():
        tally_total += v
    not_current = len(unaccepted)
    if not tally_total:
        print("\nFAIL: no addresses were audited at all.")
        return 1
    if baseline_failures:
        print("\nFAIL (--baseline): the accepted-drift file no longer describes reality:")
        for f in baseline_failures:
            print(f"  - {f}")
        return 1
    if skipped or empty or not_current:
        for u in unaccepted:
            print(f"  UNACCEPTED DRIFT {u}")
        print(f"\nFAIL (--require-current): {not_current} address(es) not CURRENT and not in the "
              f"accepted-drift baseline, "
              f"{len(skipped)} chain(s) unreachable "
              f"({', '.join(str(r['chainId']) for r in skipped) or 'none'}), "
              f"{len(empty)} chain(s) with an EMPTY deployment record "
              f"({', '.join(str(r['chainId']) for r in empty) or 'none'}).")
        return 1
    print(f"\nPASS (--require-current): all {tally_total} address(es) across {len(results)} chain(s) "
          f"are CURRENT or declared in the accepted-drift baseline ({len(accepted)} entr(ies)).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
