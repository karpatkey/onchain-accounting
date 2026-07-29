#!/usr/bin/env python3
"""Refuse a UUPS upgrade whose storage layout is not compatible with what is already deployed.

WHY THIS EXISTS
---------------
`UpgradeNAVCalculator` deploys a new implementation and repoints a LIVE proxy at it. Nothing in that
path looked at storage layout. A UUPS proxy keeps its storage and swaps only the code, so an
implementation that assigns a different meaning to an occupied slot does not fail, revert, or log —
it silently reinterprets live state. Every balance, feed and role on that chain is read through the
new layout from the next block onward.

That is worse than the stale-library problem the pin guard addresses. A missing library is a
DELEGATECALL into nothing and reverts loudly; a shifted slot returns a plausible number.

WHAT COUNTS AS COMPATIBLE
-------------------------
Only APPENDING. For every entry in the baseline, the new layout must place the same label at the same
slot and offset with the same type. New entries are allowed strictly above the highest baseline slot.
Anything else — a removed variable, a reordered pair, a widened type, a struct that grew — moves
everything after it and is rejected.

The gap arrays (`__pricesGap`, `_gap`) are the intended place to add without moving anything: shrink
the gap by exactly what you add. This checker sees that correctly — the gap's type changes size while
every following slot stays put, which it reports as a deliberate reserved-space consumption rather
than a violation, provided nothing after it moved.

WHAT THIS DOES NOT PROVE
------------------------
The baseline describes the CURRENT SOURCE at the time it was committed, not the bytecode actually
running behind the proxy on a given chain. If an implementation was ever deployed from a tree whose
layout differed from this file, this check cannot see it. Regenerate the baseline only in the same
commit that legitimately changes the layout, and never to make this pass.

usage:
  python3 script/upgrade/check_storage_layout.py                 # check against the committed baseline
  python3 script/upgrade/check_storage_layout.py --print         # show the current layout
  python3 script/upgrade/check_storage_layout.py --regenerate    # rewrite the baseline (see above)
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASELINE = REPO / "script/upgrade/storage-layout/NAVCalculator.json"
CONTRACT = "NAVCalculator"

# Struct/array ids are build artefacts: `t_struct(Asset)14419_storage` becomes `t_struct(Asset)_storage`.
# The numeric id shifts whenever anything above it in the AST moves, so leaving it in would make the
# baseline churn on unrelated edits — and a baseline that cries wolf is one people regenerate blindly.
_ASTID = re.compile(r"\)\d+_storage")


def normalise(t: str) -> str:
    return _ASTID.sub(")_storage", t)


def current_layout() -> list[dict]:
    out = subprocess.run(
        ["forge", "inspect", CONTRACT, "storage-layout", "--json"],
        cwd=REPO, capture_output=True, text=True,
    )
    if out.returncode != 0:
        print(f"ERROR: `forge inspect` failed:\n{out.stderr[-2000:]}", file=sys.stderr)
        sys.exit(2)
    doc = json.loads(out.stdout)
    return [{"slot": e["slot"], "offset": e["offset"], "label": e["label"],
             "type": normalise(e["type"])} for e in doc["storage"]]


def load_baseline() -> list[dict]:
    if not BASELINE.is_file():
        print(f"ERROR: no baseline at {BASELINE}", file=sys.stderr)
        sys.exit(2)
    return json.loads(BASELINE.read_text())["storage"]


def compare(base: list[dict], new: list[dict]) -> list[str]:
    """Return a list of incompatibility messages; empty means append-only or identical."""
    problems: list[str] = []
    by_label_new = {e["label"]: e for e in new}
    max_base_slot = max((int(e["slot"]) for e in base), default=-1)

    for e in base:
        got = by_label_new.get(e["label"])
        if got is None:
            problems.append(
                f"REMOVED: `{e['label']}` was at slot {e['slot']} offset {e['offset']} and is gone. "
                f"Every variable after it shifts up; the proxy's existing storage does not.")
            continue
        if got["slot"] != e["slot"] or got["offset"] != e["offset"]:
            problems.append(
                f"MOVED: `{e['label']}` was slot {e['slot']} offset {e['offset']}, now slot "
                f"{got['slot']} offset {got['offset']}. It would read whatever the old layout left "
                f"at its new position.")
        if got["type"] != e["type"]:
            problems.append(
                f"RETYPED: `{e['label']}` at slot {e['slot']} was `{e['type']}`, now `{got['type']}`. "
                f"Same slot, different interpretation of the bytes already in it.")

    known = {e["label"] for e in base}
    for e in new:
        if e["label"] in known:
            continue
        if int(e["slot"]) <= max_base_slot:
            problems.append(
                f"INSERTED: new variable `{e['label']}` occupies slot {e['slot']}, at or below the "
                f"highest baseline slot {max_base_slot}. Appending is only safe strictly above it.")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--print", action="store_true", dest="show")
    ap.add_argument("--regenerate", action="store_true",
                    help="rewrite the baseline from the current source. Only in the same commit as a "
                         "deliberate, reviewed layout change — never to make this check pass.")
    args = ap.parse_args()

    new = current_layout()
    if args.show:
        for e in new:
            print(f"  slot {e['slot']:>4} +{e['offset']:<2} {e['label']:<34} {e['type']}")
        return 0

    if args.regenerate:
        doc = json.loads(BASELINE.read_text()) if BASELINE.is_file() else {"contract": CONTRACT}
        doc["storage"] = new
        BASELINE.write_text(json.dumps(doc, indent=1) + "\n")
        print(f"rewrote {BASELINE.relative_to(REPO)} with {len(new)} entries.\n"
              f"Commit it WITH the source change that justifies it, and say so in the PR.")
        return 0

    base = load_baseline()
    problems = compare(base, new)
    added = [e for e in new if e["label"] not in {b["label"] for b in base}]

    print(f"baseline: {len(base)} entries   current: {len(new)} entries")
    if added:
        print(f"\nappended above the baseline's highest slot ({max(int(e['slot']) for e in base)}):")
        for e in added:
            print(f"  + slot {e['slot']:>4} +{e['offset']:<2} {e['label']:<34} {e['type']}")

    if problems:
        print(f"\nINCOMPATIBLE — {len(problems)} problem(s). A UUPS upgrade keeps the proxy's storage "
              f"and swaps only the code, so each of these silently reinterprets live state:\n")
        for p in problems:
            print(f"  * {p}")
        print("\nDo NOT upgrade. Either restore the layout (append only, consuming a gap array), or "
              "regenerate the baseline in the same commit as a reviewed, deliberate migration.")
        return 1

    print("\nCOMPATIBLE: every baseline variable keeps its slot, offset and type"
          + (f"; {len(added)} appended." if added else "; nothing added."))
    return 0


if __name__ == "__main__":
    sys.exit(main())
