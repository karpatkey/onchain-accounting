#!/usr/bin/env python3
"""
Generate a detailed NAV vs DeBank comparison report in Markdown.

The report has six sections:

  Section 1 — Account-level drift summary
  Section 2 — Protocol-level pairing (per account × chain)
  Section 3 — Per-adapter granular detail: one table per adapter instance, per account,
               showing NAV vs DeBank amounts AND unit prices so amount drift (balance-adapter
               signal) and price drift (price-feed signal) can be graded independently.
  Section 4 — Coverage gaps: DeBank protocols with value not in supportedDeBankProtocols
               (4.1) and supported protocol items with no NAV match (4.2).
  Section 5 — Untracked-by-design footer (rationale in accounts.json.$untracked_by_design)
  Section 6 — Stale price / sequencer flags per account × chain

NAV position detail is read from test/integration/nav-positions-<chainId>.json,
written by IntegrationFromConfigBase during the refresh run.

DeBank data is loaded from test/integration/debank-cache/ by default when that directory
exists; otherwise a live DeBank API fetch is performed (requires DEBANK_API_KEY).

Usage:
    # Default: use cache if available, else call live API
    . ./.env && python3 script/test/generate-comparison-report.py

    # Force live API call + update cache + overwrite debankUsd in accounts.json
    . ./.env && python3 script/test/generate-comparison-report.py --refresh-debank

    # Regenerate report from cache only (no API key required)
    python3 script/test/generate-comparison-report.py --from-cache

Output: comparison-report.md
"""

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

DEBANK_API_KEY = os.environ.get("DEBANK_API_KEY", "")
DEBANK_BASE = "https://pro-openapi.debank.com"
ACCOUNTS_JSON = "test/integration/accounts.json"
NAV_ASSETS_PATTERN = "script/config/nav-config/assets-and-price-feeds/{chain_id}.json"
CHAINS_CONFIG_DIR = "script/config/chains"
NAV_POSITIONS_PATTERN = "test/integration/nav-positions-{chain_id}.json"
DEBANK_CACHE_DIR = "test/integration/debank-cache"
OUT_FILE = "comparison-report.md"
NATIVE_SENTINEL = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

# Display-only rename for DeBank protocol IDs in the rendered "DeBank ID" column.
# Honors the project naming convention from CLAUDE.md ("Morpho not Morpho Blue").
DEBANK_ID_DISPLAY: dict[str, str] = {
    "morphoblue": "morpho",
}

# WALLET_AGGREGATING adapters aggregate wallet token balances into a single
# PositionBalance denominated in another asset (e.g. Cap reads cUsd + stcUsd → USDC).
WALLET_AGGREGATING_DEBANK_IDS: dict[str, str] = {
    "capapp": "Cap",
}

# NET_POSITION adapters report a single net PositionBalance for what DeBank shows as
# a split supply+borrow row (e.g. StakeWise V3 vaults).
NET_POSITION_DEBANK_IDS: dict[str, str] = {
    "stakewise": "StakeWise V3",
}

# CONTROLLER_MERGE_DEBANK_IDS: DeBank protocols where the same position is split across
# multiple portfolio_item_list entries sharing the same pool.controller address (e.g.
# Compound V3 splits supply into a "Yield" item and rewards into a "Lending" item for the
# same Comet market). Items sharing a controller are merged before matching so that all
# NAV positions for that market are matched together against the combined token list.
CONTROLLER_MERGE_DEBANK_IDS: set[str] = {"compound3"}

WALLET_AGGREGATING_ADAPTERS_JSON = "script/test/wallet-aggregating-adapters.json"
with open(WALLET_AGGREGATING_ADAPTERS_JSON) as _wa_f:
    WALLET_AGGREGATING_ADAPTERS: dict[str, list[str]] = {
        k: v for k, v in json.load(_wa_f).items() if not k.startswith("$")
    }

# Maps NAV adapter `protocol` prefixes to DeBank protocol short-IDs.
# Longer prefixes take priority over shorter ones.
NAV_PROTOCOL_TO_DEBANK_IDS: dict[str, list[str]] = {
    "Aave V2": ["aave2"],
    # Old protocol strings (deployed adapters; kept for backward compat until redeployed)
    "Aave Umbrella": ["aave3"],
    # DeBank reports stkAAVE (Safety Module) under aave2, not aave3 — include aave2 so
    # those positions are candidates when matching the aave2 staked row.
    "Aave V3 Safety Module": ["aave3", "aave2"],
    # New canonical strings (post-redeploy adapters). aave2 included for the same reason
    # as Aave V3 Safety Module above (stkAAVE classified under aave2 by DeBank).
    "Aave V3": ["aave3", "aave2"],
    "Morpho": ["morphoblue"],
    "Compound v3": ["compound3"],  # legacy casing
    "Compound V3": ["compound3"],  # canonical (meta-adapter)
    "Balancer V3": ["balancer3", "balancer2"],
    "Spark": ["spark"],
    "Curve": ["curve"],
    "Convex": ["convex"],
    "Merkl": ["merkl"],
    "Fluid": ["fluid"],
    "Cap": ["capapp"],
    "Kelp DAO": ["kelpdao"],
    "Rocket Pool": ["rocketpool"],
    "Lido": ["lido"],
    "Ethena": ["ethena"],
    "ether.fi": ["etherfi"],
    "Stakewise v3": ["stakewise"],   # old casing — keep until redeployed
    "StakeWise V3": ["stakewise"],   # canonical
    "Stader": ["stader"],
    "Uniswap V3": ["uniswap3"],
    "Uniswap V2": ["uniswap2"],
    "Sky": ["sky"],
    "Sablier": ["sablier"],
    "Gearbox": ["gearbox"],
    "PancakeSwap V3": ["pancakeswap3"],
    "PancakeSwap V2": ["pancakeswap"],
}

# Reverse map: debank_id → NAV protocol prefixes that cover it (for gap annotation).
_DEBANK_ID_TO_NAV_PROTOCOLS: dict[str, list[str]] = {}
for _proto, _ids in NAV_PROTOCOL_TO_DEBANK_IDS.items():
    for _did in _ids:
        _DEBANK_ID_TO_NAV_PROTOCOLS.setdefault(_did, []).append(_proto)

WALLET_SYMBOL_TO_DEBANK_IDS: dict[str, list[str]] = {
    "sUSDS": ["sky"],
    "sXDAI": ["gnosis"],
    "sDAI": ["gnosis", "spark"],
    "stETH": ["lido"],
    "wstETH": ["lido"],
    "rETH": ["rocketpool"],
    "weETH": ["etherfi"],
    "sUSDe": ["ethena"],
    "rsETH": ["kelpdao"],
    "osETH": ["stakewise"],
    "ezETH": ["renzo"],
    "cbETH": ["coinbase_wrapped_staked_eth"],
    "mETH": ["mantle_staking"],
    # Stader: ETHx wallet balance + withdrawal-queue adapter both map to "stader".
    # DeBank groups the LST holding under the stader protocol; NAV values it via
    # the ETHx custom price feed as a plain wallet token.
    "ETHx": ["stader"],
}


# ── LegMatch dataclass ────────────────────────────────────────────────────────

@dataclass
class LegMatch:
    """One matched (or unmatched) leg: a single NAV position paired with the
    corresponding DeBank token entry, with drift fields computed on access."""
    account: str
    chain_id: str
    account_label: str
    protocol: str           # NAV protocol name — from protocolName (new) or protocol (legacy)
    debank_id: str          # DeBank short id (e.g. "compound3"); "" for nav_only
    position_id: str        # NAV positionId (bytes hex, new) or hex addr string (legacy)
    position_detail: dict   # NAV positionDetail JSON object (legacy; empty dict in new format)
    leg_kind: str           # e.g. "supply", "borrow", "reward", "fees", "staking"
    symbol: str
    is_debt: bool
    nav_amount: Optional[float]           # token units
    nav_unit_price_usd: Optional[float]   # USD per token
    nav_usd: Optional[float]             # valueUsd8dp / 1e8
    debank_amount: Optional[float]
    debank_unit_price_usd: Optional[float]
    debank_usd: Optional[float]
    match_stage: str   # "1", "2", "3", "3b", "pf", "nav_only"
    item_label: str = ""


# ── Drift helpers ─────────────────────────────────────────────────────────────

def _drift_pct(nav: Optional[float], ref: Optional[float]) -> Optional[float]:
    """Return (nav - ref) / ref * 100, or None if either side is missing/zero."""
    if nav is None or ref is None or ref == 0:
        return None
    return (nav - ref) / ref * 100.0


def _drift_severity(v: Optional[float]) -> str:
    if v is None:
        return ""
    av = abs(v)
    if av <= 1.0:
        return "OK"
    if av <= 5.0:
        return "WARN"
    return "FAIL"


def fmt_drift_cell(v: Optional[float]) -> str:
    """Return e.g. 'OK +0.12%' or 'WARN -2.34%' or 'FAIL +8.90%' or '—'."""
    if v is None:
        return "—"
    sev = _drift_severity(v)
    sign = "+" if v >= 0 else ""
    return f"{sev} {sign}{v:.2f}%"


# ── Utility helpers (unchanged) ───────────────────────────────────────────────

def debank_ids_for_nav_protocol(protocol: str) -> list[str]:
    best_prefix = ""
    best_ids: list[str] = []
    for prefix, ids in NAV_PROTOCOL_TO_DEBANK_IDS.items():
        if protocol.startswith(prefix) and len(prefix) > len(best_prefix):
            best_prefix = prefix
            best_ids = ids
    return best_ids


def adapter_aggregated_addrs(cid: str) -> set[str]:
    try:
        with open(f"{CHAINS_CONFIG_DIR}/{cid}.json") as f:
            adapters = json.load(f).get("balanceAdapters", {})
    except FileNotFoundError:
        return set()
    addrs: set[str] = set()
    for key, params in WALLET_AGGREGATING_ADAPTERS.items():
        cfg = adapters.get(key)
        if not cfg or not cfg.get("enabled"):
            continue
        ctor = cfg.get("constructor", {})
        for p in params:
            v = ctor.get(p)
            if v:
                addrs.add(v.lower())
    return addrs


def disabled_lp_pool_addrs(cid: str) -> set[str]:
    try:
        with open(f"{CHAINS_CONFIG_DIR}/{cid}.json") as f:
            adapters = json.load(f).get("balanceAdapters", {})
    except FileNotFoundError:
        return set()
    addrs: set[str] = set()
    for _key, params in adapters.items():
        if params.get("enabled", True):
            continue
        ctor = params.get("constructor", {})
        pool = ctor.get("pool") or ctor.get("pair")
        if pool:
            addrs.add(pool.lower())
    return addrs


def debank_get(path, params=""):
    url = f"{DEBANK_BASE}{path}{'?' + params if params else ''}"
    r = subprocess.run(
        ["curl", "-sf", "--max-time", "30", "--retry", "2",
         "-H", f"AccessKey: {DEBANK_API_KEY}", url],
        capture_output=True, text=True,
    )
    if r.returncode != 0 or not r.stdout.strip():
        print(f"  [warn] empty/error response for {url}", file=sys.stderr)
        return []
    return json.loads(r.stdout)


def fmt_usd(v):
    if v is None:
        return "—"
    if abs(v) >= 1_000_000:
        return f"${v / 1_000_000:.3f}M"
    if abs(v) >= 1_000:
        return f"${v:,.2f}"
    return f"${v:.4f}"


def fmt_amt(v):
    if abs(v) >= 1_000_000:
        return f"{v / 1_000_000:.4f}M"
    if abs(v) >= 1_000:
        return f"{v:,.4f}"
    return f"{v:.6f}"


def token_inline(t):
    sym = t.get("symbol", "?")
    amt = t.get("amount", 0)
    price = t.get("price", 0)
    usd = amt * price
    return f"{sym} {fmt_amt(amt)} ({fmt_usd(usd)})"


def load_nav_positions(chain_id: str) -> dict[str, list]:
    path = NAV_POSITIONS_PATTERN.format(chain_id=chain_id)
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        data = json.load(f)
    return {k.lower(): v for k, v in data.get("accounts", {}).items()}


def proto_net_usd(p) -> float:
    return sum(
        i.get("stats", {}).get("net_usd_value", 0)
        for i in p.get("portfolio_item_list", [])
    )


def normalise_pid(pid: str, dbank_chain: str) -> str:
    prefix = f"{dbank_chain}_"
    return pid[len(prefix):] if pid.startswith(prefix) else pid


def find_debank_proto(chain_protos: list, short_ids: list[str]) -> list:
    return [p for p in chain_protos if p.get("_short_id", "") in short_ids]


def find_debank_proto_by_symbol(chain_protos: list, symbol: str) -> tuple[str, float] | None:
    for p in chain_protos:
        short_id = p.get("_short_id", "")
        for item in p.get("portfolio_item_list", []):
            detail = item.get("detail", {})
            for tok in detail.get("supply_token_list", []) + detail.get("reward_token_list", []):
                if tok.get("symbol", "").lower() == symbol.lower():
                    return short_id, proto_net_usd(p)
    return None


def build_debank_proto_detail(p: dict) -> str:
    cells = []
    for item in p.get("portfolio_item_list", []):
        detail = item.get("detail", {})
        parts = []
        if detail.get("supply_token_list"):
            parts.append("supply: " + " + ".join(token_inline(t) for t in detail["supply_token_list"]))
        if detail.get("borrow_token_list"):
            parts.append("borrow: " + " + ".join(token_inline(t) for t in detail["borrow_token_list"]))
        if detail.get("reward_token_list"):
            parts.append("rewards: " + " + ".join(token_inline(t) for t in detail["reward_token_list"]))
        net = item.get("stats", {}).get("net_usd_value", 0)
        cells.append(("; ".join(parts) if parts else "—") + f" → **{fmt_usd(net)}**")
    return "<br>".join(cells) if cells else "—"


def build_item_label(item: dict) -> str:
    desc = item.get("detail", {}).get("description", "")
    name = item.get("name", "")
    ctrl = (item.get("pool") or {}).get("controller", "")
    label = desc or name or "—"
    if ctrl:
        label += f" (`{ctrl[:10]}…`)"
    return label


def merge_items_by_controller(items: list[dict]) -> list[dict]:
    """Merge portfolio items that share the same pool.controller into a single logical item.
    The merged item has combined supply/borrow/reward token lists and summed net_usd_value.
    Items without a controller are left as-is."""
    from collections import defaultdict, OrderedDict
    by_ctrl: dict[str, list[dict]] = OrderedDict()
    no_ctrl: list[dict] = []
    for item in items:
        ctrl = (item.get("pool") or {}).get("controller", "").lower()
        if ctrl:
            by_ctrl.setdefault(ctrl, []).append(item)
        else:
            no_ctrl.append(item)
    merged: list[dict] = []
    for ctrl, group in by_ctrl.items():
        if len(group) == 1:
            merged.append(group[0])
            continue
        combined_detail: dict = {"supply_token_list": [], "borrow_token_list": [], "reward_token_list": []}
        combined_usd = 0.0
        names = []
        for g in group:
            d = g.get("detail", {})
            combined_detail["supply_token_list"] += d.get("supply_token_list", [])
            combined_detail["borrow_token_list"] += d.get("borrow_token_list", [])
            combined_detail["reward_token_list"] += d.get("reward_token_list", [])
            combined_usd += g.get("stats", {}).get("net_usd_value", 0)
            n = g.get("name", "") or g.get("detail", {}).get("description", "")
            if n and n not in names:
                names.append(n)
        first = group[0]
        merged.append({
            **first,
            "name": " + ".join(names) if names else first.get("name", ""),
            "detail": {**first.get("detail", {}), **combined_detail},
            "stats": {"net_usd_value": combined_usd},
        })
    return merged + no_ctrl


def build_item_tokens(item: dict) -> str:
    detail = item.get("detail", {})
    parts = []
    for tok in detail.get("supply_token_list", []):
        parts.append(f"supply {tok.get('symbol','?')} {fmt_amt(tok.get('amount', 0))}")
    for tok in detail.get("borrow_token_list", []):
        parts.append(f"borrow {tok.get('symbol','?')} {fmt_amt(tok.get('amount', 0))}")
    for tok in detail.get("reward_token_list", []):
        parts.append(f"reward {tok.get('symbol','?')} {fmt_amt(tok.get('amount', 0))}")
    return " + ".join(parts) if parts else "—"


def _leg_kind(pos: dict) -> str:
    """Derive human-readable leg kind from positionKind (new) or positionDetail.type (legacy).

    New format: positionKind is a uint8 — 0=Wallet, 1=Supplied, 2=Borrowed, 3=Collateral,
    4=Staking, 5=Rewards, 6=Fees (matches the PositionKind enum in src/utils/PositionKind.sol).
    Legacy format: positionDetail.type is a string — "Supply"/"Borrow"/"Collateral"/"Staking"/etc.
    """
    # New format: positionKind uint8
    if "positionKind" in pos:
        kind_map = {0: "Wallet", 1: "Supply", 2: "Borrow", 3: "Collateral", 4: "Staking", 5: "Rewards", 6: "Fees"}
        try:
            n = int(pos["positionKind"])
            # Surface unmapped values as Unknown(<n>) rather than silently labelling them "Supply" —
            # an unrecognised ordinal means enum drift (a new PositionKind), exactly what this report should flag.
            return kind_map.get(n, f"Unknown({n})")
        except (ValueError, TypeError):
            pass
    # Legacy format: positionDetail.type
    det = pos.get("positionDetail", {})
    if isinstance(det, dict):
        t = det.get("type", "").strip()
        if t:
            return t
    return "Borrow" if pos.get("isDebt") else "Supply"


def _nav_protocol(pos: dict) -> str:
    """Extract the protocol name from a NAV position dict.

    New format: protocolName field (human-readable string from IPositionDescribable).
    Legacy format: protocol field (e.g. "Compound v3 USDC").
    """
    # New format first
    name = pos.get("protocolName", "").strip()
    if name:
        return name
    # Legacy format
    # This helper is defined above; this line is unreachable
    return ""


# ── DeBank cache I/O ──────────────────────────────────────────────────────────

def _cache_proto_path(addr: str) -> str:
    return os.path.join(DEBANK_CACHE_DIR, f"{addr.lower()}-protocols.json")


def _cache_tok_path(addr: str, cid: str) -> str:
    return os.path.join(DEBANK_CACHE_DIR, f"{addr.lower()}-tokens-{cid}.json")


def load_protocols_from_cache(addr: str) -> list | None:
    path = _cache_proto_path(addr)
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


def load_tokens_from_cache(addr: str, cid: str) -> list | None:
    path = _cache_tok_path(addr, cid)
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


def save_protocols_to_cache(addr: str, proto_resp: list) -> None:
    os.makedirs(DEBANK_CACHE_DIR, exist_ok=True)
    with open(_cache_proto_path(addr), "w") as f:
        json.dump(proto_resp, f, indent=2)
        f.write("\n")


def save_tokens_to_cache(addr: str, cid: str, tok_resp: list) -> None:
    os.makedirs(DEBANK_CACHE_DIR, exist_ok=True)
    with open(_cache_tok_path(addr, cid), "w") as f:
        json.dump(tok_resp, f, indent=2)
        f.write("\n")


# ── render_unified_table ──────────────────────────────────────────────────────

def render_unified_table(
    nav_positions: list,
    chain_protos: list,
    wallet_tokens: list,
    supported_ids: set[str],
    reg_addrs: set[str],
    priced_addrs: set[str],
    agg_addrs: set[str],
    dbank_chain: str,
    disabled_pools: set[str] | None = None,
    # Extended parameters for cross-section data collection:
    leg_matches_out: list | None = None,
    coverage_gaps_out: list | None = None,
    global_untracked_out: list | None = None,
    account: str = "",
    chain_id: str = "",
    chain_name: str = "",
    account_label: str = "",
) -> list[str]:
    """
    Render two DeBank-first tables (protocol positions + wallet tokens), each
    extended with NAV match columns on the right.

    Extended parameters (all optional, default None/empty):
    - leg_matches_out: accumulator for LegMatch records (used for Section 3)
    - coverage_gaps_out: accumulator for unmatched supported-protocol items (Section 4.2)
    - global_untracked_out: accumulator for untracked protocol entries (Section 4.1)
    - account/chain_id/chain_name/account_label: context for the above records
    """
    if disabled_pools is None:
        disabled_pools = set()
    if not nav_positions and not chain_protos and not wallet_tokens:
        return ["_No positions on this chain._", ""]

    all_covered = reg_addrs | agg_addrs

    # ── Pre-index NAV positions ─────────────────────────────────────────────────
    debank_to_pf_symbols: dict[str, set[str]] = {}
    for sym, dids in WALLET_SYMBOL_TO_DEBANK_IDS.items():
        for did in dids:
            debank_to_pf_symbols.setdefault(did, set()).add(sym.lower())

    matched_nav: set[int] = set()

    nav_adapters_by_debank: dict[str, list[tuple[int, dict]]] = {}
    nav_pf_by_addr: dict[str, tuple[int, dict]] = {}
    nav_pf_by_symbol: dict[str, tuple[int, dict]] = {}

    for idx, pos in enumerate(nav_positions):
        if _nav_protocol(pos) == "wallet":
            addr = pos.get("address", "").lower()
            nav_pf_by_addr.setdefault(addr, (idx, pos))
            sym_l = pos.get("symbol", "").lower()
            nav_pf_by_symbol.setdefault(sym_l, (idx, pos))
        else:
            for did in debank_ids_for_nav_protocol(_nav_protocol(pos)):
                nav_adapters_by_debank.setdefault(did, []).append((idx, pos))

    def _nav_unit_price(pos: dict) -> Optional[float]:
        p = int(pos.get("price", 0))
        pd = int(pos.get("priceDecimals", 8))
        return p / 10 ** pd if p > 0 else None

    def _nav_amount_float(pos: dict) -> float:
        decimals = int(pos.get("decimals", 18))
        return int(pos.get("amount", 0)) / 10 ** decimals

    def _nav_usd(pos: dict) -> float:
        return int(pos.get("valueUsd8dp", 0)) / 1e8

    def _match_nav_for_item(item: dict, short_id: str) -> list[tuple[str, str, str]]:
        """Match one DeBank portfolio item to all matching NAV adapter positions.
        As a side effect appends LegMatch records to leg_matches_out (if provided)."""
        detail = item.get("detail", {})
        tokens = (
            [(t, False) for t in detail.get("supply_token_list", [])]
            + [(t, True) for t in detail.get("borrow_token_list", [])]
            + [(t, False) for t in detail.get("reward_token_list", [])]
        )
        candidates = [(idx, p) for idx, p in nav_adapters_by_debank.get(short_id, [])
                      if idx not in matched_nav]
        if not candidates:
            return []

        results: list[tuple[str, str, str]] = []
        local_matched: set[int] = set()

        # Stage 1: two-pass symbol+debt match.
        # Pass A (strict): match tokens within 10% amount tolerance.
        # Pass B (relaxed): for tokens still unmatched after pass A, pick the closest
        #   remaining candidate regardless of distance (stage "1b").  This handles large
        #   interest-accrual gaps between the fork block and the DeBank query time (e.g.
        #   a Morpho market that grew from 16.18 → 18.36 USDC between snapshots).
        def _do_stage1_pass(token_list, strict: bool):
            for tok, is_borrow in token_list:
                s_sym = tok.get("symbol", "").lower()
                s_amt = float(tok.get("amount", 0))
                if s_amt <= 0:
                    continue
                best_idx, best_pos, best_score = None, None, float("inf")
                for idx, p in candidates:
                    if idx in local_matched:
                        continue
                    if p.get("symbol", "").lower() != s_sym:
                        continue
                    if bool(p.get("isDebt", False)) != is_borrow:
                        continue
                    p_amt = _nav_amount_float(p)
                    if p_amt <= 0:
                        continue
                    score = abs(p_amt - s_amt) / s_amt
                    if score < best_score:
                        best_score, best_idx, best_pos = score, idx, p
                if best_idx is None:
                    continue
                if strict and best_score > 0.10:
                    continue
                local_matched.add(best_idx)
                matched_nav.add(best_idx)
                sym = best_pos.get("symbol", "?")
                amt = _nav_amount_float(best_pos)
                usd = _nav_usd(best_pos)
                label = _leg_kind(best_pos)
                results.append((_nav_protocol(best_pos), f"{label} {sym} {fmt_amt(amt)}", fmt_usd(usd)))
                if leg_matches_out is not None:
                    db_amt = float(tok.get("amount", 0))
                    db_price = float(tok.get("price", 0))
                    leg_matches_out.append(LegMatch(
                        account=account, chain_id=chain_id, account_label=account_label,
                        protocol=_nav_protocol(best_pos),
                        debank_id=short_id,
                        position_id=best_pos.get("positionId", ""),
                        position_detail=best_pos.get("positionDetail", {}),
                        leg_kind=_leg_kind(best_pos),
                        symbol=best_pos.get("symbol", "?"),
                        is_debt=bool(best_pos.get("isDebt", False)),
                        nav_amount=amt,
                        nav_unit_price_usd=_nav_unit_price(best_pos),
                        nav_usd=usd,
                        debank_amount=db_amt,
                        debank_unit_price_usd=db_price if db_price > 0 else None,
                        debank_usd=db_amt * db_price,
                        match_stage="1" if strict else "1b",
                        item_label=build_item_label(item),
                    ))

        _do_stage1_pass(tokens, strict=True)
        # Identify tokens still unmatched after strict pass (by symbol+debt+amount tuple)
        strict_matched_keys = {
            (p.get("symbol", "").lower(), bool(p.get("isDebt", False)),
             round(_nav_amount_float(p), 6))
            for idx, p in candidates if idx in local_matched
        }
        unmatched_tokens = [
            (tok, is_borrow) for tok, is_borrow in tokens
            if float(tok.get("amount", 0)) > 0
            and not any(
                sym == tok.get("symbol", "").lower()
                and debt == is_borrow
                and abs(nav_a - float(tok.get("amount", 0))) / max(float(tok.get("amount", 0)), 1e-9) <= 0.10
                for sym, debt, nav_a in strict_matched_keys
            )
        ]
        _do_stage1_pass(unmatched_tokens, strict=False)

        # Stage 2: LP-pool / multi-leg fallback
        all_debank_syms = {
            tok.get("symbol", "").lower()
            for tok_list in [detail.get("supply_token_list", []),
                             detail.get("reward_token_list", [])]
            for tok in tok_list
            if tok.get("amount", 0) > 0
        }
        item_usd = item.get("stats", {}).get("net_usd_value", 0)
        if not all_debank_syms or item_usd <= 0:
            return results

        groups: dict[str, list[tuple[int, dict]]] = {}
        for idx, p in candidates:
            # Group by (protocol, positionId) so different adapter instances (e.g. different
            # Comet markets, different Curve pools) are never merged into the same LP group.
            key = (_nav_protocol(p), p.get("positionId", ""))
            groups.setdefault(key, []).append((idx, p))

        for group in groups.values():
            if len(group) < 2:
                continue
            group_syms = {p.get("symbol", "").lower() for _, p in group}
            if not group_syms.intersection(all_debank_syms):
                continue
            group_usd = sum(_nav_usd(p) for _, p in group)
            if item_usd > 0 and abs(group_usd - item_usd) / item_usd > 0.10:
                continue
            # All supply/borrow/reward tokens indexed by symbol for pairing
            all_item_toks_by_sym = {
                t.get("symbol", "").lower(): t
                for tok_list in [detail.get("supply_token_list", []),
                                 detail.get("borrow_token_list", []),
                                 detail.get("reward_token_list", [])]
                for t in tok_list if t.get("amount", 0) > 0
            }
            stage2_added = False
            for idx, p in group:
                if idx in local_matched:
                    continue
                matched_nav.add(idx)
                sym = p.get("symbol", "?")
                amt = _nav_amount_float(p)
                usd = _nav_usd(p)
                label = _leg_kind(p)
                results.append((_nav_protocol(p), f"{label} {sym} {fmt_amt(amt)}", fmt_usd(usd)))
                stage2_added = True
                if leg_matches_out is not None:
                    matched_db_tok = all_item_toks_by_sym.get(sym.lower())
                    db_amt = float(matched_db_tok.get("amount", 0)) if matched_db_tok else None
                    db_price = float(matched_db_tok.get("price", 0)) if matched_db_tok else None
                    db_usd = (db_amt * db_price) if (db_amt is not None and db_price is not None) else None
                    leg_matches_out.append(LegMatch(
                        account=account, chain_id=chain_id, account_label=account_label,
                        protocol=_nav_protocol(p),
                        debank_id=short_id,
                        position_id=p.get("positionId", ""),
                        position_detail=p.get("positionDetail", {}),
                        leg_kind=_leg_kind(p),
                        symbol=p.get("symbol", "?"),
                        is_debt=bool(p.get("isDebt", False)),
                        nav_amount=amt,
                        nav_unit_price_usd=_nav_unit_price(p),
                        nav_usd=usd,
                        debank_amount=db_amt,
                        debank_unit_price_usd=db_price if (db_price is not None and db_price > 0) else None,
                        debank_usd=db_usd,
                        match_stage="2",
                        item_label=build_item_label(item),
                    ))
            if stage2_added:
                break

        # Stage 3: WALLET_AGGREGATING adapters
        if not results and short_id in WALLET_AGGREGATING_DEBANK_IDS:
            for idx, p in candidates:
                if idx in local_matched:
                    continue
                local_matched.add(idx)
                matched_nav.add(idx)
                sym = p.get("symbol", "?")
                amt = _nav_amount_float(p)
                usd = _nav_usd(p)
                label = _leg_kind(p)
                results.append((_nav_protocol(p), f"{label} {sym} {fmt_amt(amt)}", fmt_usd(usd)))
                if leg_matches_out is not None:
                    leg_matches_out.append(LegMatch(
                        account=account, chain_id=chain_id, account_label=account_label,
                        protocol=_nav_protocol(p),
                        debank_id=short_id,
                        position_id=p.get("positionId", ""),
                        position_detail=p.get("positionDetail", {}),
                        leg_kind=_leg_kind(p),
                        symbol=p.get("symbol", "?"),
                        is_debt=bool(p.get("isDebt", False)),
                        nav_amount=amt,
                        nav_unit_price_usd=_nav_unit_price(p),
                        nav_usd=usd,
                        debank_amount=None,
                        debank_unit_price_usd=None,
                        debank_usd=item_usd,  # item-level only
                        match_stage="3",
                        item_label=build_item_label(item),
                    ))
                break

        # Stage 3b: NET_POSITION adapters
        if not results and short_id in NET_POSITION_DEBANK_IDS:
            has_supply = any(not is_borrow for tok, is_borrow in tokens
                             if float(tok.get("amount", 0)) > 0)
            has_borrow = any(is_borrow for tok, is_borrow in tokens
                             if float(tok.get("amount", 0)) > 0)
            if has_supply and has_borrow:
                for idx, p in candidates:
                    if idx in local_matched:
                        continue
                    local_matched.add(idx)
                    matched_nav.add(idx)
                    sym = p.get("symbol", "?")
                    amt = _nav_amount_float(p)
                    usd = _nav_usd(p)
                    label = _leg_kind(p)
                    results.append((_nav_protocol(p), f"{label} {sym} {fmt_amt(amt)}", fmt_usd(usd)))
                    if leg_matches_out is not None:
                        leg_matches_out.append(LegMatch(
                            account=account, chain_id=chain_id, account_label=account_label,
                            protocol=_nav_protocol(p),
                            debank_id=short_id,
                            position_id=p.get("positionId", ""),
                            position_detail=p.get("positionDetail", {}),
                            leg_kind=_leg_kind(p),
                            symbol=p.get("symbol", "?"),
                            is_debt=bool(p.get("isDebt", False)),
                            nav_amount=amt,
                            nav_unit_price_usd=_nav_unit_price(p),
                            nav_usd=usd,
                            debank_amount=None,
                            debank_unit_price_usd=None,
                            debank_usd=item_usd,
                            match_stage="3b",
                            item_label=build_item_label(item),
                        ))
                    break

        return results

    lines: list[str] = []

    untracked_protos: list[tuple[str, str, float, str]] = []
    untracked_wallet: list[tuple[str, float, str]] = []

    # ── Protocol positions table ──────────────────────────────────────────────────
    covered_protos = [p for p in chain_protos if p.get("_short_id", "") in supported_ids]

    for p in chain_protos:
        short_id = p.get("_short_id", "")
        if short_id in supported_ids:
            continue
        usd = proto_net_usd(p)
        if abs(usd) < 0.01:
            continue
        entry = (p.get("name", short_id), short_id, usd, build_debank_proto_detail(p))
        untracked_protos.append(entry)
        if global_untracked_out is not None:
            global_untracked_out.append({
                "pname": p.get("name", short_id),
                "debank_id": short_id,
                "usd": usd,
                "account": account,
                "account_label": account_label,
                "chain_id": chain_id,
                "chain_name": chain_name,
            })

    if covered_protos:
        lines += [
            "#### Protocol positions",
            "",
            "_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._",
            "",
            "| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |",
            "|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|",
        ]
        for p in covered_protos:
            short_id = p.get("_short_id", "")
            display_id = DEBANK_ID_DISPLAY.get(short_id, short_id)
            pname = p.get("name", short_id)
            all_items = [i for i in p.get("portfolio_item_list", [])
                         if abs(i.get("stats", {}).get("net_usd_value", 0)) >= 0.01]

            items = []
            for item in all_items:
                ctrl = (item.get("pool") or {}).get("controller", "").lower()
                if ctrl and ctrl in disabled_pools:
                    item_usd = item.get("stats", {}).get("net_usd_value", 0)
                    untracked_protos.append((pname, short_id, item_usd, build_item_tokens(item)))
                    if global_untracked_out is not None:
                        global_untracked_out.append({
                            "pname": pname,
                            "debank_id": short_id,
                            "usd": item_usd,
                            "account": account,
                            "account_label": account_label,
                            "chain_id": chain_id,
                            "chain_name": chain_name,
                        })
                else:
                    items.append(item)

            if not items:
                continue

            # For protocols that split one logical position across multiple items (e.g.
            # Compound V3 emits a "Lending" item for rewards and a "Yield" item for supply
            # on the same Comet market), merge items sharing the same pool.controller so
            # all legs are matched together against the corresponding NAV adapter.
            if short_id in CONTROLLER_MERGE_DEBANK_IDS:
                items = merge_items_by_controller(items)

            total = sum(i.get("stats", {}).get("net_usd_value", 0) for i in items)
            has_adapters = bool(nav_adapters_by_debank.get(short_id))
            pf_syms = debank_to_pf_symbols.get(short_id, set())
            pf_pool: list[tuple[int, dict]] = []
            if not has_adapters and pf_syms:
                for sym_l in pf_syms:
                    entry = nav_pf_by_symbol.get(sym_l)
                    if entry and entry[0] not in matched_nav:
                        pf_pool.append(entry)

            # Pass 1: collect matches and coverage gaps (side effects on matched_nav / leg_matches_out)
            proto_leg_start = len(leg_matches_out) if leg_matches_out is not None else 0
            pf_nav_total: float = 0.0
            item_data: list[tuple] = []
            for item in items:
                item_usd = item.get("stats", {}).get("net_usd_value", 0)
                item_label = build_item_label(item)
                item_tokens = build_item_tokens(item)

                if has_adapters:
                    nav_matches = _match_nav_for_item(item, short_id)
                elif pf_pool:
                    best_i = min(
                        range(len(pf_pool)),
                        key=lambda i: abs(_nav_usd(pf_pool[i][1]) - item_usd),
                    )
                    idx, pos = pf_pool.pop(best_i)
                    matched_nav.add(idx)
                    sym = pos.get("symbol", "?")
                    amt = _nav_amount_float(pos)
                    usd_val = _nav_usd(pos)
                    pf_nav_total += usd_val
                    nav_matches = [("price feed", f"{sym} {fmt_amt(amt)}", fmt_usd(usd_val))]
                else:
                    nav_matches = []

                # Coverage gap detection (Section 4.2)
                if not nav_matches and abs(item_usd) >= 1.0:
                    detail = item.get("detail", {})
                    all_item_toks = (
                        detail.get("supply_token_list", [])
                        + detail.get("borrow_token_list", [])
                        + detail.get("reward_token_list", [])
                    )
                    nonzero_toks = [t for t in all_item_toks if t.get("amount", 0) > 0]
                    unregistered = [
                        t.get("symbol", "?") for t in nonzero_toks
                        if (t.get("id") or "").lower() not in (reg_addrs | agg_addrs)
                    ]
                    # All tokens unpriced (registered but no feed, or fully unknown) →
                    # "Untracked by design" rather than a coverage gap.
                    unpriced = [
                        t.get("symbol", "?") for t in nonzero_toks
                        if (t.get("id") or "").lower() not in (priced_addrs | agg_addrs)
                    ]
                    if nonzero_toks and len(unpriced) == len(nonzero_toks):
                        untracked_protos.append((pname, short_id, item_usd, item_tokens))
                        if global_untracked_out is not None:
                            global_untracked_out.append({
                                "pname": pname,
                                "debank_id": short_id,
                                "usd": item_usd,
                                "account": account,
                                "account_label": account_label,
                                "chain_id": chain_id,
                                "chain_name": chain_name,
                            })
                        continue
                    if coverage_gaps_out is not None:
                        # Are the item's underlying tokens themselves NAV-priced assets
                        # (registered with a feed, or aggregated by an adapter)? If so, NAV
                        # already prices them as wallet ERC-20s, so the value IS in the NAV
                        # total whenever the account holds them in-wallet — the per-row
                        # pairing just fails because there is no protocol adapter. It is only
                        # a true coverage gap when those tokens sit locked inside the
                        # protocol's own contract (e.g. a withdrawal queue or savings vault),
                        # where the wallet sweep can't see them. Don't conflate the two.
                        priced_syms = []
                        for t in nonzero_toks:
                            tid = (t.get("id") or "").lower()
                            # native tokens arrive as the chain id (e.g. "eth"); map to the
                            # ERC-7528 sentinel before checking the priced set, as elsewhere.
                            lookup = NATIVE_SENTINEL if tid == dbank_chain.lower() else tid
                            if lookup in priced_addrs or lookup in agg_addrs:
                                priced_syms.append(t.get("symbol", "?"))
                        if not has_adapters and not pf_pool:
                            if nonzero_toks and len(priced_syms) == len(nonzero_toks):
                                uniq = ", ".join(dict.fromkeys(priced_syms))
                                hint = (
                                    f"No `{short_id}` protocol adapter, but {uniq} is/are NAV-priced: "
                                    f"the value is already in the NAV total when held in-wallet "
                                    f"(see this account's wallet-token rows) — a true gap only if locked "
                                    f"in the protocol contract (withdrawal queue / savings vault)"
                                )
                            else:
                                hint = f"No NAV adapter/feed registered for `{short_id}` on chain {chain_id}"
                        elif unregistered:
                            hint = f"Token(s) not in NAV registry: {', '.join(unregistered[:4])}"
                        else:
                            hint = "Adapter registered but no matching position (zero balance or position identity mismatch)"
                        coverage_gaps_out.append({
                            "account": account,
                            "account_label": account_label,
                            "chain_id": chain_id,
                            "chain_name": chain_name,
                            "debank_id": short_id,
                            "protocol_name": pname,
                            "item_label": item_label,
                            "item_usd": item_usd,
                            "item_tokens": item_tokens,
                            "hint": hint,
                        })

                item_data.append((item_usd, item_label, item_tokens, nav_matches))

            # Compute NAV Σ USD: adapter matches from leg_matches_out + price-feed matches tracked above
            if leg_matches_out is not None:
                adapter_nav_total = sum(lm.nav_usd or 0 for lm in leg_matches_out[proto_leg_start:])
            else:
                adapter_nav_total = 0.0
            nav_total_float = adapter_nav_total + pf_nav_total
            nav_total_str = fmt_usd(nav_total_float) if nav_total_float > 0 else "—"

            # Pass 2: render rows
            proto_cell = f"{pname}<br>`{display_id}`"
            first_row = True
            for item_usd, item_label, item_tokens, nav_matches in item_data:
                nav_market, nav_pos, nav_usd_s = nav_matches[0] if nav_matches else ("—", "—", "—")
                if first_row:
                    lines.append(
                        f"| {proto_cell} | │ | {fmt_usd(total)} | {item_label} | {item_tokens} | {fmt_usd(item_usd)} "
                        f"| │ | {nav_total_str} | {nav_market} | {nav_pos} | {nav_usd_s} |"
                    )
                    first_row = False
                else:
                    lines.append(
                        f"| | │ | | {item_label} | {item_tokens} | {fmt_usd(item_usd)} "
                        f"| │ | | {nav_market} | {nav_pos} | {nav_usd_s} |"
                    )
                for nav_market, nav_pos, nav_usd_s in nav_matches[1:]:
                    lines.append(
                        f"| | │ | | | | | │ | | {nav_market} | {nav_pos} | {nav_usd_s} |"
                    )

            if first_row and not item_data:
                # All items for this protocol were routed to untracked — skip the stub row.
                continue
            if first_row:
                if not has_adapters and pf_pool:
                    for j, (p_idx, p_pos) in enumerate(pf_pool):
                        matched_nav.add(p_idx)
                        p_sym = p_pos.get("symbol", "?")
                        p_amt = _nav_amount_float(p_pos)
                        p_usd = _nav_usd(p_pos)
                        pf_nav_total += p_usd
                        if j == 0:
                            lines.append(
                                f"| {proto_cell} | │ | {fmt_usd(total)} | — | — | — "
                                f"| │ | {fmt_usd(p_usd)} | price feed | {p_sym} {fmt_amt(p_amt)} | {fmt_usd(p_usd)} |"
                            )
                        else:
                            lines.append(
                                f"| | │ | | | | "
                                f"| │ | | price feed | {p_sym} {fmt_amt(p_amt)} | {fmt_usd(p_usd)} |"
                            )
                else:
                    lines.append(
                        f"| {proto_cell} | │ | {fmt_usd(total)} | — | — | — | │ | — | — | — | — |"
                    )
        lines.append("")

    # ── Wallet tokens table ───────────────────────────────────────────────────────
    significant_wallet = [
        t for t in wallet_tokens
        if t.get("amount", 0) * t.get("price", 0) >= 0.50
    ]

    covered_wallet: list[dict] = []
    for t in significant_wallet:
        tid = (t.get("id") or "").lower()
        is_native = tid == dbank_chain.lower()
        lookup = NATIVE_SENTINEL if is_native else tid
        if lookup in all_covered:
            covered_wallet.append(t)
        else:
            sym = t.get("symbol", "?")
            usd = t.get("amount", 0) * t.get("price", 0)
            untracked_wallet.append((sym, usd, tid))

    if covered_wallet:
        lines += [
            "#### Wallet tokens",
            "",
            "_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultAdapter` and registered Custom price feeds._",
            "",
            "| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |",
            "|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|",
        ]
        for t in covered_wallet:
            tid = (t.get("id") or "").lower()
            sym = t.get("symbol", "?")
            amt = t.get("amount", 0)
            price = t.get("price", 0)
            tok_usd = amt * price
            is_native = tid == dbank_chain.lower()
            lookup = NATIVE_SENTINEL if is_native else tid

            nav_amt_s, nav_price_s, nav_usd_s = "—", "—", "—"

            if lookup in agg_addrs:
                adapter_label = next(iter(WALLET_AGGREGATING_ADAPTERS.keys()), "aggregating adapter")
                lines.append(
                    f"| {sym} | `{tid}` "
                    f"| │ | {fmt_amt(amt)} | {fmt_usd(price)} | {fmt_usd(tok_usd)} "
                    f"| │ | ↑ aggregated (see protocol row) | — | — |"
                )
                continue

            entry = nav_pf_by_addr.get(lookup)
            if entry:
                idx, pos = entry
                if idx not in matched_nav:
                    matched_nav.add(idx)
                    nav_amt_val = _nav_amount_float(pos)
                    nav_usd_val = _nav_usd(pos)
                    nav_price_val = _nav_unit_price(pos)
                    nav_amt_s = fmt_amt(nav_amt_val)
                    nav_price_s = fmt_usd(nav_price_val) if nav_price_val is not None else "—"
                    nav_usd_s = fmt_usd(nav_usd_val)

            lines.append(
                f"| {sym} | `{tid}` "
                f"| │ | {fmt_amt(amt)} | {fmt_usd(price)} | {fmt_usd(tok_usd)} "
                f"| │ | {nav_amt_s} | {nav_price_s} | {nav_usd_s} |"
            )
        lines.append("")

    # ── Untracked-by-design footer ────────────────────────────────────────────────
    if untracked_protos or untracked_wallet:
        lines += [
            "#### Untracked by design",
            "",
            "_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._",
            "",
            "| Source | Type | $ value | Detail |",
            "|---|---|---:|---|",
        ]
        for pname, sid, usd, detail in sorted(untracked_protos, key=lambda x: -abs(x[2])):
            display_sid = DEBANK_ID_DISPLAY.get(sid, sid)
            lines.append(f"| {pname} (`{display_sid}`) | protocol | {fmt_usd(usd)} | {detail} |")
        for sym, usd, addr in sorted(untracked_wallet, key=lambda x: -abs(x[1])):
            lines.append(f"| {sym} | wallet token | {fmt_usd(usd)} | `{addr}` |")
        lines.append("")

    # ── Silent wallet absorption ──────────────────────────────────────────────────
    for t in wallet_tokens:
        if t.get("amount", 0) * t.get("price", 0) >= 0.50:
            continue
        tid = (t.get("id") or "").lower()
        is_native = tid == dbank_chain.lower()
        lookup = NATIVE_SENTINEL if is_native else tid
        entry = nav_pf_by_addr.get(lookup)
        if entry:
            idx, _ = entry
            matched_nav.add(idx)

    # ── Unmatched NAV positions ───────────────────────────────────────────────────
    unmatched = [
        (idx, pos) for idx, pos in enumerate(nav_positions)
        if idx not in matched_nav
        and abs(int(pos.get("valueUsd8dp", 0))) / 1e8 >= 0.01
    ]
    if unmatched:
        lines += [
            "#### NAV positions with no DeBank counterpart row",
            "",
            "_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._",
            "",
            "| NAV source | Detail | Asset | NAV amount | NAV $ |",
            "|---|---|---|---:|---:|",
        ]
        for _, pos in unmatched:
            sym = pos.get("symbol", "?")
            amount = _nav_amount_float(pos)
            usd = _nav_usd(pos)
            is_debt = pos.get("isDebt", False)
            sign = "−" if is_debt else ""
            proto = _nav_protocol(pos)
            det = pos.get("positionDetail", {})
            det_product = det.get("product", "") if isinstance(det, dict) else str(det)
            det_type = det.get("type", "") if isinstance(det, dict) else ""
            nav_type_s = "price feed" if proto == "wallet" else "adapter"
            nav_detail_parts = [p for p in [proto, det_product, det_type] if p]
            nav_detail_s = " / ".join(nav_detail_parts) if nav_detail_parts else proto
            lines.append(
                f"| {nav_type_s} | {nav_detail_s} | {sym} | {fmt_amt(amount)} "
                f"| {sign}{fmt_usd(abs(usd))} |"
            )
            # Collect as nav_only LegMatch for Section 3
            if leg_matches_out is not None and abs(usd) >= 0.01:
                leg_matches_out.append(LegMatch(
                    account=account, chain_id=chain_id, account_label=account_label,
                    protocol=proto,
                    debank_id="",
                    position_id=pos.get("positionId", ""),
                    position_detail=pos.get("positionDetail", {}),
                    leg_kind=_leg_kind(pos),
                    symbol=pos.get("symbol", "?"),
                    is_debt=is_debt,
                    nav_amount=amount,
                    nav_unit_price_usd=_nav_unit_price(pos),
                    nav_usd=usd,
                    debank_amount=None,
                    debank_unit_price_usd=None,
                    debank_usd=None,
                    match_stage="nav_only",
                    item_label="",
                ))
        lines.append("")

    return lines


# ── Section 3: Per-adapter granular detail ─────────────────────────────────────

def render_per_adapter_detail_section(
    all_leg_matches: list[LegMatch],
    chains_cfg: dict,
) -> list[str]:
    """Render one sub-section per (adapter instance × chain), each with one table
    per account showing per-leg amount / unit-price / USD drift."""
    lines = [
        "---",
        "",
        "## Section 3 — Per-Adapter Granular Detail",
        "",
        "_One table per adapter instance × account. **Amount drift** (Δ amt %) signals a balance-adapter issue. "
        "**Price drift** (Δ price %) signals a price-feed issue. If both are small but USD drift is large, check "
        "decimal/precision handling in the price computation._",
        "",
        "_Severity: **OK** ≤1% · **WARN** 1–5% · **FAIL** >5%. Rows sorted by descending NAV USD._",
        "_`nav_only` rows (no DeBank match) are listed in a separate subsection._",
        "",
    ]

    # Filter to adapter positions only (exclude wallet/price-feed and nav_only for main tables)
    adapter_matches = [
        lm for lm in all_leg_matches
        if lm.protocol != "wallet"
        and lm.match_stage not in ("nav_only", "pf")
    ]
    nav_only_matches = [
        lm for lm in all_leg_matches
        if lm.match_stage == "nav_only"
        and lm.protocol != "wallet"
    ]

    if not adapter_matches and not nav_only_matches:
        lines += ["_No adapter positions matched._", ""]
        return lines

    # Group by (chain_id, position_id, protocol)
    from collections import defaultdict
    by_adapter: dict[tuple, list[LegMatch]] = defaultdict(list)
    for lm in adapter_matches:
        key = (lm.chain_id, lm.position_id, lm.protocol)
        by_adapter[key].append(lm)

    # Sort: by chain_id ascending, then by total absolute NAV USD descending
    def _adapter_sort(kv: tuple) -> tuple:
        (cid, _pos_id, _proto), matches = kv
        total = sum(abs(lm.nav_usd or 0) for lm in matches)
        return (cid, -total)

    for (cid, pos_id, protocol), matches in sorted(by_adapter.items(), key=_adapter_sort):
        chain_name = chains_cfg.get(cid, {}).get("name", f"chain {cid}")
        pos_id_short = f"{pos_id[:12]}…" if len(pos_id) > 14 else pos_id
        lines += [
            f"### {protocol} — {chain_name.title()} (chain {cid}) — `{pos_id_short}`",
            "",
        ]

        # Sub-group by account
        by_account: dict[str, list[LegMatch]] = defaultdict(list)
        for lm in matches:
            by_account[lm.account].append(lm)

        for addr, acct_matches in sorted(by_account.items()):
            lbl = acct_matches[0].account_label
            addr_short = f"{addr[:8]}…{addr[-6:]}"
            lines += [
                f"#### {lbl} (`{addr_short}`)",
                "",
                "| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |",
                "|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|",
            ]
            for lm in sorted(acct_matches, key=lambda x: -(abs(x.nav_usd or 0))):
                side = "−" if lm.is_debt else "+"
                nav_amt_s = fmt_amt(lm.nav_amount) if lm.nav_amount is not None else "—"
                db_amt_s = fmt_amt(lm.debank_amount) if lm.debank_amount is not None else "—"
                nav_price_s = fmt_usd(lm.nav_unit_price_usd) if lm.nav_unit_price_usd is not None else "—"
                db_price_s = fmt_usd(lm.debank_unit_price_usd) if lm.debank_unit_price_usd is not None else "—"
                nav_usd_s = fmt_usd(lm.nav_usd) if lm.nav_usd is not None else "—"
                db_usd_s = fmt_usd(lm.debank_usd) if lm.debank_usd is not None else "—"
                amt_d = _drift_pct(lm.nav_amount, lm.debank_amount)
                price_d = _drift_pct(lm.nav_unit_price_usd, lm.debank_unit_price_usd)
                usd_d = _drift_pct(lm.nav_usd, lm.debank_usd)
                leg_label = f"{lm.symbol} ({lm.leg_kind})"
                lines.append(
                    f"| {leg_label} | {side} "
                    f"| {nav_amt_s} | {db_amt_s} | {fmt_drift_cell(amt_d)} "
                    f"| {nav_price_s} | {db_price_s} | {fmt_drift_cell(price_d)} "
                    f"| {nav_usd_s} | {db_usd_s} | {fmt_drift_cell(usd_d)} |"
                )
            lines.append("")

    # Nav-only appendix
    if nav_only_matches:
        lines += [
            "### NAV-only positions (no DeBank counterpart matched)",
            "",
            "_These adapter positions are counted in the headline NAV but have no DeBank row. See Section 2 inline tables for rationale._",
            "",
            "| Chain | Account | Protocol | Leg | NAV amount | NAV unit $ | NAV USD |",
            "|---|---|---|---|---:|---:|---:|",
        ]
        for lm in sorted(nav_only_matches, key=lambda x: -(abs(x.nav_usd or 0))):
            chain_name = chains_cfg.get(lm.chain_id, {}).get("name", f"chain {lm.chain_id}")
            addr_short = f"{lm.account[:8]}…{lm.account[-6:]}"
            nav_amt_s = fmt_amt(lm.nav_amount) if lm.nav_amount is not None else "—"
            nav_price_s = fmt_usd(lm.nav_unit_price_usd) if lm.nav_unit_price_usd is not None else "—"
            nav_usd_s = fmt_usd(lm.nav_usd) if lm.nav_usd is not None else "—"
            leg_label = f"{lm.symbol} ({lm.leg_kind})"
            lines.append(
                f"| {chain_name} ({lm.chain_id}) | {lm.account_label} (`{addr_short}`) "
                f"| {lm.protocol} | {leg_label} | {nav_amt_s} | {nav_price_s} | {nav_usd_s} |"
            )
        lines.append("")

    return lines


# ── Section 4: Coverage gaps ──────────────────────────────────────────────────

def render_coverage_gap_section(
    all_coverage_gaps: list[dict],
    all_global_untracked: list[dict],
) -> list[str]:
    """Render coverage-gap diagnostics: unsupported protocols (4.1) and
    supported protocol items with no NAV match (4.2)."""
    lines = [
        "---",
        "",
        "## Section 4 — Coverage Gaps",
        "",
        "_Use this section to identify missing adapter registrations, unregistered tokens, or missing price feeds._",
        "",
    ]

    # 4.1 — Untracked protocols
    lines += [
        "### 4.1 — DeBank protocols with value not in `supportedDeBankProtocols`",
        "",
        "_These show non-zero DeBank balance but are absent from the per-chain allowlist in `accounts.json`. "
        "If an NAV adapter exists for the protocol, consider adding it to `supportedDeBankProtocols` and "
        "registering the adapter on that chain._",
        "",
    ]
    # Deduplicate by (chain_id, debank_id), keeping the highest-value entry
    dedup: dict[tuple, dict] = {}
    for e in all_global_untracked:
        key = (e["chain_id"], e["debank_id"])
        if key not in dedup or abs(e["usd"]) > abs(dedup[key]["usd"]):
            dedup[key] = e
    # Also collect per-account rows sorted by USD
    sorted_untracked = sorted(all_global_untracked, key=lambda x: -abs(x["usd"]))
    if sorted_untracked:
        lines += [
            "| Chain | Account | Protocol | DeBank ID | Value | NAV adapter? |",
            "|---|---|---|---|---:|---|",
        ]
        for e in sorted_untracked:
            did = e["debank_id"]
            nav_protos = _DEBANK_ID_TO_NAV_PROTOCOLS.get(did, [])
            adapter_s = f"Yes (`{'`, `'.join(nav_protos)}`)" if nav_protos else "No"
            display_did = DEBANK_ID_DISPLAY.get(did, did)
            chain_lbl = f"{e['chain_name'].title()} ({e['chain_id']})"
            lines.append(
                f"| {chain_lbl} | {e['account_label']} "
                f"| {e['pname']} | `{display_did}` "
                f"| {fmt_usd(e['usd'])} | {adapter_s} |"
            )
    else:
        lines.append("_None — all DeBank protocols with value are in the allowlist._")
    lines.append("")

    # 4.2 — Supported protocols with no NAV match
    lines += [
        "### 4.2 — Supported protocol items with no NAV match",
        "",
        "_The protocol IS in `supportedDeBankProtocols` but no NAV position matched the item. "
        "Possible causes: adapter not deployed on this chain, token not in NAV registry, price feed missing, "
        "or account has zero balance in this market._",
        "",
    ]
    if all_coverage_gaps:
        lines += [
            "| Chain | Account | Protocol | DeBank ID | Item | Value | Hint |",
            "|---|---|---|---|---|---:|---|",
        ]
        for g in sorted(all_coverage_gaps, key=lambda x: -abs(x["item_usd"])):
            did = g["debank_id"]
            display_did = DEBANK_ID_DISPLAY.get(did, did)
            chain_lbl = f"{g['chain_name'].title()} ({g['chain_id']})"
            lines.append(
                f"| {chain_lbl} | {g['account_label']} "
                f"| {g['protocol_name']} | `{display_did}` "
                f"| {g['item_label']} | {fmt_usd(g['item_usd'])} "
                f"| {g['hint']} |"
            )
    else:
        lines.append("_None — all supported protocol items matched a NAV position._")
    lines.append("")

    return lines


# ── main ──────────────────────────────────────────────────────────────────────

def main(refresh_debank: bool = False, from_cache: bool = False) -> None:
    with open(ACCOUNTS_JSON) as f:
        data = json.load(f)

    chains_cfg = data["chains"]
    accounts = data["accounts"]
    tolerance = data["tolerance"]

    # Build registered-token address sets: chain_id -> {lowercase_address}.
    # Source: per-chain nav-config/assets-and-price-feeds/<chainId>.json (keyed by symbol →
    # {address, priceFeeds:[{type,address,heartbeat}]}). Replaces the old single
    # script/config/assets.json (.tokens.<chainId>), removed in the #70 config split.
    registered: dict[str, set[str]] = {}
    # priced: subset of registered that actually have a working price feed (non-empty priceFeeds).
    # Used to detect items whose tokens are known but unpriced (→ untracked, not a coverage gap).
    priced: dict[str, set[str]] = {}
    for cid in chains_cfg:
        assets_path = NAV_ASSETS_PATTERN.format(chain_id=cid)
        if not os.path.exists(assets_path):
            registered[cid] = set()
            priced[cid] = set()
            continue
        with open(assets_path) as f:
            tokens = json.load(f)
        # Skip `$`-prefixed metadata keys (e.g. `$comment`/`$schema`), matching
        # ConfigReader.getAssetSymbols — they are not assets.
        assets = {k: v for k, v in tokens.items() if not k.startswith("$")}
        registered[cid] = {v["address"].lower() for v in assets.values()}
        priced[cid] = {
            v["address"].lower() for v in assets.values() if v.get("priceFeeds")
        }

    # Load NAV position detail files
    nav_positions_by_chain: dict[str, dict[str, list]] = {}
    for cid in chains_cfg:
        nav_positions_by_chain[cid] = load_nav_positions(cid)
        if nav_positions_by_chain[cid]:
            print(f"  [nav] chain {cid}: loaded {len(nav_positions_by_chain[cid])} account(s)", file=sys.stderr)
        else:
            print(f"  [nav] chain {cid}: no file (run refresh script to generate)", file=sys.stderr)

    # Cross-section accumulators (populated by render_unified_table calls)
    all_leg_matches: list[LegMatch] = []
    all_coverage_gaps: list[dict] = []
    all_global_untracked: list[dict] = []

    # DeBank total accumulator (for write-back to accounts.json)
    debank_totals: dict[int, dict[str, float]] = {}

    lines = [
        "# NAV vs DeBank — Detailed Comparison Report",
        "",
        f"Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}  ",
        f"Tolerance: {tolerance * 100:.0f}%",
        "",
    ]
    if from_cache:
        lines.append(
            "DeBank anchor: read from `test/integration/debank-cache/` (no live API call).  "
        )
    elif refresh_debank:
        lines.append(
            "DeBank anchor: freshly captured against current chain state "
            "(`--refresh-debank`).  "
        )
    else:
        lines.append(
            "DeBank anchor: from `accounts.json.expected.<cid>.debankUsd` "
            "(captured at forge-snapshot time). Re-run with `--refresh-debank` "
            "to recapture against current chain state.  "
        )
    lines += [
        "",
        "## Fork blocks",
        "",
        "| Chain | Block |",
        "|---|---|",
    ]
    for cid, ccfg in chains_cfg.items():
        lines.append(f"| {ccfg['name']} ({cid}) | {ccfg['forkBlock']} |")
    lines.append("")

    SUMMARY_SENTINEL = "<<DRIFT_SUMMARY_TABLE>>"
    lines.append(SUMMARY_SENTINEL)
    lines.append("")
    summary_rows: list[dict] = []

    for acc_idx, acc in enumerate(accounts):
        addr = acc["address"]
        label = acc["label"]
        enabled = [str(c) for c in acc.get("enabledChains", [])]
        # Skip placeholder accounts (no address yet)
        if not addr or addr.startswith("<"):
            continue
        debank_totals[acc_idx] = {}

        lines += ["---", "", f"## {label}", "", f"**Address:** `{addr}`", ""]

        # Load or fetch all_complex_protocol_list (once per account)
        if from_cache:
            proto_resp = load_protocols_from_cache(addr) or []
            if not proto_resp:
                print(f"  [{label}] no protocol cache — run with --refresh-debank first", file=sys.stderr)
        else:
            print(f"[{label}] fetching protocol list...", file=sys.stderr)
            proto_resp = debank_get("/v1/user/all_complex_protocol_list", f"id={addr}")
            if not from_cache:
                save_protocols_to_cache(addr, proto_resp)

        protos_by_chain: dict[str, list] = {}
        for p in proto_resp:
            c = p.get("chain", "")
            protos_by_chain.setdefault(c, []).append(p)

        for cid in enabled:
            ccfg = chains_cfg[cid]
            dbank_chain = ccfg["debankChainId"]
            chain_name = ccfg["name"]
            supported_ids = set(ccfg.get("supportedDeBankProtocols", []))
            exp = acc.get("expected", {}).get(cid, {})
            nav_raw = exp.get("navUsd8dp") or "0"
            dbank_usd_s = exp.get("debankUsd", "")
            nav_usd = int(nav_raw) / 1e8

            raw_protos = protos_by_chain.get(dbank_chain, [])
            for p in raw_protos:
                p["_short_id"] = normalise_pid(p.get("id", ""), dbank_chain)
            chain_protos = sorted(raw_protos, key=proto_net_usd, reverse=True)

            anchor_zero = (not dbank_usd_s) or (not dbank_usd_s.strip()) or float(dbank_usd_s or 0) == 0
            if nav_usd == 0 and not chain_protos and anchor_zero:
                continue

            # Load or fetch token list (per account × chain)
            if from_cache:
                tok_resp = load_tokens_from_cache(addr, cid) or []
                if not tok_resp and not anchor_zero:
                    print(f"  [{label}] no token cache for chain {cid}", file=sys.stderr)
            else:
                print(f"  [{label}] fetching token list chain {cid}...", file=sys.stderr)
                tok_resp = debank_get("/v1/user/token_list",
                                      f"id={addr}&chain_id={dbank_chain}&is_all=false")
                save_tokens_to_cache(addr, cid, tok_resp)

            reg_addrs = registered.get(cid, set())
            priced_addrs = priced.get(cid, set())
            agg_addrs = adapter_aggregated_addrs(cid)
            all_covered = reg_addrs | agg_addrs
            disabled_pools = disabled_lp_pool_addrs(cid)

            # Compute DeBank filtered total for write-back
            filtered_proto_sum = 0.0
            for p in chain_protos:
                if p["_short_id"] not in supported_ids:
                    continue
                for item in p.get("portfolio_item_list", []):
                    ctrl = (item.get("pool") or {}).get("controller", "").lower()
                    if ctrl and ctrl in disabled_pools:
                        continue
                    filtered_proto_sum += item.get("stats", {}).get("net_usd_value", 0)
            filtered_token_sum = 0.0
            for t in tok_resp:
                tid = (t.get("id") or "").lower()
                amt = t.get("amount", 0)
                price = t.get("price", 0)
                usd = amt * price
                lookup = NATIVE_SENTINEL if tid == dbank_chain else tid
                if lookup in all_covered:
                    filtered_token_sum += usd
            fresh_filtered = filtered_proto_sum + filtered_token_sum
            debank_totals[acc_idx][cid] = fresh_filtered

            if refresh_debank:
                anchor_usd: float | None = fresh_filtered
                has_anchor = True
            elif dbank_usd_s and dbank_usd_s.strip():
                anchor_usd = float(dbank_usd_s)
                has_anchor = True
            else:
                anchor_usd = None
                has_anchor = False

            lines += [f"### {chain_name.title()} (chain {cid})", ""]

            if has_anchor and anchor_usd and anchor_usd > 0:
                drift = (nav_usd - anchor_usd) / anchor_usd
                drift_s = f"{drift * 100:+.2f}%"
                flag = "✅" if abs(drift) <= tolerance else "⚠️"
                lines.append(
                    f"**NAV: {fmt_usd(nav_usd)} | DeBank filtered: {fmt_usd(anchor_usd)} | Drift: {drift_s} {flag}**"
                )
                summary_rows.append({
                    "label": label, "chain": chain_name, "cid": cid,
                    "nav": nav_usd, "anchor": anchor_usd,
                    "drift_s": drift_s, "flag": flag,
                })
            elif has_anchor:
                lines.append(
                    f"**NAV: {fmt_usd(nav_usd)} | DeBank filtered: {fmt_usd(anchor_usd)} | Drift: — **"
                )
                summary_rows.append({
                    "label": label, "chain": chain_name, "cid": cid,
                    "nav": nav_usd, "anchor": anchor_usd,
                    "drift_s": "—", "flag": "",
                })
            else:
                lines.append(f"**NAV: {fmt_usd(nav_usd)} | DeBank filtered: — (not available)**")
                summary_rows.append({
                    "label": label, "chain": chain_name, "cid": cid,
                    "nav": nav_usd, "anchor": None,
                    "drift_s": "—", "flag": "",
                })
            lines.append("")

            nav_pos_map = nav_positions_by_chain.get(cid, {})
            account_positions = nav_pos_map.get(addr.lower(), None)

            if account_positions is None:
                lines += ["_NAV position detail not available — run refresh script._", ""]
                if chain_protos:
                    lines += [
                        "#### DeBank protocol positions",
                        "",
                        "| Protocol | DeBank ID | Covered | DeBank USD | DeBank position detail |",
                        "|---|---|:---:|---:|---|",
                    ]
                    for p in chain_protos:
                        short_id = p["_short_id"]
                        pname = p.get("name", short_id)
                        covered = "✅" if short_id in supported_ids else "❌"
                        lines.append(
                            f"| {pname} | `{short_id}` | {covered} | {fmt_usd(proto_net_usd(p))} "
                            f"| {build_debank_proto_detail(p)} |"
                        )
                    lines.append("")
            else:
                lines += render_unified_table(
                    account_positions,
                    chain_protos,
                    [t for t in tok_resp if (t.get("amount", 0) * t.get("price", 0)) >= 0.50],
                    supported_ids,
                    reg_addrs,
                    priced_addrs,
                    agg_addrs,
                    dbank_chain,
                    disabled_pools,
                    # Extended:
                    leg_matches_out=all_leg_matches,
                    coverage_gaps_out=all_coverage_gaps,
                    global_untracked_out=all_global_untracked,
                    account=addr.lower(),
                    chain_id=cid,
                    chain_name=chain_name,
                    account_label=label,
                )

    # Drift summary
    summary_block: list[str] = ["## Drift summary", ""]
    countable = [r for r in summary_rows if r["anchor"] not in (None, 0)]
    in_tol = sum(1 for r in countable if r["flag"] == "✅")
    over = sum(1 for r in countable if r["flag"] == "⚠️")
    if countable:
        summary_block.append(
            f"**{in_tol} of {len(countable)} account-chain pairs within {int(tolerance * 100)}% tolerance.**"
            + (f" ⚠ {over} over tolerance — see per-account section for breakdown." if over else "")
        )
        summary_block.append("")
    summary_block += [
        "| Account | Chain | │ | NAV | │ | DeBank filtered | Drift |  |",
        "|---|---|:---:|---:|:---:|---:|---:|:---:|",
    ]
    for r in summary_rows:
        anchor_s = fmt_usd(r["anchor"]) if r["anchor"] not in (None, 0) else "—"
        summary_block.append(
            f"| {r['label']} | {r['chain']} | │ | {fmt_usd(r['nav'])} | │ | {anchor_s} | {r['drift_s']} | {r['flag']} |"
        )
    summary_block.append("")

    if SUMMARY_SENTINEL in lines:
        sidx = lines.index(SUMMARY_SENTINEL)
        lines = lines[:sidx] + summary_block + lines[sidx + 1:]

    # Append Section 3 and Section 4
    lines += render_per_adapter_detail_section(all_leg_matches, chains_cfg)
    lines += render_coverage_gap_section(all_coverage_gaps, all_global_untracked)

    # Write DeBank totals back to accounts.json
    for acc_idx, chain_totals in debank_totals.items():
        for cid, total in chain_totals.items():
            exp = accounts[acc_idx].setdefault("expected", {}).setdefault(cid, {})
            if refresh_debank or not exp.get("debankUsd", "").strip():
                exp["debankUsd"] = f"{total:.6f}"
    with open(ACCOUNTS_JSON, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"Updated: {ACCOUNTS_JSON}", file=sys.stderr)

    with open(OUT_FILE, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"Written: {OUT_FILE}", file=sys.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--refresh-debank",
        action="store_true",
        help="Fetch live DeBank data, update cache + accounts.json debankUsd. Requires DEBANK_API_KEY.",
    )
    parser.add_argument(
        "--from-cache",
        action="store_true",
        help="Read DeBank data from test/integration/debank-cache/ only — no API calls, no API key needed.",
    )
    args = parser.parse_args()

    # Cache-first fallback: if no flag given and no API key, try the cache
    if not args.from_cache and not args.refresh_debank and not DEBANK_API_KEY:
        if os.path.isdir(DEBANK_CACHE_DIR) and any(os.scandir(DEBANK_CACHE_DIR)):
            print(
                "DEBANK_API_KEY not set — using cached DeBank data (pass --refresh-debank to recapture).",
                file=sys.stderr,
            )
            args.from_cache = True
        else:
            print(
                "DEBANK_API_KEY not set and no cache found in test/integration/debank-cache/. "
                "Source .env first, or run --refresh-debank after setting the key.",
                file=sys.stderr,
            )
            sys.exit(1)

    if args.refresh_debank and not DEBANK_API_KEY:
        print("DEBANK_API_KEY not set — source .env first", file=sys.stderr)
        sys.exit(1)

    main(refresh_debank=args.refresh_debank, from_cache=args.from_cache)
