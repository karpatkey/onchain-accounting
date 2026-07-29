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
Every variable in the baseline must still be there, at the same slot and offset, with the same
structural type — where "structural" includes the interior of any struct it reaches and the length of
any fixed array. Nothing else is checked, because nothing else can break existing storage: a NEW
variable is safe wherever it lands, since if it took occupied space the previous occupant would report
MOVED or RETYPED.

That makes the documented migration work rather than merely being claimed to: shrink a gap array
(`__pricesGap`, `_gap`) and spend the freed slots. The new variables sit in the middle of the layout,
nothing moves, and the check passes. Removals, reorderings, widened types and grown structs all shift
something and are rejected.

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
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASELINE = REPO / "script/upgrade/storage-layout/NAVCalculator.json"
CONTRACT = "NAVCalculator"

# Canonicalising a type is the whole correctness of this checker, and the obvious approach is wrong.
#
# A first version regex-stripped `)\d+_storage` from forge's type strings, on the theory that the number is
# always an astId that churns on unrelated edits. It is not. In `t_struct(Asset)14419_storage` it IS an astId;
# in `t_array(t_uint256)48_storage` it is the array LENGTH. One pattern, two meanings, so the regex silently
# erased gap-array sizes — `uint256[48]` and `uint256[43]` normalised identically, making the one migration
# this file documents as safe completely unobservable. It was also incomplete: `t_contract(...)45` and
# `t_enum(...)13835` do not end in `_storage`, so those astIds survived and produced spurious RETYPED reports
# on untouched variables, whose printed remedy (--regenerate) then baselined away any real violation too.
#
# Worse, the type STRING says nothing about a struct's interior. `_priceOracles` is
# `t_mapping(t_address,t_array(t_struct(PriceFeedConfig)…)dyn_storage)`; inserting a field into
# PriceFeedConfig leaves that string byte-identical while every member behind it shifts. A checker built on
# the strings alone reports COMPATIBLE for the single most likely incompatible edit in this repo.
#
# So types are resolved through forge's `types` dictionary instead, which carries what actually matters and no
# astIds: `label` is human-readable and length-bearing (`uint256[48]`, `struct IPrices.PriceFeedConfig`),
# `numberOfBytes` and `encoding` pin the physical shape, and `members` gives each struct field its own slot and
# offset. Expanding those recursively yields a signature that changes exactly when the storage meaning changes.

_MAX_DEPTH = 12


def canonical(type_key: str, types: dict, depth: int = 0) -> str:
    """A structural signature for a type: astId-free, length-preserving, struct-interior-aware."""
    t = types.get(type_key)
    if t is None:
        # Unresolvable: fall back to the raw key rather than silently treating it as equal to anything else.
        return f"<unresolved:{type_key}>"
    if depth >= _MAX_DEPTH:
        return f"{t.get('label')}|depth-capped"
    parts = [str(t.get("label")), f"b={t.get('numberOfBytes')}", f"e={t.get('encoding')}"]
    if "base" in t:
        parts.append("base=" + canonical(t["base"], types, depth + 1))
    if "value" in t:  # mappings
        parts.append("key=" + str(t.get("key")))
        parts.append("val=" + canonical(t["value"], types, depth + 1))
    for m in t.get("members") or []:
        parts.append(
            f"m[{m.get('label')}@{m.get('slot')}+{m.get('offset')}]=" + canonical(m["type"], types, depth + 1)
        )
    return "{" + ";".join(parts) + "}"


def current_layout() -> list[dict]:
    out = subprocess.run(
        ["forge", "inspect", CONTRACT, "storage-layout", "--json"],
        cwd=REPO, capture_output=True, text=True,
    )
    if out.returncode != 0:
        print(f"ERROR: `forge inspect` failed:\n{out.stderr[-2000:]}", file=sys.stderr)
        sys.exit(2)
    doc = json.loads(out.stdout)
    types = doc.get("types") or {}
    return [_entry(e, types) for e in doc["storage"]]


def _entry(e: dict, types: dict) -> dict:
    """One storage entry, plus structured fixed-array facts so compare() never parses a signature."""
    out = {"slot": e["slot"], "offset": e["offset"], "label": e["label"],
           "type": canonical(e["type"], types)}
    t = types.get(e["type"]) or {}
    # A fixed-size array records its length in `label` (`uint256[48]`) and its element type in `base`.
    # Gap arrays are exactly this shape, and shrinking one is the sanctioned way to add storage, so the
    # length has to be legible to compare() rather than buried in the signature string.
    lbl = str(t.get("label") or "")
    if t.get("encoding") == "inplace" and "base" in t and lbl.endswith("]") and "[" in lbl:
        n = lbl[lbl.rindex("[") + 1:-1]
        if n.isdigit():
            out["fixedArrayLen"] = int(n)
            out["fixedArrayBase"] = canonical(t["base"], types)
    return out


def load_baseline() -> list[dict]:
    if not BASELINE.is_file():
        print(f"ERROR: no baseline at {BASELINE}", file=sys.stderr)
        sys.exit(2)
    return json.loads(BASELINE.read_text())["storage"]


def compare(base: list[dict], new: list[dict], notes: list[str] | None = None) -> list[str]:
    """Return incompatibility messages; empty means compatible. `notes` collects benign observations."""
    problems: list[str] = []
    notes = notes if notes is not None else []
    by_label_new = {e["label"]: e for e in new}

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
            # ONE narrow exemption: a fixed array of the same element type, at the same slot and offset,
            # that got SHORTER. That is a reserved gap being spent — the documented way to add storage
            # here — and it cannot misread anything: the array's own slots are untouched, and if a freed
            # slot were already occupied by something else, that something would report MOVED above.
            # A LENGTHENED array is not exempt: it would overrun whatever follows it.
            shrunk = (
                e.get("fixedArrayLen") is not None
                and got.get("fixedArrayLen") is not None
                and e.get("fixedArrayBase") == got.get("fixedArrayBase")
                and got["fixedArrayLen"] < e["fixedArrayLen"]
            )
            if shrunk:
                notes.append(
                    f"gap consumed: `{e['label']}` at slot {e['slot']} shrank from "
                    f"{e['fixedArrayLen']} to {got['fixedArrayLen']} element(s), freeing "
                    f"{e['fixedArrayLen'] - got['fixedArrayLen']} slot(s). Nothing after it moved.")
            else:
                problems.append(
                    f"RETYPED: `{e['label']}` at slot {e['slot']} was `{e['type']}`, now `{got['type']}`. "
                    f"Same slot, different interpretation of the bytes already in it.")

    # There is deliberately NO "new variable below the highest baseline slot" rule.
    #
    # An earlier version rejected any new label at or below the top baseline slot, which fails the one
    # migration this module documents as safe: shrinking a gap array and spending the freed slots. Those
    # new variables land in the middle of the layout by construction, and nothing has moved.
    #
    # The rule was also redundant. A new variable can only be unsafe if it takes a slot/offset something
    # else already occupies — and then that occupant reports MOVED or RETYPED above. Inserting into space
    # the previous layout reserved (a gap) or never used (free bytes in a partly-filled slot) touches only
    # bytes that were always zero. So the three checks above are exactly the condition, and adding a
    # position rule on top of them only produced false failures — whose printed remedy was `--regenerate`,
    # which would have erased any genuine violation present in the same run.
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--print", action="store_true", dest="show")
    ap.add_argument("--force", action="store_true",
                    help="with --regenerate: overwrite even when real incompatibilities were found")
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
        # Compare FIRST. Rewriting the baseline is how a real incompatibility gets laundered into a
        # clean run, and the previous version did it unconditionally, printed nothing about what it was
        # erasing, and exited 0 — so the tree kept no trace that a violation had ever been detected.
        problems = compare(load_baseline(), new) if BASELINE.is_file() else []
        if problems and not args.force:
            print(f"REFUSING TO REGENERATE: {len(problems)} incompatibility(ies) would be erased.\n")
            for pr in problems:
                print(f"  * {pr}")
            print("\nRegenerating now would overwrite the record of a layout the deployed proxies still "
                  "use, and the resulting baseline diff would look like any reviewed change.\n"
                  "If this really is a deliberate, migrated layout change, re-run with --force and say "
                  "in the PR which of the above you are accepting and why.")
            return 1
        doc = json.loads(BASELINE.read_text()) if BASELINE.is_file() else {"contract": CONTRACT}
        doc["storage"] = new
        BASELINE.write_text(json.dumps(doc, indent=1) + "\n")
        print(f"rewrote {BASELINE.relative_to(REPO)} with {len(new)} entries.")
        if problems:
            print(f"FORCED over {len(problems)} incompatibility(ies) — every one of them must be named "
                  f"and justified in the PR description.")
        print("Commit it WITH the source change that justifies it.")
        return 0

    base = load_baseline()
    notes: list[str] = []
    problems = compare(base, new, notes)
    added = [e for e in new if e["label"] not in {b["label"] for b in base}]

    print(f"baseline: {len(base)} entries   current: {len(new)} entries")
    if added:
        # Deliberately "added", not "appended": since the position rule was removed, a new variable may
        # legitimately sit mid-layout in slots freed by a shrunk gap.
        print(f"\nadded (new variables; position is not itself a violation):")
        for e in added:
            print(f"  + slot {e['slot']:>4} +{e['offset']:<2} {e['label']:<34} {e['type']}")

    for n in notes:
        print(f"\n  note: {n}")

    if problems:
        print(f"\nINCOMPATIBLE — {len(problems)} problem(s). A UUPS upgrade keeps the proxy's storage "
              f"and swaps only the code, so each of these silently reinterprets live state:\n")
        for p in problems:
            print(f"  * {p}")
        print("\nDo NOT upgrade. Either restore the layout (append only, consuming a gap array), or "
              "regenerate the baseline in the same commit as a reviewed, deliberate migration.")
        return 1

    print("\nCOMPATIBLE: every baseline variable keeps its slot, offset and type"
          + (f"; {len(added)} added." if added else "; nothing added."))
    # The token the Solidity gate demands. Printed ONLY on a passing run, and keyed to the baseline file, so
    # it cannot be guessed as a constant and a copy parked in `.env` stops working the moment the baseline
    # changes. It attests "the check ran against this baseline", never "the source is compatible".
    from eth_utils import keccak
    token = "0x" + keccak(BASELINE.read_bytes()).hex()
    print(f"\nPass this to the upgrade script:\n  STORAGE_LAYOUT_VERIFIED={token}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
