#!/usr/bin/env python3
"""
Generate a detailed NAV vs Debank comparison report in Markdown.

For each account × chain: shows every Debank protocol position (with token
breakdown) and every wallet token (split into NAV-registered vs unregistered),
alongside the NAV value from accounts.json.

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

    for acc in accounts:
        addr = acc["address"]
        label = acc["label"]
        enabled = [str(c) for c in acc["enabledChains"]]

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

            # ── Protocol positions ──────────────────────────────────────────
            chain_protos = protos_by_chain.get(dbank_chain, [])
            if chain_protos:
                # Sort by descending net USD value
                def proto_net(p):
                    return sum(
                        i.get("stats", {}).get("net_usd_value", 0)
                        for i in p.get("portfolio_item_list", [])
                    )

                chain_protos = sorted(chain_protos, key=proto_net, reverse=True)

                lines += [
                    "#### Protocol positions",
                    "",
                    "| Protocol | Debank ID | In filter | Net USD | Position detail |",
                    "|---|---|:---:|---:|---|",
                ]
                for p in chain_protos:
                    pid = p.get("id", "")
                    # Normalise: strip chain prefix so arb_aave3 → aave3
                    short_id = pid
                    for prefix in (f"{dbank_chain}_",):
                        if short_id.startswith(prefix):
                            short_id = short_id[len(prefix):]
                    pname = p.get("name", pid)
                    in_filter = "✅" if short_id in supported_ids else "❌"
                    total_net = proto_net(p)

                    # Flatten positions into readable text
                    pos_cells = []
                    for item in p.get("portfolio_item_list", []):
                        detail = item.get("detail", {})
                        item_net = item.get("stats", {}).get("net_usd_value", 0)
                        parts = []
                        supply = detail.get("supply_token_list", [])
                        borrow = detail.get("borrow_token_list", [])
                        reward = detail.get("reward_token_list", [])
                        token = detail.get("token_list", [])  # LP / vault tokens
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
                        f"| {pname} | `{short_id}` | {in_filter} | {fmt_usd(total_net)} | {detail_col} |"
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
                if usd < 0.50:  # ignore dust
                    continue
                # Native token: Debank uses the chain string as id
                lookup = NATIVE_SENTINEL if tid == dbank_chain else tid
                bucket = in_nav if lookup in reg_addrs else out_nav
                bucket.append((t.get("symbol", "?"), amt, price, usd, tid))

            in_nav.sort(key=lambda x: -x[3])
            out_nav.sort(key=lambda x: -x[3])

            if in_nav or out_nav:
                lines += ["#### Wallet tokens", ""]
                if in_nav:
                    lines += [
                        "**Registered in `assets.json` (counted by NAV):**",
                        "",
                        "| Symbol | Amount | Price | USD | Address |",
                        "|---|---:|---:|---:|---|",
                    ]
                    for sym, amt, price, usd, tid in in_nav:
                        lines.append(f"| {sym} | {fmt_amt(amt)} | {fmt_usd(price)} | {fmt_usd(usd)} | `{tid}` |")
                    lines.append("")
                if out_nav:
                    lines += [
                        "**NOT in `assets.json` — unpriced / not counted by NAV:**",
                        "",
                        "| Symbol | Amount | Price | USD | Address |",
                        "|---|---:|---:|---:|---|",
                    ]
                    for sym, amt, price, usd, tid in out_nav:
                        lines.append(f"| {sym} | {fmt_amt(amt)} | {fmt_usd(price)} | {fmt_usd(usd)} | `{tid}` |")
                    lines.append("")
            else:
                lines += ["_No significant wallet token balances on this chain._", ""]

    with open(OUT_FILE, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"\nWritten: {OUT_FILE}", file=sys.stderr)


if __name__ == "__main__":
    if not DEBANK_API_KEY:
        print("DEBANK_API_KEY not set — source .env first", file=sys.stderr)
        sys.exit(1)
    main()
