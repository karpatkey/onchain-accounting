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
  * A NAV-sourced custom feed whose `baseAsset` is itself Custom-priced forms a pricing CYCLE. Every leg
    passes the on-chain guard (`PriceFeedLib._validateFeedNotCircular` rejects only `base == asset`, and
    never reads the registry, so ordering does not save you), and the read then costs ~7.7M gas against a
    ~50k control while still returning a correct-looking price — a fault with no symptom but the bill.
    Enforced here instead, in config, where the whole graph is visible. See `base_allowlist_findings`.
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
  python3 preflight_config.py --self-test     # prove the guards themselves, incl. by real-config mutation
  python3 preflight_config.py --base-report   # the NAV-sourced base graph + its cycle/config-only counts
"""
from __future__ import annotations

import argparse
import contextlib
import json
import sys
from collections import Counter

import chainlib as c

ERROR, WARN, INFO = "ERROR", "WARN", "INFO"

REQUIRED_CHAIN_FIELDS = ["chainId", "name", "rpc", "explorer", "chainlinkSequencerFeed",
                         "nativeTokenSymbol"]
REQUIRED_ROLES = ["admin", "manager", "securityCouncil"]

# The only values `ConfigReader.accrualKindFromString` recognises. Case-exact: it compares whole
# strings, so "none" or "REBASING" are unrecognised, not lenient matches.
ACCRUAL_KINDS = ("None", "Rebasing", "Appreciating")


class ConfigParseError(ValueError):
    """A per-chain config file could not be read as a config object."""


# Recording is OPT-IN and SCOPED. Outside a `collect_config_errors()` block, `cfg`/`dcfg` RAISE — which is
# the contract they had before this module started containing parse failures, and the contract every other
# importer still depends on. `verify_step.py` imports `cfg`/`dcfg`/`counts` and certifies deploy
# post-conditions on-chain from the sets they return; silently handing it `{}` turns "everything expected
# is present" into a vacuous truth on a chain where nothing was registered. A record of parse errors that
# only one of four importers reads is the same shape as the defects this file exists to catch, so the
# containment is now something a caller must ASK for rather than something it inherits by importing.
_COLLECTING: set[str] | None = None


@contextlib.contextmanager
def collect_config_errors():
    """Within this block, a bad config file is RECORDED (deduped) instead of raised."""
    global _COLLECTING
    prev, _COLLECTING = _COLLECTING, set()
    try:
        yield _COLLECTING
    finally:
        _COLLECTING = prev


def _bad_config(p, why: str) -> dict:
    # A set, not a list: the same file is read more than once per chain (`_check_chain`, then `counts`),
    # and errors are keyed by COLLECTING SCOPE, not by chain — which is why `_load_json` takes no
    # chain_id. A signature implying per-chain keying is what made the two-scope duplication easy to miss.
    # and appending per read inflated the run's headline ERROR count by however many times the file
    # happened to be opened — a count a pre-deploy gate is reconciled against.
    if _COLLECTING is None:
        raise ConfigParseError(f"{p.name}: {why}")
    _COLLECTING.add(f"{p.name}: {why}")
    return {}


def _load_json(p) -> dict:
    if not p.exists():
        return {}
    try:
        v = json.loads(p.read_text())
    except json.JSONDecodeError as e:
        return _bad_config(p, str(e))
    if not isinstance(v, dict):
        # A top-level list/string/null parses fine but is not a config object. Returning it would make
        # every downstream `.items()`/`.get()` raise far from the cause, or quietly read as empty.
        return _bad_config(p, f"top level is {type(v).__name__}, expected an object")
    return v


def cfg(sub: str, chain_id: int) -> dict:
    return _load_json(c.NAV_CONFIG_DIR / sub / f"{chain_id}.json")


def dcfg(sub: str, chain_id: int) -> dict:
    return _load_json(c.CONTRACTS_CONFIG_DIR / sub / f"{chain_id}.json")


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


ZERO_ADDR = "0x" + "0" * 40


def is_address_shaped(v) -> bool:
    """A 20-byte hex address by SHAPE, address(0) included.

    `chainlib.is_address` deliberately rejects address(0), which is right everywhere it is used to mean
    "a real contract". It is wrong for `baseAsset`, where address(0) is the sentinel meaning "this feed
    has no NAV dependency" — the same value `ETHPlus_CustomPriceFeed.BASE_ASSET` returns on chain.
    """
    if not isinstance(v, str) or not v.startswith("0x") or len(v) != 42:
        return False
    try:
        int(v, 16)
    except ValueError:
        return False
    return True


def base_allowlist_findings(chain_id: int, assets: dict, dep_feeds: dict) -> list[tuple[str, str]]:
    """THE BASE ALLOWLIST — every NAV-sourced custom feed's `baseAsset` must be a DIRECT-priced asset.

    A NAV-sourced custom feed prices its asset as `rate x base/USD` and reads the `base/USD` term back out
    of the NAV itself (`NavBaseUsdLib` -> `getPriceDataNoDivergence(baseAsset)`, ADR 0019). ADR 0019's
    circularity invariant says the base MUST be priced by direct feeds (Chainlink/Redstone/API3) and never
    by a feed that calls back. `PriceFeedLib._validateFeedNotCircular` enforces only the SELF case on
    chain (`base == asset`), because the multi-hop case needs an ordering-dependent registry scan that
    cannot answer NO reliably. This is where the rest is enforced: in configuration, before deploy.

    WHAT THIS CATCHES that the on-chain guard cannot:

      * a MULTI-HOP cycle of any length — A based on B, B based on A (or A->B->C->A). Every leg passes the
        on-chain guard in either order, then costs ~7.7M gas per read against a ~50k control while still
        returning the correct price, so there is no symptom but the bill.
      * a base that is not a registered asset at all, which makes the derived feed permanently stale.
      * a base that is some arbitrary registered asset rather than a pricing base.

    WHAT IT DOES NOT CATCH, stated so nobody reads more into a clean run: it cannot tell WETH from USDC for
    an LST. A feed built with the WRONG-but-direct base still passes, still reports `stale=false` and
    `irregular=false`, and costs an ordinary read. There is no on-chain ground truth for what an LST's base
    ought to be -- which is why the ERC-4626 family CAN be pinned (its constructor asserts
    `baseAsset == IERC4626(vault).asset()`) and the others cannot. This check narrows the exposure from
    "any of the chain's registered assets" to "a direct-priced base"; it does not close it.

    ABSENT IS NOT THE SAME FAILURE AS WRONG, and both are rejected. A custom feed with no NAV dependency
    (`ETHPlus_CustomPriceFeed`, which prices off the Reserve Protocol basket and never calls back) must
    DECLARE that by setting `baseAsset` to the zero address, mirroring exactly what the contract does
    on chain. Silence is not acceptance: an omitted key used to drop the feed out of every base check
    entirely, which is the same "could not read it, therefore it is fine" collapse the on-chain guard was
    written to avoid. So an absent key, an empty string and a malformed address each get their own error.
    """
    f: list[tuple[str, str]] = []
    by_addr = {v["address"].lower(): k for k, v in assets.items()
               if isinstance(v, dict) and isinstance(v.get("address"), str)}

    def nav_dependency(feed_name: str) -> str | None | bool:
        """The base a feed reads from the NAV: an address, None if it declares none, False if unknowable."""
        fe = dep_feeds.get(feed_name)
        if fe is None:
            return False  # cannot be established -> cannot be vouched for
        ctor = fe.get("constructor", fe)
        raw = ctor.get("baseAsset", fe.get("baseAsset"))
        if not is_address_shaped(raw):
            return False
        return None if int(raw, 16) == 0 else raw.lower()

    # The allowlist is DERIVED, never hand-maintained: an asset may serve as a base exactly when none of its
    # PRIMARY feeds reads a price back out of the NAV. Monitors are irrelevant -- `getPriceDataNoDivergence`
    # passes `withDivergence=false`, so the base read never reaches the monitor mapping. Deriving it means
    # the list shrinks by itself the moment someone gives a base a NAV-sourced primary, which IS the cycle.
    #
    # Note this is NOT "has no Custom primary". A Custom feed that declares no NAV dependency
    # (`ETHPlus_CustomPriceFeed`, baseAsset == 0) cannot re-enter the NAV, so an asset priced by one is a
    # perfectly good base. Banning every Custom primary would reject that legitimate shape for no gain --
    # the same over-reach the on-chain guard avoids by reading a VALUE rather than testing for presence.
    def is_direct_priced(sym: str) -> bool:
        prim = (assets.get(sym) or {}).get("priceFeeds") or []
        if not prim:
            return False
        return all(fd.get("type") != "Custom" or nav_dependency(fd.get("feed", "")) is None
                   for fd in prim)

    allowlist = sorted(s for s in assets if not s.startswith("$") and is_direct_priced(s))

    for sym, entry in assets.items():
        if sym.startswith("$") or not isinstance(entry, dict):
            continue
        for kind in ("priceFeeds", "monitorFeeds"):
            for i, fd in enumerate(entry.get(kind) or []):
                if fd.get("type") != "Custom":
                    continue
                fname = fd.get("feed", "")
                fentry = dep_feeds.get(fname)
                if not fentry:
                    continue  # already reported as a missing/disabled Custom feed by check_chain
                where = f"asset '{sym}' {kind}[{i}] Custom '{fname}'"
                ctor = fentry.get("constructor", fentry)
                has_key = "baseAsset" in ctor or "baseAsset" in fentry
                raw = ctor.get("baseAsset", fentry.get("baseAsset"))

                if not has_key:
                    f.append((ERROR, f"{where} does not declare a baseAsset in "
                                     f"custom-price-feeds/{chain_id}.json. Every custom feed must state its "
                                     f"NAV dependency: set baseAsset to the asset it reads base/USD for, or to "
                                     f"{ZERO_ADDR} to assert it has none (as ETHPlus_CustomPriceFeed does on "
                                     f"chain). An omitted key is not the same as 'no dependency' — it drops "
                                     f"the feed out of the circularity checks entirely"))
                    continue
                if not isinstance(raw, str) or not raw.strip():
                    f.append((ERROR, f"{where} has an EMPTY baseAsset ({raw!r}). Use {ZERO_ADDR} to assert "
                                     f"no NAV dependency; an empty value states nothing"))
                    continue
                # The zero test comes BEFORE `c.is_address`, which rejects address(0) by design
                # (`int(v,16) != 0`). Here address(0) is not a bad address — it is the sentinel that MEANS
                # "no NAV dependency", so ordering these the other way round reports the one legitimate
                # opt-out as malformed and bans the ETHPlus shape outright.
                if is_address_shaped(raw) and int(raw, 16) == 0:
                    continue  # explicitly not NAV-sourced — the only clean way to opt out
                if not c.is_address(raw):
                    f.append((ERROR, f"{where} has a MALFORMED baseAsset ({raw!r}) — not a 20-byte address, "
                                     f"so its NAV dependency cannot be established"))
                    continue

                if raw.lower() == (entry.get("address") or "").lower():
                    f.append((ERROR, f"{where} has baseAsset == '{sym}' itself — pricing '{sym}' re-enters "
                                     f"this same feed and recurses. This is also rejected on chain by "
                                     f"IPrices.CustomFeedBaseCircular; failing here means it never reaches a "
                                     f"registration transaction"))
                    continue

                base_sym = by_addr.get(raw.lower())
                if base_sym is None:
                    f.append((ERROR, f"{where} has baseAsset {raw} which is NOT a registered asset on chain "
                                     f"{chain_id}, so it cannot be on the direct-feed allowlist "
                                     f"{allowlist}. `NavBaseUsdLib.baseUsd` catches the revert and the feed "
                                     f"is permanently stale, valuing '{sym}' at $0"))
                    continue
                if not is_direct_priced(base_sym):
                    prim = [x.get("type") for x in (assets.get(base_sym) or {}).get("priceFeeds") or []]
                    f.append((ERROR, f"{where} derives from '{base_sym}', which is NOT on the direct-feed "
                                     f"allowlist {allowlist} — its own primaries are {prim}. ADR 0019 "
                                     f"requires a base priced by direct feeds only. A base that is itself "
                                     f"Custom-priced forms a multi-hop pricing cycle, which the on-chain "
                                     f"guard cannot detect (it never reads the registry) and which costs "
                                     f"~7.7M gas per read of '{sym}' while still returning a plausible price"))
    return f


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


def _config_error_findings(chain_id: int, msgs) -> list[tuple[str, str]]:
    return [(ERROR, f"config file {msg} — could not be read, so whatever it governs on chain "
                    f"{chain_id} has NO preflight coverage. That is not the same as clean.")
            for msg in sorted(msgs)]


def chain_report(chain_id: int) -> tuple[list[tuple[str, str]], dict, str, bool]:
    """Everything `main` needs for one chain — findings, counts, name — gathered in ONE collecting scope.

    ONE SCOPE PER CHAIN, not one per call site. Each scope carries its own dedupe set, so running
    `_check_chain` and `counts` in separate scopes let the same unparseable file be reported once by each:
    measured on chain 137 with `137.json = []`, three ERRORs of which two were identical. Deduping per read
    and then formatting per scope moves the duplication rather than removing it.

    FORMATTED INSIDE THE `with`, deliberately. If `_check_chain` records a parse error and *then* raises,
    an exit through the exception would skip a `_config_error_findings` call placed after the block, losing
    the filename and leaving only the exception type — actionable detail gone from the one message that
    names which file to fix.

    Raises nothing: a chain that cannot be checked is reported as an ERROR, never as an absence.
    """
    f: list[tuple[str, str]] = []
    k: dict | None = None
    name, degraded = "?", False
    with collect_config_errors() as errs:
        try:
            f = _check_chain(chain_id)
            k = counts(chain_id)
            name = c.chain_config(chain_id).get("name", "?")
        except Exception as e:  # noqa: BLE001 - a chain that cannot be checked is not a chain that passed
            degraded = True
            f.append((ERROR, f"chain {chain_id} could NOT be fully checked ({e!r}) — its coverage is "
                             f"INCOMPLETE; that is not the same as clean."))
        f += _config_error_findings(chain_id, errs)
    if k is None:
        k = {"metaAdapters": 0, "metaInstances": 0, "plainAdapters": 0, "customFeeds": 0, "assets": 0}
    return f, k, name, degraded


def check_chain(chain_id: int) -> list[tuple[str, str]]:
    """The findings for one chain. See `chain_report` for why the scope covers `counts` as well."""
    return chain_report(chain_id)[0]


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

        # Snapshot-level findings are NOT emitted here — see `snapshot_findings` in main(). The
        # snapshot's age is a property of the FILE, not of any chain, so emitting it from inside a
        # per-chain call meant reasoning about a once-per-process latch across chains that may fail. Both
        # spellings of that reasoning were wrong in 2 of 7 failure scenarios, one of them by LOSING the
        # warning outright. Hoisting it above the loop is correct in all 7 and needs no latch at all.
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

    # --- constructor args SHARED across sibling adapters --------------------
    # Splitting one adapter into per-leg siblings duplicates whatever constructor args the legs have in common,
    # and a JSON file cannot express "these two must be equal". Before the Cap split one key supplied `cUsd` and
    # `usdc` once, so divergence was structurally impossible; now a typo in either block deploys cleanly and
    # AddressCheckLib.requireContract still passes, because a WRONG contract is still a contract. The failure is
    # silent and expensive: a divergent `cUsd` points CapSavings at the wrong burn-quote oracle, so the stcUSD leg
    # either reverts (dropped from NAV by the per-adapter try/catch) or returns a garbage USDC amount summed in as
    # real value; a divergent `usdc` makes the two legs report different balanceAsset, so they stop summing to the
    # pre-split total the fork test pins.
    #
    # Keyed by the shared arg name -> the sibling adapters that must agree on it. Add a row when you split an
    # adapter, not after the divergence is found on-chain.
    SIBLING_SHARED_ARGS: dict[str, tuple[str, ...]] = {
        "cUsd": ("CapStablecoin", "CapSavings"),
        "usdc": ("CapStablecoin", "CapSavings"),
    }
    for arg, siblings in SIBLING_SHARED_ARGS.items():
        present = [n for n in siblings if n in dep_plain]
        if len(present) < 2:
            continue  # not both configured on this chain; nothing to compare
        seen: dict[str, list[str]] = {}
        for name in present:
            val = (dep_plain.get(name, {}).get("constructor", {}) or {}).get(arg)
            if val is None:
                f.append((ERROR, f"'{name}' is missing the shared constructor arg '{arg}' that its sibling(s) "
                                 f"{', '.join(x for x in present if x != name)} also take"))
                continue
            seen.setdefault(val.lower(), []).append(name)
        if len(seen) > 1:
            detail = "; ".join(f"{v} <- {', '.join(ns)}" for v, ns in seen.items())
            f.append((ERROR, f"sibling adapters disagree on the shared constructor arg '{arg}': {detail} — "
                             f"they were split from ONE adapter and must pass the identical address; a wrong "
                             f"one still deploys (it is a contract) and misprices or drops the leg silently"))

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
        kind = entry.get("accrualKind")
        if kind not in ACCRUAL_KINDS:
            f.append((ERROR, f"asset '{sym}' has accrualKind={kind!r} — must be exactly one of "
                             f"{list(ACCRUAL_KINDS)}. 08_DeployAssetKindRegistry is fail-closed "
                             f"with no default, so an absent, empty, mis-cased or unrecognised "
                             f"value aborts this chain's deploy. Note ConfigReader does no "
                             f"field-set validation: a misspelled KEY (accrualkind, accrual_kind) "
                             f"is silently ignored and reaches the deploy as absent."))
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
    f += base_allowlist_findings(chain_id, assets, dep_feeds)
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

    # THE accrualKind REQUIREMENT. The check reads `entry.get("accrualKind")` and tests membership of
    # ACCRUAL_KINDS, so a MISSING key arrives as Python `None` and fails the same membership test an
    # invalid string fails. That is correct — but it holds by a property of `.get`, not by anything
    # asserted, and the obvious "tidying" edit (`entry.get("accrualKind", "None")`) would silently
    # default every unclassified asset to a REAL classification and leave the value arms below green.
    # Verified by mutation: that edit fails exactly the two arms below that name absence, and no others.
    #
    # Mutation is on an in-memory deep copy and `cfg` is restored in `finally`, for the same reason the
    # heartbeat arm above does it: `script/config` is the record of what production runs.
    print("accrualKind requirement, mutated against the real mainnet config:")
    real_cfg = globals()["cfg"]
    real_assets_ak = real_cfg("assets-and-price-feeds", 1)
    if not real_assets_ak or "WETH" not in real_assets_ak:
        check("mainnet assets readable for the accrualKind arm", False)
    else:
        def _ak_errs(mutate) -> list[str]:
            mutated = copy.deepcopy(real_assets_ak)
            mutate(mutated)
            globals()["cfg"] = lambda sub, cid: (
                mutated if (sub == "assets-and-price-feeds" and cid == 1) else real_cfg(sub, cid))
            try:
                return [m for m in errs(_check_chain(1)) if "accrualKind" in m and "'WETH'" in m]
            finally:
                globals()["cfg"] = real_cfg

        # The clean case first. Without it the arms below are vacuous: a check that flagged EVERY asset
        # would pass all five mutations and still be worthless.
        check("WETH carries a legal accrualKind in the real config (arm is not vacuous)",
              _ak_errs(lambda a: None) == [])
        check("a MISSING accrualKind key is rejected",
              len(_ak_errs(lambda a: a["WETH"].pop("accrualKind"))) == 1)
        check("a misspelled KEY ('accrualkind') is rejected — the real key reads as absent",
              len(_ak_errs(lambda a: a["WETH"].__setitem__(
                  "accrualkind", a["WETH"].pop("accrualKind")))) == 1)
        check("an out-of-vocabulary VALUE is rejected",
              len(_ak_errs(lambda a: a["WETH"].__setitem__("accrualKind", "Accruing"))) == 1)
        check("a mis-cased VALUE is rejected (comparison is case-exact)",
              len(_ak_errs(lambda a: a["WETH"].__setitem__("accrualKind", "appreciating"))) == 1)
        check("an EMPTY-STRING value is rejected, not treated as absent-and-defaulted",
              len(_ak_errs(lambda a: a["WETH"].__setitem__("accrualKind", ""))) == 1)
        check("the real config on disk was not modified by the accrualKind arm",
              real_cfg("assets-and-price-feeds", 1)["WETH"].get("accrualKind")
              == real_assets_ak["WETH"].get("accrualKind") is not None)

    # THE BASE ALLOWLIST. `base_allowlist_findings` must be able to answer NO — it fails on a base that is
    # not direct-priced, rather than merely passing when some base is present. The four rejection shapes are
    # kept DISTINCT on purpose: an absent key, an empty value, a malformed address and a wrong-but-parseable
    # base are four different config mistakes, and collapsing them would make the report say less than it
    # knows. The zero-address arm is the one that keeps the check honest in the other direction: a feed with
    # no NAV dependency must be able to SAY so, or the check would just ban a legitimate shape.
    print("base allowlist:")
    import copy as _copy
    _disk_cfg, _disk_dcfg = globals()["cfg"], globals()["dcfg"]
    B_WETH, B_DER, B_OTHER = "0x" + "a" * 40, "0x" + "b" * 40, "0x" + "c" * 40

    def _base_case(base_val, base_primary="Chainlink", omit=False, kind="priceFeeds",
                   base_feed_base=B_OTHER):
        # THREE assets, not two: when WETH's own primary is made Custom, its feed needs a legitimate base of
        # its own (USDC here, Chainlink-priced), or WETH's entry would raise its own unrelated error and the
        # arm would pass for the wrong reason — counting two errors while asserting the presence of one.
        assets_ = {
            "USDC": {"address": B_OTHER,
                     "priceFeeds": [{"type": "Chainlink", "address": B_OTHER, "heartbeat": 3600}]},
            "WETH": {"address": B_WETH,
                     "priceFeeds": [{"type": base_primary, "feed": "basefeed",
                                     "address": B_OTHER, "heartbeat": 3600}]},
            "DER": {"address": B_DER, kind: [{"type": "Custom", "feed": "der", "heartbeat": 86400}]},
        }
        ctor = {} if omit else {"baseAsset": base_val}
        feeds = {"der": {"enabled": True, "constructor": ctor},
                 "basefeed": {"enabled": True, "constructor": {"baseAsset": base_feed_base}}}
        return base_allowlist_findings(1, assets_, feeds)

    def _msgs(findings):
        return [m for s, m in findings if s == ERROR]

    check("a direct-priced base is ACCEPTED (arm is not vacuous)", _msgs(_base_case(B_WETH)) == [])
    check("a base priced by a Custom feed that declares NO NAV dependency is ACCEPTED (the ETHPlus shape)",
          _msgs(_base_case(B_WETH, base_primary="Custom", base_feed_base=ZERO_ADDR)) == [])
    check("an explicit zero-address baseAsset is ACCEPTED (declares no NAV dependency)",
          _msgs(_base_case(ZERO_ADDR)) == [])
    check("an ABSENT baseAsset key is an ERROR, named as absent",
          len(_msgs(_base_case(None, omit=True))) == 1
          and "does not declare a baseAsset" in _msgs(_base_case(None, omit=True))[0])
    check("an EMPTY baseAsset is an ERROR, distinct from absent",
          len(_msgs(_base_case(""))) == 1 and "EMPTY baseAsset" in _msgs(_base_case(""))[0])
    check("a MALFORMED baseAsset is an ERROR, distinct from empty",
          len(_msgs(_base_case("0xnot-an-address"))) == 1
          and "MALFORMED baseAsset" in _msgs(_base_case("0xnot-an-address"))[0])
    check("a baseAsset equal to the asset itself is an ERROR (the on-chain self case, caught earlier)",
          len(_msgs(_base_case(B_DER))) == 1 and "itself" in _msgs(_base_case(B_DER))[0])
    check("an UNREGISTERED baseAsset is an ERROR",
          len(_msgs(_base_case("0x" + "d" * 40))) == 1
          and "NOT a registered asset" in _msgs(_base_case("0x" + "d" * 40))[0])
    # The multi-hop cycle: the base is a registered asset, but its own primary is Custom.
    check("a base whose own primary is CUSTOM is an ERROR (multi-hop cycle the chain cannot see)",
          len(_msgs(_base_case(B_WETH, base_primary="Custom"))) == 1
          and "direct-feed allowlist" in _msgs(_base_case(B_WETH, base_primary="Custom"))[0])
    check("a MONITOR custom feed is checked too, not just primaries",
          len(_msgs(_base_case(B_WETH, base_primary="Custom", kind="monitorFeeds"))) == 1)
    # A true mutual two-hop: A based on B and B based on A. BOTH legs must be reported, not just one —
    # reporting one would leave the operator fixing half a cycle.
    _mutual = base_allowlist_findings(
        1,
        {"A": {"address": B_WETH, "priceFeeds": [{"type": "Custom", "feed": "fa", "heartbeat": 3600}]},
         "B": {"address": B_DER, "priceFeeds": [{"type": "Custom", "feed": "fb", "heartbeat": 3600}]}},
        {"fa": {"enabled": True, "constructor": {"baseAsset": B_DER}},
         "fb": {"enabled": True, "constructor": {"baseAsset": B_WETH}}})
    check("a mutual two-hop cycle reports BOTH legs", len(_msgs(_mutual)) == 2)

    print("base allowlist, mutated against the real mainnet config:")
    real_assets_bl = _disk_cfg("assets-and-price-feeds", 1)
    real_feeds_bl = _disk_dcfg("custom-price-feeds", 1)
    if not real_assets_bl or not real_feeds_bl:
        check("mainnet config readable for the base-allowlist arm", False)
    else:
        check("the real mainnet config raises ZERO base-allowlist errors",
              _msgs(base_allowlist_findings(1, real_assets_bl, real_feeds_bl)) == [])
        # Turn WETH itself into a Custom-priced asset. Every WETH-based feed on mainnet must then fail —
        # this is the exact shape of the cycle, applied to the real registry rather than a synthetic one.
        mutated_bl = _copy.deepcopy(real_assets_bl)
        mutated_bl["WETH"]["priceFeeds"] = [{"type": "Custom", "feed": "wstETH", "heartbeat": 3600}]
        n_cycle = len(_msgs(base_allowlist_findings(1, mutated_bl, real_feeds_bl)))
        check(f"making WETH Custom-priced makes every WETH-based feed fail ({n_cycle} errors)",
              n_cycle >= 15)
        # And dropping the baseAsset key from a real feed is caught, which is the silent-drop case.
        mutated_key = _copy.deepcopy(real_feeds_bl)
        mutated_key["wstETH"]["constructor"].pop("baseAsset", None)
        check("removing baseAsset from the real wstETH feed entry is an ERROR",
              any("does not declare a baseAsset" in m
                  for m in _msgs(base_allowlist_findings(1, real_assets_bl, mutated_key))))
        check("the real config on disk was not modified by the base-allowlist arms",
              _disk_cfg("assets-and-price-feeds", 1)["WETH"]["priceFeeds"][0]["type"] == "Chainlink"
              and "baseAsset" in _disk_dcfg("custom-price-feeds", 1)["wstETH"]["constructor"])

    # THE SNAPSHOT-STALENESS FAILURE MATRIX. The correct answer is exactly ONE emission in every cell.
    # This path had no arm at all, in either direction, which is how two successive wrong placements —
    # one duplicating the warning, one LOSING it — both shipped on a fully green suite. The dimension the
    # signal lives on is (where a chain fails) x (which chain fails), and it needs THREE chains: with two,
    # a non-first failure has no successor and the losing cell is unreachable, so a wrong fix looks proved.
    import contextlib as _ctx
    import io as _io

    _MC = [1, 10, 8453]

    def _emissions(where, idx):
        real_counts, real_enabled, real_report = counts, enabled_keys, chain_report
        real_resolve = c.resolve_chains
        import declared_heartbeat_guard as _g
        real_age = _g.snapshot_age_findings
        _g.snapshot_age_findings = lambda snap: [(WARN, "MATRIX-STALE")]
        _g._reset_snapshot_findings_once()
        state = {}
        try:
            globals()["enabled_keys"] = lambda d: (_ for _ in ()).throw(
                RuntimeError("matrix")) if where == "inside" and state.get("cid") == _MC[idx] \
                else real_enabled(d)
            globals()["counts"] = lambda cid: (_ for _ in ()).throw(
                RuntimeError("matrix")) if where == "after" and cid == _MC[idx] else real_counts(cid)

            # Patch the seam `main` ACTUALLY CALLS. This arm used to wrap `check_chain`; when the
            # single-scope fix moved main() onto `chain_report`, that wrapper stopped being reached and
            # the arm passed against a known-bad mutation — vacuous, in the very test written to stop a
            # signal defect landing green. Anchoring on the wrong seam is the same class of error as
            # under-dimensioning the input: the scenario is never reached, so every variant looks correct.
            def _cr(cid):
                state["cid"] = cid
                return real_report(cid)

            globals()["chain_report"] = _cr
            c.resolve_chains = lambda a: (_MC, "matrix")
            buf = _io.StringIO()
            with _ctx.redirect_stdout(buf), _ctx.redirect_stderr(buf):
                import sys as _sys
                argv = _sys.argv
                _sys.argv = ["preflight_config.py"]
                try:
                    main()
                except SystemExit:
                    pass
                finally:
                    _sys.argv = argv
            return buf.getvalue().count("MATRIX-STALE")
        finally:
            globals()["counts"], globals()["enabled_keys"] = real_counts, real_enabled
            globals()["chain_report"] = real_report
            c.resolve_chains = real_resolve
            _g.snapshot_age_findings = real_age
            _g._reset_snapshot_findings_once()

    cells = [("no failure", None, 0)]
    for _w in ("inside", "after"):
        for _i, _lab in ((0, "1st"), (1, "2nd"), (2, "last")):
            cells.append((f"raise {_w}, {_lab} chain", _w, _i))
    bad_cells = [(lab, _emissions(w, i)) for lab, w, i in cells]
    bad_cells = [(lab, n) for lab, n in bad_cells if n != 1]
    print(f"  {'PASS' if not bad_cells else 'FAIL'}  snapshot-staleness matrix: exactly 1 emission in "
          f"all {len(cells)} failure scenarios")
    for lab, n in bad_cells:
        print(f"           {lab}: {n} emissions ({'LOST' if n == 0 else 'DUPLICATED'})")
        failures.append(f"staleness matrix: {lab}")

    print(f"\nself-test: {'all checks passed' if not failures else str(len(failures)) + ' FAILED'}")
    return 1 if failures else 0


def base_report(chains) -> int:
    """The NAV-sourced base graph, and the two numbers quoted in `PriceFeedLib._validateFeedNotCircular`.

    Exists so those numbers can be RE-DERIVED rather than trusted. They move whenever config does, and a
    docstring quoting a stale count is worse than one quoting none.
    """
    total = 0
    cyclic = 0
    pinned = 0
    bases: dict[str, set[str]] = {}
    # The ERC-4626 family is the only one whose base is pinned by its own constructor
    # (`baseAsset == IERC4626(vault).asset()`, reverting BaseAssetMismatch). Everything else takes the
    # base on trust from config, which is what makes the wrong-base axis a config problem.
    erc4626 = {"RWIV", "sGHO", "sUSDS", "sUSDe", "sXDAI", "syrupUSDC"}
    print(f"{'chain':>7}  {'asset':<12} {'feed':<24} {'base':<12} base primaries")
    for cid in chains:
        assets, feeds = cfg("assets-and-price-feeds", cid), dcfg("custom-price-feeds", cid)
        by_addr = {v["address"].lower(): k for k, v in assets.items()
                   if isinstance(v, dict) and isinstance(v.get("address"), str)}
        for sym, entry in sorted(assets.items()):
            if sym.startswith("$") or not isinstance(entry, dict):
                continue
            for kind in ("priceFeeds", "monitorFeeds"):
                for fd in entry.get(kind) or []:
                    if fd.get("type") != "Custom":
                        continue
                    fname = fd.get("feed", "")
                    fe = feeds.get(fname)
                    if not fe:
                        continue
                    total += 1
                    pinned += fname in erc4626
                    raw = fe.get("constructor", fe).get("baseAsset")
                    if not is_address_shaped(raw) or int(raw, 16) == 0:
                        print(f"{cid:>7}  {sym:<12} {fname:<24} {'(none)':<12} not NAV-sourced")
                        continue
                    bsym = by_addr.get(raw.lower(), raw)
                    prim = [x.get("type") for x in (assets.get(bsym) or {}).get("priceFeeds") or []]
                    cyclic += "Custom" in prim
                    bases.setdefault(f"{cid}:{bsym}", set()).add(sym)
                    print(f"{cid:>7}  {sym:<12} {fname:<24} {bsym:<12} {prim}")
    print(f"\nNAV-sourced custom (asset, feed) pairs : {total}")
    print(f"distinct (chain, base) pairs           : {len(bases)}")
    print(f"pairs whose base is itself Custom-priced (any-length cycle) : {cyclic}")
    print(f"pairs with a constructor-PINNED base (ERC-4626 family)      : {pinned}")
    print(f"pairs relying on config correctness for the base            : {total - pinned}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("chains", nargs="*", type=int)
    ap.add_argument("--json", help="also write the full report to this path")
    ap.add_argument("--self-test", action="store_true",
                    help="prove the heartbeat guard (synthetic arms + real-config mutation) and exit")
    ap.add_argument("--base-report", action="store_true",
                    help="print the NAV-sourced base graph and the cycle/config-only counts, and exit")
    args = ap.parse_args()
    c.load_env()

    if args.self_test:
        return self_test()
    if args.base_report:
        return base_report(c.resolve_chains(args.chains)[0])

    chains, scope_src = c.resolve_chains(args.chains)
    print(f"scope: {len(chains)} chain(s) from {scope_src}")
    report, n_err, n_warn = {}, 0, 0
    totals = Counter()

    # SNAPSHOT-LEVEL findings, emitted exactly once, before the loop and outside every per-chain guard.
    # The snapshot's age is a property of the file, so it belongs to the RUN, not to a chain. Emitting it
    # per-chain forced a once-per-process latch, and no condition over a chain's findings can answer
    # "did THIS chain consume the latch and then lose the message?" — the information is not in there.
    # Hoisting removes the question instead of answering it.
    try:
        import declared_heartbeat_guard as _dhg

        snapshot_findings = _dhg.snapshot_findings_once()
    except SystemExit as e:
        snapshot_findings = [(WARN, f"declared-heartbeat snapshot unavailable: {e}")]
    except Exception as e:  # noqa: BLE001 - must never take out the per-chain checks
        snapshot_findings = [(WARN, f"declared-heartbeat snapshot could not be aged: {e!r}")]
    for _sev, _msg in snapshot_findings:
        print(f"  [{_sev}] {_msg}")
        n_err += _sev == ERROR
        n_warn += _sev == WARN
    report["snapshot"] = [{"severity": s_, "message": m_} for s_, m_ in snapshot_findings]

    for cid in chains:
        # One chain must not be able to kill the run, and everything that reads config for it lives in ONE
        # collecting scope inside `chain_report` — findings, counts and chain name together. Two earlier
        # versions of this containment were defeated by a call left just outside the guard, and a third
        # split the work across two scopes, which duplicated every parse error instead of deduping it.
        # No staleness handling here, deliberately: that signal is emitted once above the loop, so a chain
        # that fails cannot consume, duplicate or lose it.
        findings, k, name, degraded = chain_report(cid)
        for key, v in k.items():
            totals[key] += v
        report[str(cid)] = {"name": name,
                            "counts": k,
                            # Marked, so a zeroed row cannot be mistaken for a chain that really
                            # configures nothing when reconciling the runbook's totals.
                            "countsDegraded": degraded,
                            "findings": [{"severity": s, "message": m} for s, m in findings]}
        errs = [x for x in findings if x[0] == ERROR]
        warns = [x for x in findings if x[0] == WARN]
        n_err += len(errs)
        n_warn += len(warns)
        head = (f"  {cid:8} {name:16} "
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
