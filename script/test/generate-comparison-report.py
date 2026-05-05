#!/usr/bin/env python3
"""
Generate a detailed NAV vs Debank comparison report in Markdown.

For each account × chain: one unified table that pairs each NAV position
with its Debank counterpart, making the NAV-type distinction explicit:
  - "adapter"    : balance adapter (Aave V3, Morpho, …)
  - "price feed" : ERC20 wallet balance priced via a custom feed
                   (sUSDS, sXDAI, rETH, wstETH, …)

The same economic exposure may appear as a Debank *protocol* position while
NAV sees it as a price-feed wallet balance (e.g. sUSDS → Sky protocol;
sXDAI → Gnosis protocol).  The unified table shows both sides on the same row.

NAV position detail is read from test/integration/nav-positions-<chainId>.json,
written by RefreshIntegrationSnapshot during the refresh run.

Usage:
    . ./.env && python3 script/test/generate-comparison-report.py
    . ./.env && python3 script/test/generate-comparison-report.py --refresh-debank

By default writes back debankUsd only to empty slots (preserves forge-time
captures). Pass --refresh-debank to recapture every slot against current chain
state — pairs anchor with regenerated NAV but introduces a small temporal gap
between fork-block-pinned NAV and now-pinned Debank for volatile assets.

Output: comparison-report.md
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

DEBANK_API_KEY = os.environ.get("DEBANK_API_KEY", "")
DEBANK_BASE = "https://pro-openapi.debank.com"
ACCOUNTS_JSON = "test/integration/accounts.json"
ASSETS_JSON = "script/config/assets.json"
CHAINS_CONFIG_DIR = "script/config/chains"
NAV_POSITIONS_PATTERN = "test/integration/nav-positions-{chain_id}.json"
OUT_FILE = "comparison-report.md"
NATIVE_SENTINEL = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

# Adapters that read wallet token balances directly and aggregate them into a
# single protocol-denominated PositionBalance (e.g. Cap reads balanceOf(cUsd)
# and balanceOf(stcUsd), then returns the combined amount in USDC). For these,
# the wallet tokens are NOT registered as standalone priceable assets, but they
# ARE in NAV — so the report should mark them ✅ Covered and include them in
# the filtered Debank total. Map: adapter_key (as it appears under
# chains/<cid>.json.balanceAdapters) → list of constructor param names whose
# values are the wallet token addresses to credit.
WALLET_AGGREGATING_ADAPTERS = {
    "Cap": ["cUsd", "stcUsd"],
}

# Maps NAV adapter `protocol` prefixes to Debank protocol short-IDs.
# Matching is prefix-based: e.g. "Aave V3" matches "Aave V3 Core", "Aave V3 Prime",
# "Aave V3 Safety Module", etc.  "Morpho" matches "Morpho Vault", "Morpho Blue - *".
# Longer prefixes take priority over shorter ones.
NAV_PROTOCOL_TO_DEBANK_IDS: dict[str, list[str]] = {
    "Aave V3": ["aave3"],
    "Aave V2": ["aave2"],
    "Aave Umbrella": ["aave3"],
    "Morpho": ["morphoblue"],
    "Compound v3": ["compound3"],
    "Balancer V3": ["balancer3", "balancer2"],
    "Spark": ["spark"],
    "Curve": ["curve"],
    "Convex": ["convex"],
    "Aura": ["aurafinance"],
    "Merkl": ["merkl"],
    "Fluid": ["fluid"],
    "Cap": ["capapp"],
    "Kelp DAO": ["kelpdao"],
    "Rocket Pool": ["rocketpool"],
    "Lido": ["lido"],
    "Ethena": ["ethena"],
    "ether.fi": ["etherfi"],
    "Stakewise v3": ["stakewise"],
    "Stader": ["stader"],
    "Uniswap V3": ["uniswap3"],
    "Uniswap V2": ["uniswap2"],
    "Sky": ["sky"],
    "Sablier": ["sablier"],
    "Gearbox": ["gearbox"],
    "PancakeSwap V3": ["pancakeswap3"],
    "PancakeSwap V2": ["pancakeswap"],
}

# For price-feed (wallet) positions: maps asset symbol to the Debank protocol IDs
# that represent the same economic exposure.  NAV prices these via a custom feed
# and counts them as wallet balances; Debank categorises them as protocol positions.
#
# This is the ONLY way wallet positions are matched to Debank protocols — the
# old generic supply-list symbol search caused too many false positives (e.g. a
# tiny USDT dust balance matching a $100K Aave position just because USDT is Aave
# collateral).
WALLET_SYMBOL_TO_DEBANK_IDS: dict[str, list[str]] = {
    # Savings / yield-bearing stablecoins
    "sUSDS": ["sky"],
    "sXDAI": ["gnosis"],
    "sDAI": ["gnosis", "spark"],
    # Liquid staking / restaking tokens — NAV uses a price feed, Debank sees the
    # underlying staking protocol.
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
}


def debank_ids_for_nav_protocol(protocol: str) -> list[str]:
    """Return Debank IDs for a NAV protocol string using longest-prefix matching."""
    best_prefix = ""
    best_ids: list[str] = []
    for prefix, ids in NAV_PROTOCOL_TO_DEBANK_IDS.items():
        if protocol.startswith(prefix) and len(prefix) > len(best_prefix):
            best_prefix = prefix
            best_ids = ids
    return best_ids


def adapter_aggregated_addrs(cid: str) -> set[str]:
    """Return lowercase token addresses that wallet-aggregating adapters consume
    on chain `cid`. Reads from script/config/chains/<cid>.json so addresses are
    sourced from the canonical chain config (no duplication)."""
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
    """Load nav-positions-<chainId>.json; returns {} if missing."""
    path = NAV_POSITIONS_PATTERN.format(chain_id=chain_id)
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        data = json.load(f)
    # Keys are checksummed addresses; normalise to lowercase for lookup.
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
    """Return all Debank protocol entries matching any of the given short IDs."""
    return [p for p in chain_protos
            if p.get("_short_id", "") in short_ids]


def find_debank_proto_by_symbol(chain_protos: list, symbol: str) -> tuple[str, float] | None:
    """
    Search all Debank protocol entries for a supply/reward token matching `symbol`.
    Returns (debank_id, net_usd) of the first match, or None.
    """
    for p in chain_protos:
        short_id = p.get("_short_id", "")
        for item in p.get("portfolio_item_list", []):
            detail = item.get("detail", {})
            for tok in detail.get("supply_token_list", []) + detail.get("reward_token_list", []):
                if tok.get("symbol", "").lower() == symbol.lower():
                    return short_id, proto_net_usd(p)
    return None


def build_debank_proto_detail(p: dict) -> str:
    """Build a compact inline description of a Debank protocol entry."""
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


def render_unified_table(
    nav_positions: list,
    chain_protos: list,
    wallet_tokens: list,
    supported_ids: set[str],
    reg_addrs: set[str],
    agg_addrs: set[str],
    dbank_chain: str,
) -> list[str]:
    """
    Render two Debank-first tables (protocol positions + wallet tokens), each
    extended with NAV match columns on the right.

    Protocol table columns:
      Protocol | Debank ID | Covered | Debank USD | Debank detail | NAV type | NAV USD
    Wallet table columns:
      Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD
    """
    if not nav_positions and not chain_protos and not wallet_tokens:
        return ["_No positions on this chain._", ""]

    all_covered = reg_addrs | agg_addrs

    # ── Pre-index NAV positions ─────────────────────────────────────────────────
    # Reverse map: debank_id → symbols NAV tracks as price feeds for that protocol
    debank_to_pf_symbols: dict[str, set[str]] = {}
    for sym, dids in WALLET_SYMBOL_TO_DEBANK_IDS.items():
        for did in dids:
            debank_to_pf_symbols.setdefault(did, set()).add(sym.lower())

    matched_nav: set[int] = set()

    # Adapter positions grouped by debank_id
    nav_adapters_by_debank: dict[str, list[tuple[int, dict]]] = {}
    # Price-feed positions by address and by symbol
    nav_pf_by_addr: dict[str, tuple[int, dict]] = {}
    nav_pf_by_symbol: dict[str, tuple[int, dict]] = {}

    for idx, pos in enumerate(nav_positions):
        if pos.get("protocol") == "wallet":
            addr = pos.get("address", "").lower()
            nav_pf_by_addr.setdefault(addr, (idx, pos))
            sym_l = pos.get("symbol", "").lower()
            nav_pf_by_symbol.setdefault(sym_l, (idx, pos))
        else:
            for did in debank_ids_for_nav_protocol(pos.get("protocol", "")):
                nav_adapters_by_debank.setdefault(did, []).append((idx, pos))

    def _nav_for_proto(short_id: str) -> tuple[str, str, str]:
        """Return (nav_type_label, nav_detail_str, nav_usd_str) for a Debank protocol short_id."""
        # 1. Adapter positions
        adapter_matches = [(idx, p) for idx, p in nav_adapters_by_debank.get(short_id, [])
                           if idx not in matched_nav]
        if adapter_matches:
            total_usd = sum(int(p.get("valueUsd8dp", 0)) / 1e8 for _, p in adapter_matches)
            parts = []
            for _, p in adapter_matches:
                proto = p.get("protocol", "")
                sym = p.get("symbol", "?")
                decimals = int(p.get("decimals", 18))
                amt = int(p.get("amount", 0)) / 10 ** decimals
                usd = int(p.get("valueUsd8dp", 0)) / 1e8
                label = "borrow" if p.get("isDebt") else "supply"
                parts.append(f"{proto}: {label} {sym} {fmt_amt(amt)} → {fmt_usd(usd)}")
            for idx, _ in adapter_matches:
                matched_nav.add(idx)
            return "adapter", "<br>".join(parts), fmt_usd(total_usd)
        # 2. Price-feed positions (LSTs/yield-bearing: stETH→lido, rETH→rocketpool…)
        pf_syms = debank_to_pf_symbols.get(short_id, set())
        pf_matches = []
        for sym_l in pf_syms:
            entry = nav_pf_by_symbol.get(sym_l)
            if entry and entry[0] not in matched_nav:
                pf_matches.append(entry)
        if pf_matches:
            total_usd = sum(int(p.get("valueUsd8dp", 0)) / 1e8 for _, p in pf_matches)
            parts = []
            for _, p in pf_matches:
                sym = p.get("symbol", "?")
                decimals = int(p.get("decimals", 18))
                amt = int(p.get("amount", 0)) / 10 ** decimals
                usd = int(p.get("valueUsd8dp", 0)) / 1e8
                parts.append(f"{sym} {fmt_amt(amt)} → {fmt_usd(usd)}")
            for idx, _ in pf_matches:
                matched_nav.add(idx)
            return "price feed", "<br>".join(parts), fmt_usd(total_usd)
        return "—", "—", "—"

    lines: list[str] = []

    # ── Protocol positions table ──────────────────────────────────────────────────
    if chain_protos:
        lines += [
            "#### Debank protocol positions",
            "",
            "| Protocol | Debank ID | Covered | Debank USD | Debank position detail | NAV type | NAV detail | NAV USD |",
            "|---|---|:---:|---:|---|---|---|---:|",
        ]
        for p in chain_protos:
            short_id = p.get("_short_id", "")
            pname = p.get("name", short_id)
            in_filter = short_id in supported_ids
            covered = "✅" if in_filter else "❌"
            total = proto_net_usd(p)
            detail_col = build_debank_proto_detail(p)
            nav_type_s, nav_detail_s, nav_usd_s = _nav_for_proto(short_id)
            lines.append(
                f"| {pname} | `{short_id}` | {covered} | {fmt_usd(total)} "
                f"| {detail_col} | {nav_type_s} | {nav_detail_s} | {nav_usd_s} |"
            )
        lines.append("")

    # ── Wallet tokens table ───────────────────────────────────────────────────────
    significant_wallet = [
        t for t in wallet_tokens
        if t.get("amount", 0) * t.get("price", 0) >= 0.50
    ]
    if significant_wallet:
        lines += [
            "#### Debank wallet tokens",
            "",
            "| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |",
            "|---|---:|---:|:---:|---:|---|---|---|---:|---:|",
        ]
        for t in significant_wallet:
            tid = (t.get("id") or "").lower()
            sym = t.get("symbol", "?")
            amt = t.get("amount", 0)
            price = t.get("price", 0)
            tok_usd = amt * price
            is_native = tid == dbank_chain.lower()
            lookup = NATIVE_SENTINEL if is_native else tid
            in_covered = lookup in all_covered
            covered = "✅" if in_covered else "❌"

            nav_type_s, nav_detail_s, nav_amt_s, nav_usd_s = "—", "—", "—", "—"
            entry = nav_pf_by_addr.get(lookup)
            if entry:
                idx, pos = entry
                if idx not in matched_nav:
                    matched_nav.add(idx)
                    decimals = int(pos.get("decimals", 18))
                    nav_amt_val = int(pos.get("amount", 0)) / 10 ** decimals
                    nav_usd_val = int(pos.get("valueUsd8dp", 0)) / 1e8
                    nav_detail_s = f"{pos.get('protocol', '')} / {pos.get('positionDetail', '')}"
                    nav_type_s = "price feed"
                    nav_amt_s = fmt_amt(nav_amt_val)
                    nav_usd_s = fmt_usd(nav_usd_val)

            lines.append(
                f"| {sym} | {fmt_amt(amt)} | {fmt_usd(price)} | {covered} "
                f"| {fmt_usd(tok_usd)} | `{tid}` "
                f"| {nav_type_s} | {nav_detail_s} | {nav_amt_s} | {nav_usd_s} |"
            )
        lines.append("")

    # ── Unmatched NAV positions ───────────────────────────────────────────────────
    unmatched = [(idx, pos) for idx, pos in enumerate(nav_positions) if idx not in matched_nav]
    if unmatched:
        lines += [
            "#### NAV positions without Debank counterpart",
            "",
            "| NAV type | NAV detail | Asset | NAV amount | NAV USD |",
            "|---|---|---|---:|---:|",
        ]
        for _, pos in unmatched:
            sym = pos.get("symbol", "?")
            decimals = int(pos.get("decimals", 18))
            amount = int(pos.get("amount", 0)) / 10 ** decimals
            usd = int(pos.get("valueUsd8dp", 0)) / 1e8
            is_debt = pos.get("isDebt", False)
            sign = "−" if is_debt else ""
            proto = pos.get("protocol", "")
            det = pos.get("positionDetail", "")
            nav_type_s = "price feed" if proto == "wallet" else "adapter"
            nav_detail_s = f"{proto} / {det}" if det else proto
            lines.append(
                f"| {nav_type_s} | {nav_detail_s} | {sym} | {fmt_amt(amount)} "
                f"| {sign}{fmt_usd(abs(usd))} |"
            )
        lines.append("")

    return lines


def main(refresh_debank: bool = False) -> None:
    with open(ACCOUNTS_JSON) as f:
        data = json.load(f)
    with open(ASSETS_JSON) as f:
        assets = json.load(f)

    chains_cfg = data["chains"]
    accounts = data["accounts"]
    tolerance = data["tolerance"]

    # Build registered-token address sets: chain_id -> {lowercase_address}
    registered: dict[str, set[str]] = {}
    for cid, tokens in assets.get("tokens", {}).items():
        registered[cid] = {v["address"].lower() for v in tokens.values()}

    # Load NAV position detail files
    nav_positions_by_chain: dict[str, dict[str, list]] = {}
    for cid in chains_cfg:
        nav_positions_by_chain[cid] = load_nav_positions(cid)
        if nav_positions_by_chain[cid]:
            print(f"  [nav] chain {cid}: loaded {len(nav_positions_by_chain[cid])} account(s)", file=sys.stderr)
        else:
            print(f"  [nav] chain {cid}: no file (run refresh script to generate)", file=sys.stderr)

    debank_totals: dict[int, dict[str, float]] = {}

    lines = [
        "# NAV vs Debank — Detailed Comparison Report",
        "",
        f"Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}  ",
        f"Tolerance: {tolerance * 100:.0f}%",
        "",
    ]
    if refresh_debank:
        lines.append(
            "Debank anchor: freshly captured against current chain state "
            "(`--refresh-debank`).  "
        )
    else:
        lines.append(
            "Debank anchor: from `accounts.json.expected.<cid>.debankUsd` "
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

    for acc_idx, acc in enumerate(accounts):
        addr = acc["address"]
        label = acc["label"]
        enabled = [str(c) for c in acc["enabledChains"]]
        debank_totals[acc_idx] = {}

        lines += ["---", "", f"## {label}", "", f"**Address:** `{addr}`", ""]

        print(f"[{label}] fetching protocol list...", file=sys.stderr)
        proto_resp = debank_get("/v1/user/all_complex_protocol_list", f"id={addr}")
        protos_by_chain: dict[str, list] = {}
        for p in proto_resp:
            c = p.get("chain", "")
            protos_by_chain.setdefault(c, []).append(p)

        for cid in enabled:
            ccfg = chains_cfg[cid]
            dbank_chain = ccfg["debankChainId"]
            chain_name = ccfg["name"]
            supported_ids = set(ccfg.get("supportedDebankProtocols", []))
            exp = acc.get("expected", {}).get(cid, {})
            nav_raw = exp.get("navUsd8dp") or "0"
            dbank_usd_s = exp.get("debankUsd", "")
            nav_usd = int(nav_raw) / 1e8

            # Annotate each Debank protocol entry with its normalised short_id
            raw_protos = protos_by_chain.get(dbank_chain, [])
            for p in raw_protos:
                p["_short_id"] = normalise_pid(p.get("id", ""), dbank_chain)
            chain_protos = sorted(raw_protos, key=proto_net_usd, reverse=True)

            # Wallet tokens
            print(f"  [{label}] fetching token list chain {cid}...", file=sys.stderr)
            tok_resp = debank_get("/v1/user/token_list",
                                  f"id={addr}&chain_id={dbank_chain}&is_all=false")
            reg_addrs = registered.get(cid, set())
            agg_addrs = adapter_aggregated_addrs(cid)
            all_covered = reg_addrs | agg_addrs

            # Compute Debank filtered total for write-back:
            # protocol sum (supported IDs) + wallet token sum (registered or aggregated)
            filtered_proto_sum = sum(
                proto_net_usd(p) for p in chain_protos
                if p["_short_id"] in supported_ids
            )
            filtered_token_sum = 0.0
            for t in tok_resp:
                tid = (t.get("id") or "").lower()
                amt = t.get("amount", 0)
                price = t.get("price", 0)
                usd = amt * price
                if usd < 0.50:
                    continue
                lookup = NATIVE_SENTINEL if tid == dbank_chain else tid
                if lookup in all_covered:
                    filtered_token_sum += usd
            fresh_filtered = filtered_proto_sum + filtered_token_sum
            debank_totals[acc_idx][cid] = fresh_filtered

            # Pick anchor for drift header
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
                    f"**NAV: {fmt_usd(nav_usd)} | Debank filtered: {fmt_usd(anchor_usd)} | Drift: {drift_s} {flag}**"
                )
            elif has_anchor:
                lines.append(
                    f"**NAV: {fmt_usd(nav_usd)} | Debank filtered: {fmt_usd(anchor_usd)} | Drift: — **"
                )
            else:
                lines.append(f"**NAV: {fmt_usd(nav_usd)} | Debank filtered: — (not available)**")
            lines.append("")

            # NAV positions for this account × chain
            nav_pos_map = nav_positions_by_chain.get(cid, {})
            account_positions = nav_pos_map.get(addr.lower(), None)

            if account_positions is None:
                lines += ["_NAV position detail not available — run refresh script._", ""]
                # Fall back: show Debank-only tables
                if chain_protos:
                    lines += [
                        "#### Debank protocol positions",
                        "",
                        "| Protocol | Debank ID | Covered | Debank USD | Debank position detail |",
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
                    agg_addrs,
                    dbank_chain,
                )

    # Write Debank totals back to accounts.json.
    # By default only fill empty slots so forge-time captures are preserved.
    # With --refresh-debank, overwrite every slot.
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
        help="Overwrite expected.<cid>.debankUsd in accounts.json with the freshly "
             "captured Debank totals. Default is to fill only empty slots so "
             "forge-time captures are preserved.",
    )
    args = parser.parse_args()
    if not DEBANK_API_KEY:
        print("DEBANK_API_KEY not set — source .env first", file=sys.stderr)
        sys.exit(1)
    main(refresh_debank=args.refresh_debank)
