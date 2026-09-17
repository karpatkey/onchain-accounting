#!/usr/bin/env python3
"""Two source gates that no build, test or reviewer reliably catches.

GATE 1 — `file:line` references in `src/` comments
--------------------------------------------------
A comment that says `Balances.sol:191` is correct on the day it is written and silently wrong the next
time anyone inserts a line above it. Nothing recompiles a comment, so the drift is invisible until a
reader follows the pointer to an unrelated function and believes what they find.

This is not hypothetical and it is not rare. When this gate was written, THREE of the four such
references in `src/` were already stale or false:

  * `NAVRegistryLib` pointed at `Balances.sol:191` for reasoning that had moved ~30 lines.
  * `ETHx_CrossRateCustomPriceFeed` pointed at `03_DeployPriceFeeds.s.sol:211` for
    `_deployEthxCrossRate`, which is at line 934; line 211 is the sGHO block.
  * `WalletTokenMetaBalanceAdapterBase` cited `NAVCalculator.sol:181` for the claim that `registerAsset`
    "unconditionally" arms the default adapter — a claim that had become FALSE, not merely misnumbered.

Name the symbol instead. `NAVRegistryLib._claim` survives edits; `NAVRegistryLib.sol:452` does not.

GATE 2 — new raw `.staticcall(` outside the metered helpers
-----------------------------------------------------------
An unmetered raw staticcall forwards 63/64 of the frame and absorbs its own out-of-gas as `ok == false`.
A caller that reads that as "the call failed, fail closed" returns SUCCESSFULLY from a starved read, so
the holding leaves NAV with no health flag — an over- or under-report with nothing to attribute it to.
One such read was measured at 1.05e9 gas before it was capped (#168).

This gate is a RATCHET, not a ban. The 27 call sites that existed when it was added are allowlisted by
file with their exact counts: they are real, several are already metered, and rewriting all of them
inside an unrelated change would be a worse risk than leaving them visible. What the gate stops is the
class GROWING — a new file reaching for a raw staticcall, or an existing file quietly gaining one — which
is the only part that was ever unbounded.

To change an allowlisted count deliberately, edit STATICCALL_ALLOWLIST in the same commit and say why.

usage:
  python3 script/deploy/preflight/source_comment_gates.py              # run both gates
  python3 script/deploy/preflight/source_comment_gates.py --self-test  # pin the detectors
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SRC = REPO / "src"

# A `path.ext:NNN` reference. Requires a real source extension so that ordinary prose ("ADR 0010:2",
# "issue #335", a URL with a port) is not swept up.
FILE_LINE = re.compile(r"[A-Za-z0-9_./-]+\.(?:sol|json|py|ts|md|toml|ya?ml):\d+")

# Only comments — a `:` inside a string literal or a revert message is not a doc reference.
COMMENT = re.compile(r"(?://.*|/\*[\s\S]*?\*/)")

# Files permitted raw `.staticcall(`, with the exact count each had when the ratchet was set. A count
# that RISES fails; a count that falls is progress and fails too, so the number stays honest.
STATICCALL_ALLOWLIST = {
    "src/balances/MetaBalanceAdapters/curve/CurvePoolLib.sol": 14,
    "src/balances/MetaBalanceAdapters/FluidVaultLib.sol": 2,
    "src/balances/MetaBalanceAdapters/AaveV3InstancesMetaBalanceAdapter.sol": 2,
    "src/balances/BalanceAdapters/SparkLendBalanceAdapter.sol": 2,
    "src/prices/PriceFeedLib.sol": 1,
    "src/balances/MetaBalanceAdapters/curve/CurvePoolsMetaBalanceAdapter.sol": 1,
    "src/balances/MetaBalanceAdapters/WalletTokenMetaBalanceAdapterBase.sol": 1,
    "src/balances/MetaBalanceAdapters/CompoundV3CometLib.sol": 1,
    "src/balances/MetaBalanceAdapter.sol": 1,
    "src/balances/AttestedBalanceAdapters/AttestedValueCache.sol": 1,
    "src/utils/StaticCallLib.sol": 0,  # the sanctioned home; counted so a change here is still visible
}


def find_file_line_refs(text: str) -> list[str]:
    """Every `path.ext:NNN` appearing inside a comment."""
    hits: list[str] = []
    for c in COMMENT.finditer(text):
        hits.extend(FILE_LINE.findall(c.group(0)))
    return hits


def count_staticcalls(text: str) -> int:
    """Raw `.staticcall(` outside comments."""
    return COMMENT.sub("", text).count(".staticcall(")


def run() -> int:
    problems: list[str] = []

    refs_found = 0
    counts: dict[str, int] = {}
    for f in sorted(SRC.rglob("*.sol")):
        rel = f.relative_to(REPO).as_posix()
        text = f.read_text(encoding="utf-8")

        for ref in find_file_line_refs(text):
            refs_found += 1
            problems.append(f"  {rel}: comment cites `{ref}` — name the symbol, not the line")

        n = count_staticcalls(text)
        if n:
            counts[rel] = n

    for rel, n in sorted(counts.items()):
        allowed = STATICCALL_ALLOWLIST.get(rel)
        if allowed is None:
            problems.append(f"  {rel}: {n} raw `.staticcall(` in a file with no allowance — use a metered helper")
        elif n != allowed:
            problems.append(f"  {rel}: raw `.staticcall(` count is {n}, allowlisted at {allowed}")
    for rel, allowed in sorted(STATICCALL_ALLOWLIST.items()):
        if allowed and rel not in counts:
            problems.append(f"  {rel}: allowlisted at {allowed} raw `.staticcall(` but has none — drop the entry")

    if problems:
        print("SOURCE GATES FAILED:\n" + "\n".join(problems))
        return 1
    print(f"source gates OK: 0 file:line refs in src/ comments; raw .staticcall( matches the allowlist")
    return 0


def self_test() -> int:
    """Pin the detectors. A gate whose regex silently matches nothing is worse than no gate."""
    cases = [
        ("// see Balances.sol:191", 1, "bare ref in a line comment"),
        ("/// @dev see `NAVRegistryLib.sol:452` for why", 1, "ref in a NatSpec comment, backticked"),
        ("/* block\n * Foo.sol:12\n */", 1, "ref in a block comment"),
        ("// see ADR 0010 and issue #335", 0, "prose with numbers is not a ref"),
        ('string memory s = "Foo.sol:12";', 0, "a string literal is not a comment"),
        ("// http://localhost:8545 is fine", 0, "a URL port is not a file ref"),
        ("// see script/deploy/03_DeployPriceFeeds.s.sol:211", 1, "a path with directories"),
    ]
    failures = []
    for text, want, why in cases:
        got = len(find_file_line_refs(text))
        if got != want:
            failures.append(f"  file:line detector: expected {want} got {got} — {why}: {text!r}")

    sc_cases = [
        ("(bool ok,) = t.staticcall(data);", 1, "a real raw staticcall"),
        ("// (bool ok,) = t.staticcall(data);", 0, "a commented-out one does not count"),
        ("/* t.staticcall( */", 0, "block-commented"),
        ("t.call(data);", 0, "a plain call is not a staticcall"),
    ]
    for text, want, why in sc_cases:
        got = count_staticcalls(text)
        if got != want:
            failures.append(f"  staticcall detector: expected {want} got {got} — {why}: {text!r}")

    if failures:
        print("SELF-TEST FAILED:\n" + "\n".join(failures))
        return 1
    print(f"self-test OK: {len(cases)} file:line cases, {len(sc_cases)} staticcall cases")
    return 0


if __name__ == "__main__":
    sys.exit(self_test() if "--self-test" in sys.argv else run())
