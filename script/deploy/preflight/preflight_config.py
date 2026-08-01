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
  * A NAV-sourced custom feed (ADR 0019) inherits its BASE asset's feed timestamp rather than having a
    clock of its own, so registering it with a heartbeat TIGHTER than its base's manufactures a stale
    verdict while the base is fresh — a $0 valuation that reads like an oracle outage rather than a
    config error. Nothing on-chain enforces the pairing. See `heartbeat_findings`.
  * A feed registered at or below its PROVIDER'S declared heartbeat has zero margin, and publication lands
    tens of seconds past the declared target — so the asset goes stale at the end of essentially every
    publish cycle. This is a SECOND, independent heartbeat axis (the one above compares a derived feed to
    its base; this compares any feed to the publisher it reads). It lives in `declared_heartbeat_guard.py`
    because it carries a committed declared-heartbeat snapshot plus an evidence-bearing allowlist, and is
    called from `check_chain` below. Measured instances: sUSDS 59/61 cycles (#211), OETH 29/29 (#236).

usage:
  python3 preflight_config.py                 # all chains with a deployed proxy
  python3 preflight_config.py 1 8453
  python3 preflight_config.py --json report.json
  python3 preflight_config.py --self-test     # prove the heartbeat guard itself, incl. by mutation
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


# Config files that failed to parse, per chain, recorded by `_load_json` and turned into ERRORs by
# `check_chain`. Guarding at the SOURCE rather than at one call site: `cfg`/`dcfg` are called from
# `check_chain`, from `counts`, and from `heartbeat_findings`, so wrapping any single caller leaves the
# others able to raise — which is exactly how the first attempt at this containment failed.
_CONFIG_ERRORS: dict[int, list[str]] = {}


def _load_json(p, chain_id: int) -> dict:
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text())
    except json.JSONDecodeError as e:
        _CONFIG_ERRORS.setdefault(int(chain_id), []).append(f"{p.name}: {e}")
        return {}


def cfg(sub: str, chain_id: int) -> dict:
    return _load_json(c.NAV_CONFIG_DIR / sub / f"{chain_id}.json", chain_id)


def dcfg(sub: str, chain_id: int) -> dict:
    return _load_json(c.CONTRACTS_CONFIG_DIR / sub / f"{chain_id}.json", chain_id)


def enabled_keys(d: dict) -> list[str]:
    """Mirrors ConfigReader.isAdapterEnabled: a MISSING `enabled` key reads as false."""
    return [k for k, v in d.items() if isinstance(v, dict) and v.get("enabled") is True]


def is_bytes32(s) -> bool:
    return isinstance(s, str) and s.startswith("0x") and len(s) == 66


def nav_sourced_base(feed_entry: dict) -> str | None:
    """The `baseAsset` constructor arg of a NAV-sourced custom feed, or None if it has none.

    Presence of `baseAsset` is what makes a feed NAV-sourced under ADR 0019: it reads base/USD from
    `NAVCalculator.getPriceDataNoDivergence(baseAsset)` via `NavBaseUsdLib`, and therefore inherits the
    base feed's timestamp instead of having a clock of its own. A custom feed with no `baseAsset` is not
    NAV-sourced and the heartbeat invariant below does not apply to it.
    """
    ctor = feed_entry.get("constructor", feed_entry)
    return ctor.get("baseAsset") or feed_entry.get("baseAsset")


def heartbeat_findings(chain_id: int, assets: dict, dep_feeds: dict) -> list[tuple[str, str]]:
    """The derived-vs-base heartbeat invariant, for every NAV-sourced custom feed on one chain.

    THE INVARIANT — for a NAV-sourced derived feed, the heartbeat registered on the DERIVED entry must
    be **>= the heartbeat registered for its BASE asset**:

      * A NAV-sourced feed has no independent clock. `NavBaseUsdLib.baseUsd` returns the base's
        `pd.updatedAt`, and `BaseCustomPriceFeed._compute` / `ERC4626VaultRatePriceFeed._compute` pass
        it straight out of `latestRoundData()`. `TwoFeedChainlinkPriceFeed._compute` reports
        `min(rateUpdatedAt, baseUpdatedAt)` (TwoFeedChainlinkPriceFeed.sol:97) — the older of its rate
        leg and the base — so the base's timestamp still surfaces whenever the base is the older leg.
      * `PriceFeedLib._selectFeedCore` then gates that inherited timestamp against the heartbeat of the
        entry it is reading (`block.timestamp - effectiveTime >= cfg.chainlinkHeartbeat` →
        PriceFeedLib.sol:147), i.e. the heartbeat registered for the DERIVED asset.

    ASSERT `>=`, NEVER `==` — the asymmetry is the entire point:

      * a LOOSER derived heartbeat cannot over-report, because the derived feed inherits the base's own
        staleness verdict regardless. wstETH/stETH/lsETH/weETH/eETH/OETH/LDO at 86400 against WETH's
        3600 are CORRECT and must not be flagged.
      * a TIGHTER one cannot make a price fresher. It can only manufacture a stale verdict while the
        base is fresh, which values the asset at $0 and lists it in `stalePriceAssets`.

    The failure mode is silent and MISATTRIBUTING — a $0 valuation plus a `stalePriceAssets` entry looks
    like an oracle outage, so the investigation goes to Chainlink rather than to config. Measured
    instance: sUSDS registered at 82800 against USDS's 86400 (fixed by #211). The USDS/USD publisher's
    real cadence is ~82824s median / 82872s max over 58 days, so USDS's 86400 carried 3600s of margin
    while sUSDS had effectively none: 59 of 61 intervals overshot, and sUSDS was worth $0 for ~23s a day
    on 97% of days while USDS itself never went stale.

    Nothing in the contracts enforces this — it is hand-maintained per chain, which is why it belongs in
    a pre-deploy gate that runs before a live NAV can be affected.
    """
    f: list[tuple[str, str]] = []
    by_addr = {v["address"].lower(): k for k, v in assets.items()
               if isinstance(v, dict) and isinstance(v.get("address"), str)}

    def primary_heartbeat(sym: str) -> int | None:
        """The widest heartbeat among an asset's PRIMARY feeds.

        Monitors are excluded because they never price: `getPriceDataNoDivergence` selects over the
        primary mapping only. `max` is the conservative choice — the base is fresh if ANY of its primary
        feeds passes its own gate, so the derived entry must tolerate the widest of them.
        """
        entry = assets.get(sym) or {}
        hbs = [fd.get("heartbeat") for fd in (entry.get("priceFeeds") or [])
               if isinstance(fd.get("heartbeat"), int)]
        return max(hbs) if hbs else None

    def base_is_itself_derived(sym: str) -> bool:
        return any(fd.get("type") == "Custom" and nav_sourced_base(dep_feeds.get(fd.get("feed", ""), {}))
                   for fd in (assets.get(sym) or {}).get("priceFeeds") or [])

    for sym, entry in assets.items():
        if sym.startswith("$") or not isinstance(entry, dict):
            continue
        for kind in ("priceFeeds", "monitorFeeds"):
            for i, fd in enumerate(entry.get(kind) or []):
                if fd.get("type") != "Custom":
                    continue
                fentry = dep_feeds.get(fd.get("feed", ""))
                if not fentry:
                    continue  # already reported as a missing/disabled Custom feed by check_chain
                base = nav_sourced_base(fentry)
                if not base:
                    continue  # not NAV-sourced — no inherited timestamp, invariant does not apply
                derived_hb = fd.get("heartbeat")
                if not isinstance(derived_hb, int):
                    continue  # already reported as a missing heartbeat by check_chain
                base_sym = by_addr.get(base.lower())
                if base_sym is None:
                    f.append((ERROR, f"asset '{sym}' {kind}[{i}] Custom '{fd['feed']}' has baseAsset "
                                     f"{base} which is NOT a registered asset on this chain — "
                                     f"`NavBaseUsdLib.baseUsd` catches the revert and the feed is "
                                     f"permanently stale, valuing '{sym}' at $0"))
                    continue
                base_hb = primary_heartbeat(base_sym)
                if base_hb is None:
                    f.append((WARN, f"asset '{sym}' {kind}[{i}] Custom '{fd['feed']}' derives from "
                                    f"'{base_sym}', which has no primary heartbeat to compare against"))
                    continue
                if base_is_itself_derived(base_sym):
                    f.append((WARN, f"asset '{sym}' {kind}[{i}] Custom '{fd['feed']}' derives from "
                                    f"'{base_sym}', whose own primary is ALSO a NAV-sourced custom feed "
                                    f"— the base's timestamp is itself inherited, so this single-level "
                                    f"heartbeat comparison is not conclusive. ADR 0019's circularity "
                                    f"invariant says a base must be priced by direct feeds only"))
                if derived_hb < base_hb:
                    consequence = (f"values '{sym}' at $0 and lists it in stalePriceAssets while "
                                   f"'{base_sym}' itself is still fresh"
                                   if kind == "priceFeeds" else
                                   f"silently drops this monitor, so '{sym}' loses the divergence/"
                                   f"irregular signal it is there to provide")
                    f.append((ERROR, f"heartbeat inversion: asset '{sym}' {kind}[{i}] Custom "
                                     f"'{fd['feed']}' has heartbeat {derived_hb} < its base "
                                     f"'{base_sym}' heartbeat {base_hb}. A NAV-sourced feed inherits "
                                     f"its base's timestamp (ADR 0019), so a tighter window cannot "
                                     f"make the price fresher — it only {consequence}"))
    return f


def drain_config_errors(chain_id: int) -> list[tuple[str, str]]:
    """Pop and format every parse failure recorded for this chain since the last drain.

    A DRAIN rather than a read, and called from more than one place, because the recording happens
    wherever `cfg`/`dcfg` are called — including `counts()`, which main() runs AFTER check_chain has
    already reported. Reporting at a single point would silently drop anything recorded later, which is
    the same failure class this containment exists to fix.
    """
    return [(ERROR, f"config file {msg} — could not be parsed, so whatever it governs on chain "
                    f"{chain_id} has NO preflight coverage. That is not the same as clean.")
            for msg in _CONFIG_ERRORS.pop(int(chain_id), [])]


def check_chain(chain_id: int) -> list[tuple[str, str]]:
    """Returns [(severity, message)] for one chain, plus an ERROR per config file that failed to parse.

    Wraps `_check_chain` so the unparseable-file ERRORs are appended on EVERY exit path — `_check_chain`
    returns early for an adapter-less chain, and an earlier version of this containment attached them at
    one return only, which silently dropped them for exactly the chains that take the short path.
    """
    _CONFIG_ERRORS.pop(int(chain_id), None)
    f = _check_chain(chain_id)
    f += drain_config_errors(chain_id)
    return f


def _check_chain(chain_id: int) -> list[tuple[str, str]]:
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

    # Run the declared-heartbeat axis BEFORE the adapter-config section, because that section
    # returns early for a chain with no balance-adapter nav-config. This axis is about PRICE
    # FEEDS and has nothing to do with balance adapters, so letting that early return skip it
    # would silently give such a chain zero heartbeat coverage while the run still reads clean.
    # The SECOND heartbeat axis: registered vs the PROVIDER'S DECLARED cadence. Independent of the one
    # above — that compares a derived feed to its base, this compares any feed to the publisher it reads.
    # Lives in its own module because it carries a committed declared-heartbeat snapshot and an
    # evidence-bearing allowlist. Import is lazy + fail-soft: a missing/broken snapshot must not take out
    # every other config check in this file.
    try:
        import declared_heartbeat_guard as dhg

        # Snapshot-level first, and it must be here rather than only in the guard's own main(): the
        # comparison is only as good as the snapshot's age, and this is the path the runbook actually
        # runs. It self-dedupes, so a multi-chain run reports staleness once rather than per chain.
        f += dhg.snapshot_findings_once()
        f += dhg.findings(chain_id)
    except SystemExit as e:  # snapshot absent — actionable, not fatal to the rest of preflight
        f.append((WARN, f"declared-heartbeat guard skipped: {e}"))
    except Exception as e:  # noqa: BLE001 - never let this axis mask the others
        # Deliberately still fail-soft: this axis must not take out the other config checks. But say
        # plainly that coverage was LOST, not that one small thing went wrong — `findings` contains each
        # feed's failure per row, so reaching here means the whole axis produced nothing for this chain.
        f.append((WARN, f"declared-heartbeat guard produced NO coverage for chain {chain_id} "
                        f"(other checks unaffected): {e!r}"))

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
        # A divergence tolerance with no monitors is inert, not broken: PriceFeedLib._monitorDivergence
        # skips its check when no monitor is healthy, returning irregular=false. Worth surfacing anyway
        # — it means the asset has NO divergence/irregular signal at all, which is easy to miss because
        # the tolerance is still there. (It cannot be zeroed: Prices._setDivergenceTolerance reverts on
        # 0, Prices.sol:198.) ETHx is deliberately in this state after Redstone sunset its ETHx feeds.
        if entry.get("divergenceToleranceBps") and not (entry.get("monitorFeeds") or []):
            f.append((WARN, f"asset '{sym}' sets divergenceToleranceBps="
                            f"{entry['divergenceToleranceBps']} but has NO monitor feeds — it gets no "
                            f"divergence/irregular signal until a monitor is added"))
    # The derived-vs-base heartbeat invariant — see heartbeat_findings for the full derivation.
    f += heartbeat_findings(chain_id, assets, dep_feeds)

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


def self_test() -> int:
    """Prove the heartbeat guard: synthetic cases for each arm, then mutation against the real config.

    The mutation runs on an in-memory deep copy, never on disk. A guard that edited a tracked config to
    prove itself could leave that edit behind on any early exit, and `script/config` is the record of
    what production runs — the same reason `rehearse_fork.sh` treats it as disposable-but-restored.
    """
    failures: list[str] = []

    def check(label: str, cond: bool) -> None:
        print(f"  {'PASS' if cond else 'FAIL'}  {label}")
        if not cond:
            failures.append(label)

    def errs(findings):
        return [m for s, m in findings if s == ERROR]

    WETH = "0x" + "1" * 40
    DERIVED = "0x" + "2" * 40
    OTHER = "0x" + "3" * 40

    def scenario(derived_hb, base_hb, kind="priceFeeds", base_ctor=None):
        assets = {
            "WETH": {"address": WETH, "priceFeeds": [{"type": "Chainlink", "address": OTHER,
                                                      "heartbeat": base_hb}]},
            "DER": {"address": DERIVED, kind: [{"type": "Custom", "feed": "der",
                                               "heartbeat": derived_hb}]},
        }
        if base_ctor is not None:
            assets["WETH"]["priceFeeds"] = [{"type": "Custom", "feed": "basefeed",
                                             "heartbeat": base_hb}]
        feeds = {"der": {"enabled": True, "constructor": {"baseAsset": WETH}},
                 "basefeed": {"enabled": True, "constructor": {"baseAsset": base_ctor or OTHER}}}
        return heartbeat_findings(1, assets, feeds)

    print("synthetic cases:")
    # The asymmetry: this is the case that must NOT be flagged, and the one most likely to be got wrong.
    check("looser derived heartbeat (86400 vs base 3600) is ACCEPTED",
          errs(scenario(86400, 3600)) == [])
    check("equal heartbeats (3600 vs 3600) are ACCEPTED", errs(scenario(3600, 3600)) == [])
    check("tighter derived heartbeat (1800 vs base 3600) is an ERROR",
          len(errs(scenario(1800, 3600))) == 1)
    check("tighter by ONE second (3599 vs 3600) is an ERROR",
          len(errs(scenario(3599, 3600))) == 1)
    check("the real measured shape (82800 vs 86400) is an ERROR",
          len(errs(scenario(82800, 86400))) == 1)
    check("a tighter MONITOR heartbeat is also an ERROR",
          len(errs(scenario(1800, 3600, kind="monitorFeeds"))) == 1)
    check("a non-NAV-sourced custom feed (no baseAsset) is EXCLUDED",
          heartbeat_findings(1, {"DER": {"address": DERIVED,
                                        "priceFeeds": [{"type": "Custom", "feed": "der",
                                                        "heartbeat": 60}]}},
                             {"der": {"enabled": True, "constructor": {}}}) == [])
    check("an unregistered baseAsset is an ERROR",
          len(errs(heartbeat_findings(1, {"DER": {"address": DERIVED,
                                                 "priceFeeds": [{"type": "Custom", "feed": "der",
                                                                 "heartbeat": 60}]}},
                                     {"der": {"enabled": True,
                                              "constructor": {"baseAsset": WETH}}}))) == 1)
    check("a base whose own primary is NAV-sourced yields a WARN (ADR 0019 circularity)",
          any(s == WARN for s, _ in scenario(86400, 3600, base_ctor=OTHER)))
    check("a direct (non-Custom) feed entry is ignored",
          heartbeat_findings(1, {"A": {"address": DERIVED,
                                      "priceFeeds": [{"type": "Chainlink", "address": OTHER,
                                                      "heartbeat": 1}]}}, {}) == [])

    print("mutation against the real mainnet config:")
    import copy
    real_assets = cfg("assets-and-price-feeds", 1)
    real_feeds = dcfg("custom-price-feeds", 1)
    if not real_assets or not real_feeds:
        check("mainnet config readable", False)
    else:
        # wstETH is chosen because it is legitimately LOOSER than its WETH base (86400 vs 3600): it must
        # be clean before the mutation and must fail after, which pins the direction of the comparison
        # as well as its existence. Picking an already-violating asset would prove neither.
        before = [m for m in errs(heartbeat_findings(1, real_assets, real_feeds)) if "'wstETH'" in m]
        mutated = copy.deepcopy(real_assets)
        mutated["wstETH"]["priceFeeds"][0]["heartbeat"] = 1800
        after = [m for m in errs(heartbeat_findings(1, mutated, real_feeds)) if "'wstETH'" in m]
        check("wstETH is clean in the real config (looser than base, correctly not flagged)",
              before == [])
        check("lowering wstETH's heartbeat to 1800 (< WETH's 3600) makes the guard BITE",
              len(after) == 1)
        check("the real config on disk was not modified",
              cfg("assets-and-price-feeds", 1)["wstETH"]["priceFeeds"][0]["heartbeat"]
              == real_assets["wstETH"]["priceFeeds"][0]["heartbeat"] != 1800)

    print(f"\nself-test: {'all checks passed' if not failures else str(len(failures)) + ' FAILED'}")
    return 1 if failures else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("chains", nargs="*", type=int)
    ap.add_argument("--json", help="also write the full report to this path")
    ap.add_argument("--self-test", action="store_true",
                    help="prove the heartbeat guard (synthetic arms + real-config mutation) and exit")
    args = ap.parse_args()
    c.load_env()

    if args.self_test:
        return self_test()

    chains, scope_src = c.resolve_chains(args.chains)
    print(f"scope: {len(chains)} chain(s) from {scope_src}")
    report, n_err, n_warn = {}, 0, 0
    totals = Counter()

    for cid in chains:
        # One chain must not be able to kill the run. `cfg`/`dcfg` call json.loads without a guard, so a
        # single unparseable config file used to raise straight out of check_chain and abort every
        # REMAINING chain — and it discarded the findings already computed for this one, including the
        # declared-heartbeat guard's own "config could not be parsed" ERROR. The failure is now contained
        # to its chain and reported as an ERROR, so the run still covers the others and still fails.
        try:
            findings = check_chain(cid)
            k = counts(cid)
            # counts() re-reads config through the same guarded loaders, so anything it discovers is
            # recorded AFTER check_chain already reported. Drain again or it is silently dropped.
            findings += drain_config_errors(cid)
        except Exception as e:  # noqa: BLE001 - a chain that cannot be checked is not a chain that passed
            # `counts` is inside the guard too: it re-reads the same config files, so leaving it outside
            # let the very failure this handler exists for escape one line later.
            findings = [(ERROR, f"chain {cid} could NOT be checked ({e!r}) — this chain has NO preflight "
                                f"coverage; that is not the same as clean.")]
            k = {"metaAdapters": 0, "metaInstances": 0, "plainAdapters": 0, "customFeeds": 0, "assets": 0}
            # The snapshot-staleness signal is emitted ONCE per process. If this chain consumed it and
            # then died, nothing would re-emit it and the whole run would silently lose that signal —
            # so re-arm it for the next chain.
            try:
                import declared_heartbeat_guard as _dhg

                _dhg._reset_snapshot_findings_once()
            except Exception:  # noqa: BLE001 - best effort; never let re-arming break the loop
                pass
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
