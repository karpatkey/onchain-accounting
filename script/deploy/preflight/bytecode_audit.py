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
    # indistinguishable from the stale old-generation pointer this check exists to catch. `verify_step`
    # makes the same distinction; the two tools must agree or the operator gets contradictory evidence.
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
        # "N/A (BASE_ASSET() == 0, ...)" is a CLASSIFICATION, not a failure: the contract itself declares
        # it has no NAV pointer, so there is nothing that could be stale. Without this the exemption added
        # above is inert — the status rewrite below would still mark the feed CURRENT_CODE_STALE_POINTER
        # and `--require-current` would still exit 1 on a correct deploy.
        if e["pointerCheck"] != "OK" and not e["pointerCheck"].startswith("N/A") \
                and e["status"].startswith("CURRENT"):
            e["status"] = "CURRENT_CODE_STALE_POINTER"


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
    return res


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("chains", nargs="*", type=int)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--json", help="write the full report here")
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
    skipped = [r for r in results if r["error"]]
    empty = [r for r in results if not r["error"] and not r["entries"]]
    not_current = tally_total = 0
    for k, v in tally.items():
        tally_total += v
        if k != "CURRENT":
            not_current += v
    if not tally_total:
        print("\nFAIL: no addresses were audited at all.")
        return 1
    if skipped or empty or not_current:
        print(f"\nFAIL (--require-current): {not_current} address(es) not CURRENT, "
              f"{len(skipped)} chain(s) unreachable "
              f"({', '.join(str(r['chainId']) for r in skipped) or 'none'}), "
              f"{len(empty)} chain(s) with an EMPTY deployment record "
              f"({', '.join(str(r['chainId']) for r in empty) or 'none'}).")
        return 1
    print(f"\nPASS (--require-current): all {tally_total} address(es) across {len(results)} chain(s) "
          f"are CURRENT.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
