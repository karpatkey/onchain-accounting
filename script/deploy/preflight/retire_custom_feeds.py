#!/usr/bin/env python3
"""Retire named custom price feeds in a deployment record, so `03_DeployPriceFeeds` redeploys exactly those.

WHY THIS EXISTS
---------------
`03_DeployPriceFeeds` is skip-if-already-deployed: a feed whose `customPriceFeeds.<key>` holds an address is
left alone. Redeploying a SUBSET of feeds (the ADR 0029 feeds that now carry a stale price instead of zeroing)
therefore needs exactly those keys blanked, and nothing else touched.

`reset_deployment_records.py` is the wrong tool for that: it is built for a from-scratch redeploy and blanks the
NAV proxy, implementation, libraries, AssetKindRegistry, every balance adapter and every custom feed (monitors
included). A mis-run there would make `02_2` deploy a fresh proxy. This tool can only touch the named
`customPriceFeeds` keys, and refuses everything else.

WHAT IT DOES, PER KEY
---------------------
1. Moves the current address to `retiredCustomPriceFeeds.<key>` with a dated `$<key>` note (the record keeps
   every address it ever deployed, the same pattern as the OETH entry). If `<key>` was already retired before,
   the older entry is kept under `<key>@<date>` (then `<key>@<date>#2`, `#3`, ... for further retirements on the
   same date) rather than overwritten. `<date>` is the day it was displaced; its `$` note keeps its own date.
2. Blanks `customPriceFeeds.<key>` to "" (the key is kept, never deleted).

Refuses: a key that is not in `customPriceFeeds`, a key that is already blank, and any key that names a
top-level or `balanceAdapters` entry. Writes nothing unless `--apply` is given.

usage:
  python3 retire_custom_feeds.py --chain 1 --keys wstETH,sDAI --reason "ADR 0029 redeploy"           # dry run
  python3 retire_custom_feeds.py --chain 1 --keys wstETH,sDAI --reason "ADR 0029 redeploy" --apply
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from pathlib import Path

import chainlib as c

SECTION = "customPriceFeeds"
ARCHIVE = "retiredCustomPriceFeeds"
ARCHIVE_COMMENT = (
    "Deployed feed contracts no longer configured as NAV price sources. A SIBLING of customPriceFeeds, not a "
    "member of it, so a reset of customPriceFeeds can never destroy the retirement record."
)


class RetireError(Exception):
    """Raised instead of `assert`, so the guards survive `python3 -O` (the CI preflight flag)."""


def plan(record: dict, keys: list[str]) -> list[tuple[str, str]]:
    """Validate the request against the record; return [(key, address)] to retire. Never mutates."""
    feeds = record.get(SECTION)
    if not isinstance(feeds, dict):
        raise RetireError(f"record has no '{SECTION}' section")
    out: list[tuple[str, str]] = []
    for key in keys:
        if key.startswith("$") or key in record:
            raise RetireError(f"'{key}' is a top-level record entry or a note, not a custom feed: refusing")
        if key in record.get("balanceAdapters", {}):
            raise RetireError(f"'{key}' is a balance adapter, not a custom feed: refusing")
        if key not in feeds:
            raise RetireError(f"'{key}' is not in {SECTION}")
        addr = feeds[key]
        if not isinstance(addr, str) or not c.is_address(addr):
            raise RetireError(f"{SECTION}.{key} holds no address ({addr!r}): nothing to retire")
        out.append((key, addr))
    if len({k for k, _ in out}) != len(out):
        raise RetireError("duplicate key in --keys")
    return out


def _free_slot(archive: dict, key: str, today: str) -> str:
    """The first unused dated slot for an older retirement of `key`: `<key>@<today>`, then `<key>@<today>#2`, ...

    The date is the day the older entry was DISPLACED (today), not the day it was retired; its moved `$` note
    keeps the original "RETIRED <date>". Retiring the same key more than once on one day (a redeploy that is
    retried) must not overwrite the earlier dated entry, or that deployment's address would vanish.
    """
    slot, n = f"{key}@{today}", 1
    while slot in archive or f"${slot}" in archive:
        n += 1
        slot = f"{key}@{today}#{n}"
    return slot


def apply(record: dict, retire: list[tuple[str, str]], reason: str, today: str) -> dict:
    """Return a NEW record with the keys retired. Only customPriceFeeds and retiredCustomPriceFeeds change."""
    new = json.loads(json.dumps(record))
    archive = new.setdefault(ARCHIVE, {"$comment": ARCHIVE_COMMENT})
    for key, addr in retire:
        if key in archive:
            slot = _free_slot(archive, key, today)
            archive[slot] = archive.pop(key)
            if f"${key}" in archive:
                archive[f"${slot}"] = archive.pop(f"${key}")
        archive[key] = addr
        archive[f"${key}"] = f"RETIRED {today}. {reason} The contract is still deployed at the address above."
        new[SECTION][key] = ""
    return new


def changed_sections(before: dict, after: dict) -> set[str]:
    return {k for k in set(before) | set(after) if before.get(k) != after.get(k)}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--chain", type=int, required=True)
    ap.add_argument("--keys", required=True, help="comma-separated customPriceFeeds keys")
    ap.add_argument("--reason", required=True, help="why these feeds are retired (goes into the $<key> note)")
    ap.add_argument("--apply", action="store_true", help="write the record (default: dry run)")
    ap.add_argument("--record", type=Path, help="override the record path (tests)")
    a = ap.parse_args(argv)

    path = a.record or (c.DEPLOY_DIR / f"{a.chain}.json")
    record = json.loads(path.read_text())
    keys = [k.strip() for k in a.keys.split(",") if k.strip()]
    try:
        retire = plan(record, keys)
        new = apply(record, retire, a.reason, dt.date.today().isoformat())
        touched = changed_sections(record, new)
        if not touched <= {SECTION, ARCHIVE}:
            raise RetireError(f"internal: would change {sorted(touched)}")
    except RetireError as e:
        print(f"REFUSED: {e}", file=sys.stderr)
        return 2
    for key, addr in retire:
        print(f"  {key}: {addr} -> {ARCHIVE}.{key}; {SECTION}.{key} = \"\"")
    if not a.apply:
        print(f"dry run: {len(retire)} key(s) would be retired in {path}. Re-run with --apply.")
        return 0
    # ensure_ascii=False: keep the record's existing non-ASCII characters as they are (no `\uXXXX` diff noise).
    path.write_text(json.dumps(new, indent=2, ensure_ascii=False) + "\n")
    print(f"retired {len(retire)} key(s) in {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
