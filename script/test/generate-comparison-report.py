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

# For price-feed (wallet) positions: maps asset symbol to Debank protocol IDs when
# Debank categorises the same exposure as a protocol rather than a wallet balance.
# Used as a first-pass before the generic symbol-search fallback.
# Examples: sUSDS → Debank "sky", sXDAI/sDAI → Debank "gnosis" or "spark".
WALLET_SYMBOL_TO_DEBANK_IDS: dict[str, list[str]] = {
    "sUSDS": ["sky"],
    "sXDAI": ["gnosis"],
    "sDAI": ["gnosis", "spark"],
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
    nav_positions: list,           # from nav-positions-<chainId>.json
    chain_protos: list,            # Debank protocol list (with _short_id already set)
    wallet_tokens: list,           # Debank token_list (filtered to >= $0.50)
    supported_ids: set[str],
    reg_addrs: set[str],
    agg_addrs: set[str],           # addresses consumed by wallet-aggregating adapters
) -> list[str]:
    """
    Build one unified table per account × chain pairing NAV positions with their
    Debank counterparts.  Returns a list of Markdown lines.
    """
    if not nav_positions and not chain_protos and not wallet_tokens:
        return ["_No positions on this chain._", ""]

    all_covered = reg_addrs | agg_addrs

    lines = [
        "#### Positions",
        "",
        "| NAV type | Protocol / detail | Asset | NAV amount | NAV USD | Debank source | Debank USD |",
        "|---|---|---|---:|---:|---|---:|",
    ]

    matched_debank_protos: set[str] = set()  # _short_id values already matched
    matched_wallet_addrs: set[str] = set()   # lowercase token addresses already matched

    # ── Rows from NAV positions ────────────────────────────────────────────────
    for pos in nav_positions:
        protocol = pos.get("protocol", "")
        detail = pos.get("positionDetail", "")
        symbol = pos.get("symbol", "?")
        decimals = int(pos.get("decimals", 18))
        amount_raw = int(pos.get("amount", 0))
        amount = amount_raw / 10 ** decimals
        value_8dp = int(pos.get("valueUsd8dp", "0"))
        usd = value_8dp / 1e8
        is_debt = pos.get("isDebt", False)
        asset_addr = pos.get("address", "").lower()
        sign = "−" if is_debt else ""

        nav_type = "price feed" if protocol == "wallet" else "adapter"
        nav_proto_col = f"{protocol} / {detail}" if detail else protocol

        # ── Match to Debank ────────────────────────────────────────────────────
        debank_source = "—"
        debank_usd_col = "—"

        if protocol == "wallet":
            # 1. Try exact wallet token match by address
            if asset_addr == NATIVE_SENTINEL:
                wt = None  # native handled below via protocol match
            else:
                wt = next((t for t in wallet_tokens
                           if (t.get("id") or "").lower() == asset_addr), None)

            if wt:
                wt_usd = wt.get("amount", 0) * wt.get("price", 0)
                debank_source = f"wallet ({wt.get('symbol', '?')})"
                debank_usd_col = fmt_usd(wt_usd)
                matched_wallet_addrs.add(asset_addr)
            else:
                # 2a. Explicit symbol → Debank protocol map (sUSDS→sky, sXDAI→gnosis, …)
                explicit_ids = WALLET_SYMBOL_TO_DEBANK_IDS.get(symbol, [])
                if explicit_ids:
                    matched_protos = find_debank_proto(chain_protos, explicit_ids)
                    if matched_protos:
                        total = sum(proto_net_usd(p) for p in matched_protos)
                        ids_str = ", ".join(f"`{p['_short_id']}`" for p in matched_protos)
                        debank_source = f"{ids_str} protocol"
                        debank_usd_col = fmt_usd(total)
                        for p in matched_protos:
                            matched_debank_protos.add(p["_short_id"])

                # 2b. Generic fallback: search Debank protocol supply/reward lists by symbol
                if debank_source == "—":
                    match = find_debank_proto_by_symbol(chain_protos, symbol)
                    if match:
                        pid, p_usd = match
                        debank_source = f"`{pid}` protocol"
                        debank_usd_col = fmt_usd(p_usd)
                        matched_debank_protos.add(pid)
        else:
            # Balance adapter — match by protocol name → Debank ID (prefix match)
            debank_ids = debank_ids_for_nav_protocol(protocol)
            matched_protos = find_debank_proto(chain_protos, debank_ids)
            if matched_protos:
                total = sum(proto_net_usd(p) for p in matched_protos)
                ids_str = ", ".join(f"`{p['_short_id']}`" for p in matched_protos)
                debank_source = ids_str
                debank_usd_col = fmt_usd(total)
                for p in matched_protos:
                    matched_debank_protos.add(p["_short_id"])

        lines.append(
            f"| {nav_type} | {nav_proto_col} | {symbol} | {fmt_amt(amount)} "
            f"| {sign}{fmt_usd(abs(usd))} | {debank_source} | {debank_usd_col} |"
        )

    # ── Debank-only rows (not matched by any NAV position) ─────────────────────
    for p in chain_protos:
        short_id = p.get("_short_id", "")
        if short_id in matched_debank_protos:
            continue
        total = proto_net_usd(p)
        if total < 0.01:
            continue
        covered = "✅" if short_id in supported_ids else "❌ not in NAV"
        lines.append(
            f"| — | — | — | — | — | `{short_id}` {covered} | {fmt_usd(total)} |"
        )

    for t in wallet_tokens:
        tid = (t.get("id") or "").lower()
        if tid in matched_wallet_addrs:
            continue
        amt = t.get("amount", 0)
        price = t.get("price", 0)
        usd = amt * price
        if usd < 0.50:
            continue
        sym = t.get("symbol", "?")
        in_covered = tid in all_covered
        covered = "✅" if in_covered else "❌ not in NAV"
        lines.append(
            f"| — | — | {sym} | {fmt_amt(amt)} | — | wallet {covered} | {fmt_usd(usd)} |"
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
