#!/usr/bin/env python3
"""Guard that `script/deploy/DEPLOYED_ADDRESSES.md` agrees with the deployment records.

WHY THIS EXISTS. Twice in two days a published address table was found naming contracts from a superseded
deployment — 66 of 93 entries in this very file, and the whole balance-adapter table in the GitBook. Both
were caught by a human noticing, not by a check. The failure is quiet in the worst way: a stale adapter
address still has code, so an integrator reading the doc calls a live contract that the NAV does not use
and gets zeroes rather than an error.

The tables are mechanically derivable from `script/config/deployments/<chainId>.json`, which the repo
already treats as the only place deployed addresses live. So drift is detectable, and this makes it fail
the build instead of waiting to be noticed.

WHAT IT CHECKS, in both directions and per chain:

  * PUBLISHED-BUT-NOT-DEPLOYED — an address under "### Base (8453)" must be recorded for chain 8453. Any
    address absent from that chain's record is stale, MISATTRIBUTED (a mainnet address printed under
    another chain), or invented. All three are the same defect to a reader.
  * DEPLOYED-BUT-NOT-PUBLISHED — every adapter and feed the record holds for a documented chain must
    appear under it. This is the half that would have caught Polygon's Fluid row: the address was not
    wrong, it was missing, and a one-directional check calls that a pass.

WHAT IT DOES NOT CHECK, said plainly so nobody reads more assurance into a green run than it earns:

  * It does not touch a chain. It compares two files in the repo. A record that itself disagrees with the
    chain passes here — `verify_step.py` is what compares records to chain state.
  * It does not police prose. Only the per-chain tables are parsed; a stale address written into a
    sentence or a hint block is invisible to it.
  * It does not cover the GitBook, which is a different repository. That doc has the same failure mode and
    needs its own guard.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
DOC = REPO / "script" / "deploy" / "DEPLOYED_ADDRESSES.md"
RECORDS = REPO / "script" / "config" / "deployments"

# Sections whose tables are per-chain and therefore checkable. The canonical-layer tables above them are
# deliberately excluded: those addresses are identical fleet-wide and are not filed under a chain heading.
PER_CHAIN_SECTIONS = (
    "## Balance adapters",
    "## Assisted-adapter assistants",
    "## Custom price feeds",
)

CHAIN_HEADING = re.compile(r"^###\s+.*\((\d+)\)\s*$")
TABLE_ROW = re.compile(r"^\|\s*([^|]+?)\s*\|\s*\[?`(0x[a-fA-F0-9]{40})`")
ADDRESS_IN_CELL = re.compile(r"`(0x[a-fA-F0-9]{40})`")

# `ERC20Default` is minted inside `initialize()` and documented in the canonical layer, so it is recorded
# per chain but deliberately absent from the per-chain tables.
NOT_PUBLISHED_PER_CHAIN = {"ERC20Default"}

# Canonical-layer entries: one address fleet-wide, documented above the per-chain tables rather than in
# them. Recorded per chain because the record is per chain, not because each chain has its own.
CANONICAL_LAYER = {
    "NAVCalculatorProxy",
    "NAVCalculatorImplementation",
    "BridgeEscrowImplementation",
    "PriceFeedLib",
    "NavRegistryLib",
    "AssetKindRegistry",
    "TimelockController",
}

# Maps of contracts that are deployed but SUPERSEDED. These must never be published: a reader scanning for
# an address must not meet one they are not supposed to call, and a retired feed still answers, so naming
# it would hand out plausible numbers the NAV no longer uses. Publishing one is an error in the other
# direction — see `check`.
RETIRED_MAPS = {"retiredCustomPriceFeeds"}


def recorded_addresses(chain_id: str) -> dict[str, str]:
    """Every deployed address the record holds for one chain, keyed by name.

    Reads the nested adapter/feed maps AND the top-level keys. That is not tidiness: the assisted-adapter
    assistants live at the top level rather than under `balanceAdapters`, and a sweep that walked only the
    nested maps is exactly how their four addresses stayed stale through an earlier cleanup.
    """
    path = RECORDS / f"{chain_id}.json"
    if not path.exists():
        return {}
    data = json.loads(path.read_text())
    out: dict[str, str] = {}
    for key, value in data.items():
        if key in RETIRED_MAPS:
            continue
        if isinstance(value, str) and value.startswith("0x") and len(value) == 42:
            out[key] = value
        elif isinstance(value, dict):
            for name, addr in value.items():
                if isinstance(addr, str) and addr.startswith("0x") and len(addr) == 42:
                    out[name] = addr
    return out


def retired_addresses(chain_id: str) -> dict[str, str]:
    """Superseded addresses for one chain. Publishing any of these is a failure."""
    path = RECORDS / f"{chain_id}.json"
    if not path.exists():
        return {}
    data = json.loads(path.read_text())
    out: dict[str, str] = {}
    for key in RETIRED_MAPS:
        for name, addr in (data.get(key) or {}).items():
            if isinstance(addr, str) and addr.startswith("0x"):
                out[name] = addr
    return out


def published_by_chain(doc_text: str) -> dict[str, dict[str, str]]:
    """Parse the per-chain tables into {chainId: {name: address}}."""
    lines = doc_text.split("\n")
    section_starts = [i for i, line in enumerate(lines) if line.startswith(PER_CHAIN_SECTIONS)]
    if not section_starts:
        raise SystemExit("published_addresses_guard: no per-chain sections found — has the doc been restructured?")

    out: dict[str, dict[str, str]] = {}
    for start in section_starts:
        end = next(
            (i for i in range(start + 1, len(lines)) if lines[i].startswith("## ") and i != start),
            len(lines),
        )
        chain: str | None = None
        for line in lines[start:end]:
            heading = CHAIN_HEADING.match(line)
            if heading:
                chain = heading.group(1)
                continue
            row = TABLE_ROW.match(line)
            if row and chain:
                # ★ = identical on every chain; ☆ = CREATE2 but shared only across the chains that share the
                # adapter's protocol address; † = deployed but not registered on the NAV. All are display
                # markers, never part of the recorded key. Whitespace is collapsed rather than merely stripped
                # because an entry can carry two of them ("Foo ☆ †"), which would otherwise leave a double
                # space mid-name and fail the lookup against the record.
                name = " ".join(
                    row.group(1).replace("★", "").replace("☆", "").replace("†", "").split()
                )
                out.setdefault(chain, {})[name] = row.group(2)
    return out


def all_recorded_chains() -> list[str]:
    """Every chainId that has a deployment record on disk."""
    # `<chainId>.json` only — sidecars like `<chainId>.pre-swap.json` (snapshot_and_clear_meta) live here too.
    return [p.stem for p in sorted(RECORDS.glob("*.json")) if p.stem.isdigit()]


def check() -> list[str]:
    if not DOC.exists():
        return [f"{DOC} is missing"]
    published = published_by_chain(DOC.read_text())
    problems: list[str] = []

    for chain, entries in sorted(published.items(), key=lambda kv: int(kv[0])):
        recorded = {k: v.lower() for k, v in recorded_addresses(chain).items()}
        if not recorded:
            problems.append(f"chain {chain}: documented but has no deployment record")
            continue

        retired = {v.lower(): k for k, v in retired_addresses(chain).items()}
        by_address = {v: k for k, v in recorded.items()}
        for name, addr in sorted(entries.items()):
            if addr.lower() in retired:
                problems.append(
                    f"chain {chain}: `{name}` published as {addr}, which is RETIRED "
                    f"(recorded under retiredCustomPriceFeeds as `{retired[addr.lower()]}`) — a superseded "
                    f"address must not appear in the docs"
                )
            elif addr.lower() not in by_address:
                problems.append(
                    f"chain {chain}: `{name}` published as {addr}, which is not in that chain's record "
                    f"(stale, misattributed, or invented)"
                )
            elif by_address[addr.lower()] != name:
                problems.append(
                    f"chain {chain}: {addr} is published as `{name}` but recorded as "
                    f"`{by_address[addr.lower()]}`"
                )

        for name, addr in sorted(recorded.items()):
            if name in NOT_PUBLISHED_PER_CHAIN or name in entries:
                continue
            # Only names the per-chain tables are responsible for. Canonical-layer entries (the proxy,
            # implementation, libraries) are documented above and correctly absent from these tables.
            if name in CANONICAL_LAYER:
                continue
            problems.append(f"chain {chain}: `{name}` is deployed at {addr} but appears in no table")

    # Canonical-layer names are exempt from the per-chain tables, so check them here instead: each must be ONE
    # address across every record that carries it, and that address must be published somewhere in the doc.
    # Without this, a chain recording a different (e.g. stale or misdeployed) canonical address would pass.
    doc_addrs = {a.lower() for a in ADDRESS_IN_CELL.findall(DOC.read_text())}
    for name in sorted(CANONICAL_LAYER):
        seen: dict[str, list[str]] = {}
        for chain in all_recorded_chains():
            addr = recorded_addresses(chain).get(name)
            if addr:
                seen.setdefault(addr.lower(), []).append(chain)
        if len(seen) > 1:
            problems.append(f"canonical `{name}` has {len(seen)} different recorded addresses: "
                            + "; ".join(f"{a} on {sorted(cs, key=int)}" for a, cs in seen.items()))
        for addr in seen:
            if addr not in doc_addrs:
                problems.append(f"canonical `{name}` {addr} (recorded on {len(seen[addr])} chain(s)) is not published in the doc")

    # A chain with deployments but NO section at all was invisible to the loop above, which iterates the
    # chains the DOC mentions. That blind spot let BNB (56) carry an undocumented MorphoMarketsMeta while the
    # guard reported success — the whole chain was simply never looked at. Close it by walking the records.
    for chain in sorted(all_recorded_chains(), key=int):
        if chain in published:
            continue
        undocumented = sorted(
            name
            for name in recorded_addresses(chain)
            if name not in NOT_PUBLISHED_PER_CHAIN and name not in CANONICAL_LAYER
        )
        if undocumented:
            problems.append(
                f"chain {chain}: has no section in the doc, but {len(undocumented)} adapter(s) are "
                f"deployed there: {', '.join(undocumented)}"
            )

    return problems


def self_test() -> int:
    """Prove the guard fails on the two defects it exists to catch, not merely that it runs."""
    doc = """
## Balance adapters

### Ethereum (1)

| Adapter | Address |
| --- | --- |
| Ghost | `0x00000000000000000000000000000000deadbeef` |
"""
    parsed = published_by_chain(doc)
    assert parsed == {"1": {"Ghost": "0x00000000000000000000000000000000deadbeef"}}, parsed

    starred = published_by_chain(
        "## Balance adapters\n\n### Base (8453)\n\n| Adapter | Address |\n| --- | --- |\n"
        "| MorphoVaultsMeta ★ | `0x64e1ba8B12ee2bFdBDdFd4E0863EdfaaE824C86a` |\n"
    )
    assert starred["8453"]["MorphoVaultsMeta"], "the ★ fleet marker must not become part of the name"

    shared = published_by_chain(
        "## Balance adapters\n\n### Base (8453)\n\n| Adapter | Address |\n| --- | --- |\n"
        "| MorphoMarketsMeta ☆ | `0x5C951CF5C596BC4908A5fd846710070553830b06` |\n"
    )
    assert shared["8453"]["MorphoMarketsMeta"], "the ☆ shared marker must not become part of the name"

    unregistered = published_by_chain(
        "## Balance adapters\n\n### BNB Chain (56)\n\n| Adapter | Address |\n| --- | --- |\n"
        "| MorphoMarketsMeta ☆ † | `0x5C951CF5C596BC4908A5fd846710070553830b06` |\n"
    )
    assert unregistered["56"]["MorphoMarketsMeta"], "stacked ☆ † markers must not become part of the name"

    problems = check()
    if problems:
        print("self-test: the live doc does NOT agree with the records:")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("self-test: parser assertions pass, and the live doc agrees with the records")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    problems = check()
    if problems:
        print("DEPLOYED_ADDRESSES.md disagrees with script/config/deployments/:\n")
        for p in problems:
            print(f"  - {p}")
        print(
            "\nThe records are the source of truth for deployed addresses. Regenerate the tables from them "
            "rather than editing the doc by hand."
        )
        return 1
    print("DEPLOYED_ADDRESSES.md agrees with every deployment record.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
