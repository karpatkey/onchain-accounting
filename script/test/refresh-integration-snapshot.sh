#!/usr/bin/env bash
# Refresh fork blocks + NAV snapshots + (optional) Debank reference for the integration
# tests, all driven from test/integration/accounts.json.
#
# Steps:
#   1. For each chain: bump `forkBlock` to the latest block via `cast block-number`.
#   2. For each chain: run `RefreshIntegrationSnapshot.s.sol` which forks at the new block,
#      replays the deploy pipeline, reads NAV per enabled account, and prints SNAPSHOT lines.
#      The script parses those lines and writes navUsd8dp into accounts.json.
#   3. (Optional) If `DEBANK_API_KEY` is set: for each (chain × account) call Debank's
#      /v1/user/chain_balance, write `debankUsd` into accounts.json. Logs the API key tier
#      and remaining units at the start; degrades gracefully if missing/expired/out of units.
#   4. Tolerance check: for every (chain × account) with both navUsd8dp and debankUsd,
#      assert |nav/1e8 - debank| / debank ≤ tolerance. Print a markdown report.
#
# Authoritative reference: docs/howto/refresh-integration-test-blocks.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

ACCOUNTS_JSON="test/integration/accounts.json"
REPORT_MD="${REPORT_MD:-refresh-report.md}"

# ─── Prereqs ──────────────────────────────────────────────────────────────────
for cmd in jq cast forge curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "missing required command: $cmd" >&2
    exit 1
  fi
done

if [[ -f .env ]]; then set -a; . ./.env; set +a; fi

if [[ ! -f "$ACCOUNTS_JSON" ]]; then
  echo "missing $ACCOUNTS_JSON" >&2
  exit 1
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Resolve a chain's RPC URL: prefer chain-specific *_URL, else build from ALCHEMY_API_KEY + alchemyNetwork.
rpc_for_chain() {
  local chain_id="$1"
  local network
  network=$(jq -r ".chains.\"$chain_id\".alchemyNetwork" "$ACCOUNTS_JSON")
  case "$network" in
    eth-mainnet)    [[ -n "${MAINNET_URL:-}" ]] && { echo "$MAINNET_URL"; return; } ;;
    arb-mainnet)    [[ -n "${ARBITRUM_URL:-}" ]] && { echo "$ARBITRUM_URL"; return; } ;;
    base-mainnet)   [[ -n "${BASE_URL:-}" ]] && { echo "$BASE_URL"; return; } ;;
    opt-mainnet)    [[ -n "${OP_URL:-}" ]] && { echo "$OP_URL"; return; } ;;
    gnosis-mainnet) [[ -n "${GNOSIS_URL:-}" ]] && { echo "$GNOSIS_URL"; return; } ;;
  esac
  if [[ -n "${ALCHEMY_API_KEY:-}" ]]; then
    echo "https://${network}.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
    return
  fi
  echo ""
}

# Atomically replace the file given a jq filter. Keeps the file valid JSON throughout.
jq_inplace() {
  local filter="$1"
  local tmp
  tmp=$(mktemp)
  jq "$filter" "$ACCOUNTS_JSON" > "$tmp"
  mv "$tmp" "$ACCOUNTS_JSON"
}

# ─── 0. Debank tier introspection (informational) ─────────────────────────────
debank_active="false"
debank_units_remaining=""
if [[ -n "${DEBANK_API_KEY:-}" ]]; then
  echo "Probing Debank /v1/account/units …"
  units_response=$(curl -fsSL -H "AccessKey: $DEBANK_API_KEY" \
    "https://pro-openapi.debank.com/v1/account/units" 2>&1) || units_response=""
  if [[ -n "$units_response" ]]; then
    debank_units_remaining=$(echo "$units_response" | jq -r '.balance // empty' 2>/dev/null || echo "")
    if [[ -n "$debank_units_remaining" ]]; then
      echo "Debank API key OK. Units remaining: $debank_units_remaining"
      debank_active="true"
    else
      echo "Debank /v1/account/units returned no balance field — proceeding without Debank cross-check."
      echo "Response: $units_response"
    fi
  else
    echo "Debank /v1/account/units request failed — proceeding without Debank cross-check."
  fi
else
  echo "DEBANK_API_KEY not set — Debank cross-check skipped."
fi

# ─── 1. Bump forkBlock per chain ──────────────────────────────────────────────
echo
echo "=== 1. Bumping forkBlock for each chain ==="
chain_ids=$(jq -r '.chains | keys[]' "$ACCOUNTS_JSON")

for chain_id in $chain_ids; do
  rpc=$(rpc_for_chain "$chain_id")
  if [[ -z "$rpc" ]]; then
    echo "  [skip] chain $chain_id: no RPC URL configured (set ALCHEMY_API_KEY or chain-specific *_URL)"
    continue
  fi
  old_block=$(jq -r ".chains.\"$chain_id\".forkBlock" "$ACCOUNTS_JSON")
  new_block=$(cast block-number --rpc-url "$rpc") || { echo "  [fail] chain $chain_id: cast block-number errored" >&2; exit 1; }
  jq_inplace ".chains.\"$chain_id\".forkBlock = $new_block"
  echo "  chain $chain_id: $old_block -> $new_block"
done

# ─── 2. Refresh NAV snapshot per chain ────────────────────────────────────────
echo
echo "=== 2. Refreshing NAV snapshots ==="

for chain_id in $chain_ids; do
  echo "--- chain $chain_id ---"
  rpc=$(rpc_for_chain "$chain_id")
  if [[ -z "$rpc" ]]; then
    echo "  [skip] no RPC for chain $chain_id"
    continue
  fi

  # Run forge script. We don't pass --rpc-url because the script itself calls
  # vm.createSelectFork via the integration test base.
  output=$(CHAIN_ID="$chain_id" \
    FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-slow}" \
    forge script script/test/RefreshIntegrationSnapshot.s.sol 2>&1) || {
      echo "$output" >&2
      echo "  [fail] forge script errored on chain $chain_id" >&2
      exit 1
    }

  # Parse SNAPSHOT|<chainId>|<accountIndex>|<address>|<navUsd8dp>|<sequencerDown>|<staleCount> lines.
  while IFS='|' read -r _marker snap_chain idx _addr nav_value _seq _stale; do
    [[ -z "${snap_chain:-}" ]] && continue
    jq_inplace ".accounts[$idx].expected.\"$snap_chain\".navUsd8dp = \"$nav_value\""
    echo "  account[$idx] chain $snap_chain: navUsd8dp = $nav_value"
  done < <(echo "$output" | grep -oE 'SNAPSHOT\|[^[:space:]]+' || true)
done

# ─── 3. Refresh Debank reference per (chain × account) ─────────────────────────
echo
if [[ "$debank_active" == "true" ]]; then
  echo "=== 3. Refreshing Debank references ==="
  account_count=$(jq '.accounts | length' "$ACCOUNTS_JSON")
  for chain_id in $chain_ids; do
    debank_chain=$(jq -r ".chains.\"$chain_id\".debankChainId" "$ACCOUNTS_JSON")
    for ((i=0; i<account_count; i++)); do
      enabled=$(jq -r ".accounts[$i].enabledChains | index($chain_id)" "$ACCOUNTS_JSON")
      [[ "$enabled" == "null" ]] && continue
      addr=$(jq -r ".accounts[$i].address" "$ACCOUNTS_JSON")
      label=$(jq -r ".accounts[$i].label" "$ACCOUNTS_JSON")

      response=$(curl -fsSL -H "AccessKey: $DEBANK_API_KEY" \
        "https://pro-openapi.debank.com/v1/user/chain_balance?id=${addr}&chain_id=${debank_chain}" 2>&1) || response=""
      if [[ -z "$response" ]]; then
        echo "  [warn] $label chain $chain_id: Debank request failed; skipping"
        continue
      fi
      usd=$(echo "$response" | jq -r '.usd_value // empty')
      if [[ -z "$usd" ]]; then
        echo "  [warn] $label chain $chain_id: no usd_value in response: $response"
        continue
      fi
      jq_inplace ".accounts[$i].expected.\"$chain_id\".debankUsd = \"$usd\""
      printf "  %s chain %s: %s\n" "$label" "$chain_id" "$usd"
    done
  done
else
  echo "=== 3. Skipping Debank refresh (no key or probe failed) ==="
fi

# ─── 4. Tolerance check + report ──────────────────────────────────────────────
echo
echo "=== 4. Tolerance check & diff report -> $REPORT_MD ==="

tolerance=$(jq -r '.tolerance // 0.01' "$ACCOUNTS_JSON")

{
  echo "# Refresh integration snapshot — report"
  echo
  echo "Tolerance: ${tolerance}"
  if [[ -n "$debank_units_remaining" ]]; then
    echo
    echo "Debank units remaining after run: ${debank_units_remaining}"
  fi
  echo
  echo "## Per-chain fork blocks"
  echo
  echo "| chain | forkBlock |"
  echo "|---|---|"
  for chain_id in $chain_ids; do
    fb=$(jq -r ".chains.\"$chain_id\".forkBlock" "$ACCOUNTS_JSON")
    echo "| $chain_id | $fb |"
  done

  echo
  echo "## Per-account NAV snapshots"
  echo
  echo "| label | chain | navUsd8dp | navUsd | debankUsd | drift |"
  echo "|---|---|---|---|---|---|"
} > "$REPORT_MD"

violations=0
account_count=$(jq '.accounts | length' "$ACCOUNTS_JSON")
for ((i=0; i<account_count; i++)); do
  label=$(jq -r ".accounts[$i].label" "$ACCOUNTS_JSON")
  for chain_id in $chain_ids; do
    has_expected=$(jq -r ".accounts[$i].expected | has(\"$chain_id\")" "$ACCOUNTS_JSON")
    [[ "$has_expected" != "true" ]] && continue
    nav8dp=$(jq -r ".accounts[$i].expected.\"$chain_id\".navUsd8dp // \"\"" "$ACCOUNTS_JSON")
    debank=$(jq -r ".accounts[$i].expected.\"$chain_id\".debankUsd // \"\"" "$ACCOUNTS_JSON")
    [[ -z "$nav8dp" ]] && continue

    nav_usd=$(awk "BEGIN { printf \"%.6f\", $nav8dp / 100000000 }")
    drift_str="-"
    if [[ -n "$debank" && "$debank" != "0" && "$debank" != "0.0" ]]; then
      drift=$(awk "BEGIN { d = $nav_usd - $debank; if (d<0) d=-d; printf \"%.4f\", d / $debank }")
      drift_str="${drift}"
      if awk "BEGIN { exit !($drift > $tolerance) }"; then
        violations=$((violations+1))
        echo "  [TOLERANCE] $label chain $chain_id: |nav $nav_usd - debank $debank| / debank = $drift > $tolerance"
      fi
    fi
    echo "| $label | $chain_id | $nav8dp | $nav_usd | ${debank:--} | $drift_str |" >> "$REPORT_MD"
  done
done

echo
echo "Report written: $REPORT_MD"
if (( violations > 0 )); then
  echo "$violations tolerance violation(s) detected — see $REPORT_MD."
  exit 2
fi
echo "All snapshots within tolerance."
