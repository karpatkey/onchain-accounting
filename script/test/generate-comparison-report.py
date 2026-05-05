#!/usr/bin/env python3
"""
Generate a detailed NAV vs Debank comparison report in Markdown.

For each account × chain: shows NAV position detail (from
test/integration/nav-positions-<chainId>.json written by
RefreshIntegrationSnapshot) and Debank position detail (live API).

Usage:
    . ./.env && python3 script/test/generate-comparison-report.py

Output: comparison-report.md
"""

import json
import os
import subprocess
import sys
from datetime import datetime, timezone

DEBANK_API_KEY = os.environ.get("DEBANK_API_KEY", "")
DEBANK_BASE = "https://pro-openapi.debank.com"
ACCOUNTS_JSON = "test/integration/accounts.json"
ASSETS_JSON = "script/config/assets.json"
NAV_POSITIONS_PATTERN = "test/integration/nav-positions-{chain_id}.json"
OUT_FILE = "comparison-report.md"
NATIVE_SENTINEL = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"


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


def render_nav_positions(positions: list) -> list[str]:
    """Render a NAV positions table from a list of Position dicts."""
    if not positions:
        return ["_No NAV positions reported by oracle._", ""]

    lines = [
        "#### NAV positions (from on-chain oracle)",
        "",
        "| Protocol | Detail | Asset | Amount | USD value |",
        "|---|---|---|---:|---:|",
    ]
    for pos in positions:
        symbol = pos.get("symbol", "?")
        decimals = int(pos.get("decimals", 18))
        amount_raw = int(pos.get("amount", 0))
        amount = amount_raw / 10 ** decimals
        value_8dp = int(pos.get("valueUsd8dp", "0"))
        usd = value_8dp / 1e8
        protocol = pos.get("protocol", "")
        detail = pos.get("positionDetail", "")
        is_debt = pos.get("isDebt", False)
        sign = "−" if is_debt else ""
        lines.append(
            f"| {protocol} | {detail} | {symbol} | {fmt_amt(amount)} | {sign}{fmt_usd(abs(usd))} |"
        )
    lines.append("")
    return lines


def main():
    with open(ACCOUNTS_JSON) as f:
        data = json.load(f)
    with open(ASSETS_JSON) as f:
        assets = json.load(f)

    chains_cfg = data["chains"]
    accounts = data["accounts"]
    tolerance = data["tolerance"]

    # Build registered-token address sets: chain_id -> {lowercase_address}
    registered = {}
    for cid, tokens in assets.get("tokens", {}).items():
        registered[cid] = {v["address"].lower() for v in tokens.values()}

    # Load NAV position detail files (written by RefreshIntegrationSnapshot)
    nav_positions_by_chain: dict[str, dict[str, list]] = {}
    for cid in chains_cfg:
        nav_positions_by_chain[cid] = load_nav_positions(cid)
        if nav_positions_by_chain[cid]:
            print(f"  [nav-positions] chain {cid}: loaded {len(nav_positions_by_chain[cid])} account(s)", file=sys.stderr)
        else:
            print(f"  [nav-positions] chain {cid}: no file (run refresh script to generate)", file=sys.stderr)

    # debank_totals[account_index][chain_id] = computed filtered USD total
    debank_totals: dict[int, dict[str, float]] = {}

    lines = []
    lines += [
        "# NAV vs Debank — Detailed Comparison Report",
        "",
        f"Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}  ",
        f"Tolerance: {tolerance * 100:.0f}%",
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

        # One Debank call covers all chains for this account
        print(f"[{label}] fetching protocol list...", file=sys.stderr)
        proto_resp = debank_get("/v1/user/all_complex_protocol_list", f"id={addr}")
        protos_by_chain = {}
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

            lines += [f"### {chain_name.title()} (chain {cid})", ""]

            if dbank_usd_s and dbank_usd_s.strip():
                dbank_usd = float(dbank_usd_s)
                if dbank_usd > 0:
                    drift = (nav_usd - dbank_usd) / dbank_usd
                    drift_s = f"{drift * 100:+.2f}%"
                    flag = "✅" if abs(drift) <= tolerance else "⚠️"
                else:
                    drift_s, flag = "—", ""
                lines.append(
                    f"**NAV: {fmt_usd(nav_usd)} | Debank filtered: {fmt_usd(dbank_usd)} | Drift: {drift_s} {flag}**"
                )
            else:
                lines.append(f"**NAV: {fmt_usd(nav_usd)} | Debank filtered: — (not available)**")
            lines.append("")

            # ── NAV positions (from forge oracle) ───────────────────────────
            nav_pos_map = nav_positions_by_chain.get(cid, {})
            account_positions = nav_pos_map.get(addr.lower(), None)
            if account_positions is not None:
                lines += render_nav_positions(account_positions)
            else:
                lines += ["_NAV position detail not available — run refresh script._", ""]

            # ── Debank protocol positions ────────────────────────────────────
            chain_protos = protos_by_chain.get(dbank_chain, [])
            if chain_protos:
                def proto_net(p):
                    return sum(
                        i.get("stats", {}).get("net_usd_value", 0)
                        for i in p.get("portfolio_item_list", [])
                    )

                chain_protos = sorted(chain_protos, key=proto_net, reverse=True)

                lines += [
                    "#### Debank protocol positions",
                    "",
                    "| Protocol | Debank ID | Covered | Debank USD | Debank position detail |",
                    "|---|---|:---:|---:|---|",
                ]
                for p in chain_protos:
                    pid = p.get("id", "")
                    short_id = pid
                    for prefix in (f"{dbank_chain}_",):
                        if short_id.startswith(prefix):
                            short_id = short_id[len(prefix):]
                    pname = p.get("name", pid)
                    in_filter = short_id in supported_ids
                    total_net = proto_net(p)
                    nav_proto = "✅" if in_filter else "❌"

                    pos_cells = []
                    for item in p.get("portfolio_item_list", []):
                        detail = item.get("detail", {})
                        item_net = item.get("stats", {}).get("net_usd_value", 0)
                        parts = []
                        supply = detail.get("supply_token_list", [])
                        borrow = detail.get("borrow_token_list", [])
                        reward = detail.get("reward_token_list", [])
                        token = detail.get("token_list", [])
                        if supply:
                            parts.append("supply: " + " + ".join(token_inline(t) for t in supply))
                        if borrow:
                            parts.append("borrow: " + " + ".join(token_inline(t) for t in borrow))
                        if reward:
                            parts.append("rewards: " + " + ".join(token_inline(t) for t in reward))
                        if token and not supply and not borrow:
                            parts.append("tokens: " + " + ".join(token_inline(t) for t in token))
                        net_s = fmt_usd(item_net)
                        cell = ("; ".join(parts) if parts else "—") + f" → **{net_s}**"
                        pos_cells.append(cell)

                    detail_col = "<br>".join(pos_cells) if pos_cells else "—"
                    lines.append(
                        f"| {pname} | `{short_id}` | {nav_proto} | {fmt_usd(total_net)} | {detail_col} |"
                    )
                lines.append("")
            else:
                lines += ["_No Debank protocol positions on this chain._", ""]

            # ── Wallet tokens ───────────────────────────────────────────────
            print(f"  [{label}] fetching token list chain {cid}...", file=sys.stderr)
            tok_resp = debank_get("/v1/user/token_list", f"id={addr}&chain_id={dbank_chain}&is_all=false")

            reg_addrs = registered.get(cid, set())

            in_nav, out_nav = [], []
            for t in tok_resp:
                tid = (t.get("id") or "").lower()
                amt = t.get("amount", 0)
                price = t.get("price", 0)
                usd = amt * price
                if usd < 0.50:
                    continue
                lookup = NATIVE_SENTINEL if tid == dbank_chain else tid
                bucket = in_nav if lookup in reg_addrs else out_nav
                bucket.append((t.get("symbol", "?"), amt, price, usd, tid))

            in_nav.sort(key=lambda x: -x[3])
            out_nav.sort(key=lambda x: -x[3])

            filtered_proto_sum = sum(proto_net(p) for p in chain_protos
                                     if (lambda pid: pid[len(f"{dbank_chain}_"):] if pid.startswith(f"{dbank_chain}_") else pid)(p.get("id", "")) in supported_ids)
            filtered_token_sum = sum(usd for _, _, _, usd, _ in in_nav)
            debank_totals[acc_idx][cid] = filtered_proto_sum + filtered_token_sum

            all_tokens = [(sym, amt, price, usd, tid, True) for sym, amt, price, usd, tid in in_nav] + \
                         [(sym, amt, price, usd, tid, False) for sym, amt, price, usd, tid in out_nav]

            if all_tokens:
                lines += [
                    "#### Debank wallet tokens",
                    "",
                    "| Symbol | Amount | Price | Covered | Debank USD | Address |",
                    "|---|---:|---:|:---:|---:|---|",
                ]
                for sym, amt, price, usd, tid, in_assets in all_tokens:
                    nav_col = "✅" if in_assets else "❌"
                    lines.append(
                        f"| {sym} | {fmt_amt(amt)} | {fmt_usd(price)} | {nav_col} | {fmt_usd(usd)} | `{tid}` |"
                    )
                lines.append("")
            else:
                lines += ["_No significant wallet token balances on this chain._", ""]

    # Write computed Debank totals back to accounts.json — only fill empty slots
    for acc_idx, chain_totals in debank_totals.items():
        for cid, total in chain_totals.items():
            exp = accounts[acc_idx].setdefault("expected", {}).setdefault(cid, {})
            if not exp.get("debankUsd", "").strip():
                exp["debankUsd"] = f"{total:.6f}"
    with open(ACCOUNTS_JSON, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"Updated: {ACCOUNTS_JSON}", file=sys.stderr)

    with open(OUT_FILE, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"Written: {OUT_FILE}", file=sys.stderr)


if __name__ == "__main__":
    if not DEBANK_API_KEY:
        print("DEBANK_API_KEY not set — source .env first", file=sys.stderr)
        sys.exit(1)
    main()
