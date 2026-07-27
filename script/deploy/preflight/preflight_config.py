#!/usr/bin/env python3
"""Validate every per-chain config the redeploy depends on, before a single transaction is sent.

The checks below all exist because the deploy scripts fail SILENTLY on these inputs rather than
reverting — a run "succeeds", writes nothing, and leaves a half-configured NAV:

  * `04_DeployBalanceAdapters._deployIfEnabled` looks up `enabled` via `ConfigReader.isAdapterEnabled`,
    which returns **false when the key is absent** (ConfigReader.sol:367-368). An adapter that is
    enabled in `nav-config/` but has no entry in either deploy-config folder is simply never deployed.
  * `06_Configure` then does `if (deployed == address(0)) continue;` (06_Configure.s.sol:113 for meta,
    same shape for plain), so the missing adapter is skipped without an error.
  * `addMetaInstances` is all-or-nothing and reverts `DuplicateMetaInstance`, so a coordinate repeated
    within one adapter's configured set aborts that chain's `06` mid-run.
  * A `Custom` price feed named in `nav-config/assets-and-price-feeds` resolves through
    `deployments/<id>.json .customPriceFeeds.<name>`; if the feed is not in the deploy config it is
    never built and asset registration gets address(0).

usage:
  python3 preflight_config.py                 # all chains with a deployed proxy
  python3 preflight_config.py 1 8453
  python3 preflight_config.py --json report.json
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter

import chainlib as c

ERROR, WARN, INFO = "ERROR", "WARN", "INFO"

REQUIRED_CHAIN_FIELDS = ["chainId", "name", "rpc", "explorer", "chainlinkSequencerFeed",
                         "nativeTokenSymbol"]
REQUIRED_ROLES = ["admin", "manager", "securityCouncil"]


def cfg(sub: str, chain_id: int) -> dict:
    p = c.NAV_CONFIG_DIR / sub / f"{chain_id}.json"
    return json.loads(p.read_text()) if p.exists() else {}


def dcfg(sub: str, chain_id: int) -> dict:
    p = c.CONTRACTS_CONFIG_DIR / sub / f"{chain_id}.json"
    return json.loads(p.read_text()) if p.exists() else {}


def enabled_keys(d: dict) -> list[str]:
    """Mirrors ConfigReader.isAdapterEnabled: a MISSING `enabled` key reads as false."""
    return [k for k, v in d.items() if isinstance(v, dict) and v.get("enabled") is True]


def is_bytes32(s) -> bool:
    return isinstance(s, str) and s.startswith("0x") and len(s) == 66


def check_chain(chain_id: int) -> list[tuple[str, str]]:
    """Returns [(severity, message)] for one chain."""
    f: list[tuple[str, str]] = []
    chain = c.chain_config(chain_id)
    dep = c.deployment(chain_id)

    # --- chains/<id>.json ---------------------------------------------------
    for field in REQUIRED_CHAIN_FIELDS:
        if field not in chain:
            f.append((ERROR, f"chains/{chain_id}.json missing required field '{field}'"))
    if chain.get("chainId") != chain_id:
        f.append((ERROR, f"chains/{chain_id}.json .chainId={chain.get('chainId')} != filename"))
    addrs = chain.get("addresses", {}) or {}
    for role in REQUIRED_ROLES:
        v = addrs.get(role)
        if not c.is_address(v):
            f.append((ERROR, f"chains/{chain_id}.json addresses.{role} is not a valid address: {v!r}"))
    if c.is_address(addrs.get("admin")) and c.is_address(addrs.get("manager")):
        if addrs["admin"].lower() != addrs["manager"].lower():
            f.append((WARN, f"addresses.admin != addresses.manager — the EOA flow assumes both are "
                            f"the deployer ({addrs['admin']} vs {addrs['manager']})"))
    if c.is_address(addrs.get("admin")) and c.is_address(addrs.get("securityCouncil")):
        if addrs["admin"].lower() == addrs["securityCouncil"].lower():
            f.append((WARN, "addresses.admin == addresses.securityCouncil — step 07 would be a no-op"))
    url, note = c.resolve_rpc(chain_id, allow_fallback=False)
    if not url:
        f.append((WARN, f"RPC not resolvable in this environment: {note}"))

    # L2 sequencer feed sanity: a chain with a zero feed skips the sequencer check entirely.
    seq = chain.get("chainlinkSequencerFeed", "")
    if chain_id != 1 and seq == "0x" + "0" * 40:
        f.append((INFO, "chainlinkSequencerFeed is zero — L2 sequencer-uptime check disabled on "
                        "this chain (intentional where no feed exists)"))

    # --- adapter config coherence (only chains that have nav-config) --------
    nav_plain = cfg("balance-adapters", chain_id)
    nav_meta = cfg("meta-balance-adapters", chain_id)
    dep_plain = dcfg("balance-adapters", chain_id)
    dep_meta = dcfg("meta-balance-adapters", chain_id)
    if not (nav_plain or nav_meta):
        return f  # a bare ERC20Default-only chain; nothing further to check

    meta_file = c.CONTRACTS_CONFIG_DIR / "meta-balance-adapters" / f"{chain_id}.json"
    if enabled_keys(nav_meta) and not meta_file.exists():
        f.append((ERROR, f"{len(enabled_keys(nav_meta))} meta-adapter(s) enabled in nav-config but "
                         f"contracts-deployment-config/meta-balance-adapters/{chain_id}.json DOES NOT "
                         f"EXIST — 04 will deploy none of them and 06 will silently skip them"))

    def resolves(name: str) -> bool:
        """ConfigReader._resolveAdapterFile: plain deploy file first, then the meta deploy file."""
        src = dep_plain if name in dep_plain else (dep_meta if name in dep_meta else None)
        return bool(src) and src.get(name, {}).get("enabled") is True

    for name in enabled_keys(nav_plain):
        if not resolves(name):
            where = ("present but enabled=false" if (name in dep_plain or name in dep_meta)
                     else "absent from both deploy-config folders")
            f.append((ERROR, f"plain adapter '{name}' enabled in nav-config but {where} — "
                             f"04 will not deploy it, 06 will silently skip it"))
    for name in enabled_keys(nav_meta):
        if not resolves(name):
            where = ("present but enabled=false" if (name in dep_plain or name in dep_meta)
                     else "absent from both deploy-config folders")
            f.append((ERROR, f"meta adapter '{name}' enabled in nav-config but {where} — "
                             f"04 will not deploy it, 06 will silently skip it"))

    # The reverse direction is a warning: deployed-but-unregistered wastes gas but is not wrong.
    for name in enabled_keys(dep_meta) + enabled_keys(dep_plain):
        in_nav = (nav_meta.get(name, {}).get("enabled") is True
                  or nav_plain.get(name, {}).get("enabled") is True)
        if not in_nav:
            f.append((WARN, f"'{name}' enabled in deploy-config but not in nav-config — it will be "
                            f"deployed and then never registered on the NAV"))

    # --- meta instance sets -------------------------------------------------
    for name, entry in nav_meta.items():
        if entry.get("enabled") is not True:
            continue
        insts = entry.get("instances", []) or []
        raw = entry.get("instancesRaw", []) or []
        for a in insts:
            if not c.is_address(a):
                f.append((ERROR, f"{name}.instances contains a non-address entry: {a!r}"))
        for b in raw:
            if not is_bytes32(b):
                f.append((ERROR, f"{name}.instancesRaw contains a non-bytes32 entry: {b!r}"))
        # 06 unions instances (widened) with instancesRaw; addMetaInstances reverts DuplicateMetaInstance.
        coords = [a.lower().replace("0x", "0x" + "0" * 24) for a in insts if c.is_address(a)]
        coords += [b.lower() for b in raw if is_bytes32(b)]
        dupes = [k for k, n in Counter(coords).items() if n > 1]
        if dupes:
            f.append((ERROR, f"{name} has duplicate instance coordinate(s) {dupes} — "
                             f"addMetaInstances reverts DuplicateMetaInstance and aborts 06"))
        if not insts and not raw:
            f.append((WARN, f"{name} is enabled but has an EMPTY instance set — it will be "
                            f"registered and report nothing"))

    # --- assets and price feeds --------------------------------------------
    assets = cfg("assets-and-price-feeds", chain_id)
    dep_feeds = dcfg("custom-price-feeds", chain_id)
    for sym, entry in assets.items():
        if sym.startswith("$"):
            continue
        if not c.is_address(entry.get("address")):
            f.append((ERROR, f"asset '{sym}' has an invalid address: {entry.get('address')!r}"))
        feeds = entry.get("priceFeeds", []) or []
        if not feeds:
            f.append((ERROR, f"asset '{sym}' has no priceFeeds — registerAsset requires one"))
        for i, feed in enumerate(feeds + (entry.get("monitorFeeds", []) or [])):
            if feed.get("type") == "Custom":
                fname = feed.get("feed", "")
                if fname not in dep_feeds:
                    f.append((ERROR, f"asset '{sym}' feed[{i}] is Custom '{fname}' but that feed is "
                                     f"absent from custom-price-feeds/{chain_id}.json — 03 will not "
                                     f"deploy it and registration gets address(0)"))
                elif dep_feeds[fname].get("enabled") is not True:
                    f.append((ERROR, f"asset '{sym}' feed[{i}] is Custom '{fname}' but that feed is "
                                     f"enabled=false in custom-price-feeds/{chain_id}.json"))
            elif not c.is_address(feed.get("address")):
                f.append((ERROR, f"asset '{sym}' feed[{i}] type={feed.get('type')} has an invalid "
                                 f"address: {feed.get('address')!r}"))
            if not feed.get("heartbeat"):
                f.append((WARN, f"asset '{sym}' feed[{i}] has no heartbeat"))
    for fname, entry in dep_feeds.items():
        if entry.get("enabled") is not True:
            continue
        used = any(
            fd.get("feed") == fname
            for a in assets.values() if isinstance(a, dict)
            for fd in (a.get("priceFeeds", []) or []) + (a.get("monitorFeeds", []) or [])
        )
        if not used:
            f.append((WARN, f"custom feed '{fname}' is enabled for deploy but no asset references it"))

    # --- deployment record shape -------------------------------------------
    if not dep.get("NAVCalculatorProxy"):
        f.append((ERROR, "deployments record has no NAVCalculatorProxy"))
    return f


def counts(chain_id: int) -> dict:
    nav_meta = cfg("meta-balance-adapters", chain_id)
    nav_plain = cfg("balance-adapters", chain_id)
    feeds = dcfg("custom-price-feeds", chain_id)
    metas = enabled_keys(nav_meta)
    return {
        "metaAdapters": len(metas),
        "metaInstances": sum(len(nav_meta[m].get("instances", []) or [])
                             + len(nav_meta[m].get("instancesRaw", []) or []) for m in metas),
        "plainAdapters": len(enabled_keys(nav_plain)),
        "customFeeds": len(enabled_keys(feeds)),
        "assets": len([k for k in cfg("assets-and-price-feeds", chain_id) if not k.startswith("$")]),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("chains", nargs="*", type=int)
    ap.add_argument("--json", help="also write the full report to this path")
    args = ap.parse_args()
    c.load_env()

    chains = args.chains or c.deployed_chain_ids()
    report, n_err, n_warn = {}, 0, 0
    totals = Counter()

    for cid in chains:
        findings = check_chain(cid)
        k = counts(cid)
        for key, v in k.items():
            totals[key] += v
        report[str(cid)] = {"name": c.chain_config(cid).get("name", "?"),
                            "counts": k,
                            "findings": [{"severity": s, "message": m} for s, m in findings]}
        errs = [x for x in findings if x[0] == ERROR]
        warns = [x for x in findings if x[0] == WARN]
        n_err += len(errs)
        n_warn += len(warns)
        head = (f"  {cid:8} {c.chain_config(cid).get('name','?'):16} "
                f"meta={k['metaAdapters']:<3} inst={k['metaInstances']:<4} "
                f"plain={k['plainAdapters']:<3} feeds={k['customFeeds']:<3} assets={k['assets']:<3}")
        print(head + (f"  {len(errs)} ERROR {len(warns)} WARN" if findings else "  clean"))
        for sev, msg in findings:
            if sev != INFO:
                print(f"           [{sev}] {msg}")

    print("\n--- configured totals across the checked chains ---")
    print(f"  meta adapters        {totals['metaAdapters']}")
    print(f"  meta instances       {totals['metaInstances']}")
    print(f"  plain adapters       {totals['plainAdapters']}  (+1 ERC20Default per chain, auto)")
    print(f"  custom price feeds   {totals['customFeeds']}")
    print(f"  assets to register   {totals['assets']}")
    print(f"\n{n_err} error(s), {n_warn} warning(s) across {len(chains)} chain(s)")

    if args.json:
        json.dump({"chains": report, "totals": dict(totals),
                   "errorCount": n_err, "warnCount": n_warn},
                  open(args.json, "w"), indent=1)
        print(f"wrote {args.json}")
    return 1 if n_err else 0


if __name__ == "__main__":
    sys.exit(main())
