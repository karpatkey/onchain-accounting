#!/usr/bin/env bash
# Refresh fork blocks + NAV snapshots + (optional) Debank reference for the integration
# tests, all driven from test/integration/accounts.json.
#
# Steps:
#   1. For each chain (in parallel): bump `forkBlock` to the latest block via `cast block-number`.
#   2. For each chain (in parallel): run `RefreshIntegrationSnapshot.s.sol` which forks at the
#      new block, replays the deploy pipeline, reads NAV per enabled account, and prints
#      SNAPSHOT lines. Each chain's stdout is captured to its own log; once all chains
#      finish, the script parses SNAPSHOT lines and writes navUsd8dp into accounts.json.
#   3. (Optional) If `DEBANK_API_KEY` is set: per account, fetch /v1/user/all_complex_protocol_list
#      ONCE (covers all chains), and per (chain × account) fetch /v1/user/token_list. Filter
#      protocols to chains[chainId].supportedDebankProtocols and tokens to NAV-registered
#      assets in script/config/assets.json. Sum filtered protocols + filtered wallet tokens
#      and write into expected.<chainId>.debankUsd. The filter is what makes the comparison
#      apples-to-apples: many accounts hold positions outside NAV's coverage; an unfiltered
#      Debank total would always exceed NAV. Logs the API key tier and remaining units at
#      the start; degrades gracefully if missing/expired/out of units.
#   4. Tolerance check: for every (chain × account) with both navUsd8dp and debankUsd,
#      assert |nav/1e8 - debank| / debank ≤ tolerance. Print a markdown report.
#
# Step 2 is the bottleneck (forge fork + deploy pipeline per chain ≈ 1–3 min each).
# Running 5 chains in parallel takes the wall time from `sum(chains)` to `max(chains)`.
# A pre-build runs once before the parallel forge invocations so they share a warm cache
# without racing on `out/`.
#
# Authoritative reference: docs/howto/refresh-integration-test-blocks.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

ACCOUNTS_JSON="test/integration/accounts.json"
ASSETS_JSON="script/config/assets.json"
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
if [[ ! -f "$ASSETS_JSON" ]]; then
  echo "missing $ASSETS_JSON" >&2
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

# Wrapper for Debank curl calls: bounded timeout + light retry so a slow Debank can't hang CI.
# `--max-time` caps total wall time; `--retry --retry-delay --retry-connrefused` covers transient failures.
# Echoes the response body on success; empty string on failure.
debank_curl() {
  local url="$1"
  curl -fsSL --max-time 30 --retry 2 --retry-delay 5 --retry-connrefused \
    -H "AccessKey: $DEBANK_API_KEY" "$url" 2>/dev/null || echo ""
}

# Probe units balance once. Echoes the balance, or empty string on failure / no balance field.
debank_units_balance() {
  local response
  response=$(debank_curl "https://pro-openapi.debank.com/v1/account/units")
  [[ -z "$response" ]] && { echo ""; return; }
  echo "$response" | jq -r '.balance // empty' 2>/dev/null || echo ""
}

# ─── 0. Debank tier introspection (informational) ─────────────────────────────
debank_active="false"
debank_units_at_start=""
if [[ -n "${DEBANK_API_KEY:-}" ]]; then
  echo "Probing Debank /v1/account/units …"
  debank_units_at_start=$(debank_units_balance)
  if [[ -n "$debank_units_at_start" ]]; then
    echo "Debank API key OK. Units at start: $debank_units_at_start"
    debank_active="true"
  else
    echo "Debank /v1/account/units returned no balance — proceeding without Debank cross-check."
  fi
else
  echo "DEBANK_API_KEY not set — Debank cross-check skipped."
fi

# ─── 1. Bump forkBlock per chain (parallel) ───────────────────────────────────
echo
echo "=== 1. Bumping forkBlock for each chain (parallel) ==="
chain_ids=$(jq -r '.chains | keys[]' "$ACCOUNTS_JSON")

block_dir=$(mktemp -d)
trap 'rm -rf "$block_dir"' EXIT
declare -A block_pid
for chain_id in $chain_ids; do
  rpc=$(rpc_for_chain "$chain_id")
  if [[ -z "$rpc" ]]; then
    echo "  [skip] chain $chain_id: no RPC URL configured (set ALCHEMY_API_KEY or chain-specific *_URL)"
    continue
  fi
  ( cast block-number --rpc-url "$rpc" > "$block_dir/$chain_id" 2> "$block_dir/$chain_id.err" ) &
  block_pid[$chain_id]=$!
done

# Collect results in chain-id order so output is deterministic.
for chain_id in $chain_ids; do
  pid="${block_pid[$chain_id]:-}"
  [[ -z "$pid" ]] && continue
  if ! wait "$pid"; then
    echo "  [fail] chain $chain_id: cast block-number errored: $(cat "$block_dir/$chain_id.err" 2>/dev/null)" >&2
    exit 1
  fi
  new_block=$(<"$block_dir/$chain_id")
  if ! [[ "$new_block" =~ ^[0-9]+$ ]]; then
    echo "  [fail] chain $chain_id: cast returned non-numeric: $new_block" >&2
    exit 1
  fi
  old_block=$(jq -r ".chains.\"$chain_id\".forkBlock" "$ACCOUNTS_JSON")
  jq_inplace ".chains.\"$chain_id\".forkBlock = $new_block"
  echo "  chain $chain_id: $old_block -> $new_block"
done

# ─── 2. Refresh NAV snapshot per chain (parallel, throttled) ──────────────────
# Each forge fork+deploy peaks at ~900MB RSS. Five concurrent forges saturate an
# 8GB host. MAX_PARALLEL caps the number running at once; default 2 is safe on a
# WSL2/8GB box, override via env (e.g. MAX_PARALLEL=4 on a beefier CI runner).
MAX_PARALLEL="${MAX_PARALLEL:-2}"
echo
echo "=== 2. Refreshing NAV snapshots (parallel, MAX_PARALLEL=$MAX_PARALLEL) ==="

# Pre-build once so the parallel forge invocations share a warm cache and don't
# race on `out/` writes during compile.
echo "  pre-building (so parallel forge scripts share cache)…"
forge build > /dev/null

forge_dir=$(mktemp -d)
# Replace EXIT trap so both temp dirs are cleaned up at any exit path.
trap 'rm -rf "$block_dir" "$forge_dir"' EXIT

# Track outcomes per chain so step 4 can include succeeded chains and report on failures.
failed_chains=()
ok_chains=()

# Reap any already-finished children to keep the active count accurate.
running=0

# Spawn one forge process for chain_id, redirecting stdout/stderr to per-chain logs.
spawn_forge() {
  local chain_id="$1"
  (
    CHAIN_ID="$chain_id" \
    FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-slow}" \
      forge script script/test/RefreshIntegrationSnapshot.s.sol \
      > "$forge_dir/$chain_id.out" 2> "$forge_dir/$chain_id.err"
    echo $? > "$forge_dir/$chain_id.rc"
    # Drop a marker so the parent can detect "this chain finished" via filesystem.
    touch "$forge_dir/$chain_id.done"
  ) &
  echo "  chain $chain_id: forge script started (pid=$!, slot $((running+1))/$MAX_PARALLEL)"
}

# Apply SNAPSHOTs for one finished chain and bucket it by outcome.
harvest_chain() {
  local chain_id="$1"
  local rc
  rc=$(<"$forge_dir/$chain_id.rc")
  if [[ "$rc" -ne 0 ]]; then
    echo "  [FAIL] chain $chain_id (forge rc=$rc) — last 30 lines of stderr:" >&2
    tail -n 30 "$forge_dir/$chain_id.err" >&2
    failed_chains+=("$chain_id")
    return
  fi
  local matched=0
  while IFS='|' read -r _marker snap_chain idx _addr nav_value _seq _stale; do
    [[ -z "${snap_chain:-}" ]] && continue
    jq_inplace ".accounts[$idx].expected.\"$snap_chain\".navUsd8dp = \"$nav_value\""
    echo "  chain $snap_chain account[$idx]: navUsd8dp = $nav_value"
    matched=$((matched+1))
  done < <(grep -oE 'SNAPSHOT\|[^[:space:]]+' "$forge_dir/$chain_id.out" || true)
  echo "  chain $chain_id: ${matched} snapshot(s) applied"
  ok_chains+=("$chain_id")
}

# Spawn chains, holding the active count at MAX_PARALLEL by harvesting finished
# slots before launching the next. Iterating in chain_ids order keeps logs deterministic.
declare -a queue
for chain_id in $chain_ids; do
  rpc=$(rpc_for_chain "$chain_id")
  if [[ -z "$rpc" ]]; then
    echo "  [skip] no RPC for chain $chain_id"
    continue
  fi
  queue+=("$chain_id")
done

declare -A in_flight
for chain_id in "${queue[@]}"; do
  while (( running >= MAX_PARALLEL )); do
    # Block briefly until at least one child completes (detected via .done marker file).
    for in_flight_chain in "${!in_flight[@]}"; do
      if [[ -f "$forge_dir/$in_flight_chain.done" ]]; then
        wait "${in_flight[$in_flight_chain]}" || true
        harvest_chain "$in_flight_chain"
        unset 'in_flight[$in_flight_chain]'
        running=$((running-1))
      fi
    done
    (( running >= MAX_PARALLEL )) && sleep 1
  done
  spawn_forge "$chain_id"
  in_flight[$chain_id]=$!
  running=$((running+1))
done

# Drain remaining in-flight chains.
for in_flight_chain in "${!in_flight[@]}"; do
  wait "${in_flight[$in_flight_chain]}" || true
done
# Harvest in chain_ids order so the printed log is deterministic.
for chain_id in "${queue[@]}"; do
  if [[ -f "$forge_dir/$chain_id.done" && ! " ${ok_chains[*]:-} ${failed_chains[*]:-} " =~ " $chain_id " ]]; then
    harvest_chain "$chain_id"
  fi
done

if (( ${#failed_chains[@]} > 0 )); then
  echo
  echo "  step 2 finished with ${#failed_chains[@]} failed chain(s): ${failed_chains[*]}"
  echo "  proceeding to step 3/4 with the ${#ok_chains[@]} chains that succeeded."
fi

# ─── 3. Refresh Debank reference per (chain × account) ─────────────────────────
# Filtered comparison: sum only the Debank protocols whose ids appear in the chain's
# `supportedDebankProtocols` allowlist, plus only the wallet tokens whose addresses are
# registered as NAV assets in `script/config/assets.json`. This is what makes drift
# meaningful — without filtering, any account holding a position outside NAV's coverage
# would always show NAV < Debank.
#
# One /v1/user/all_complex_protocol_list call per account covers every chain (Debank
# returns all chains in the response and we slice by `.chain == debankChainId`).
# /v1/user/token_list is fetched once per (chain × account) since it is chain-scoped.
echo
if [[ "$debank_active" == "true" ]]; then
  echo "=== 3. Refreshing Debank references (filtered) ==="
  account_count=$(jq '.accounts | length' "$ACCOUNTS_JSON")

  # Cache complex_protocol_list per account address — one Debank call covers all chains.
  proto_dir=$(mktemp -d)
  trap 'rm -rf "$block_dir" "$forge_dir" "$proto_dir"' EXIT

  for ((i=0; i<account_count; i++)); do
    addr=$(jq -r ".accounts[$i].address" "$ACCOUNTS_JSON")
    label=$(jq -r ".accounts[$i].label" "$ACCOUNTS_JSON")

    proto_resp=$(debank_curl "https://pro-openapi.debank.com/v1/user/all_complex_protocol_list?id=${addr}")
    if [[ -z "$proto_resp" ]]; then
      echo "  [warn] $label: complex_protocol_list request failed; protocol totals will be 0"
      proto_resp="[]"
    fi
    echo "$proto_resp" > "$proto_dir/$i.json"

    for chain_id in $chain_ids; do
      enabled=$(jq -r ".accounts[$i].enabledChains | index($chain_id)" "$ACCOUNTS_JSON")
      [[ "$enabled" == "null" ]] && continue

      debank_chain=$(jq -r ".chains.\"$chain_id\".debankChainId" "$ACCOUNTS_JSON")
      supported_protos=$(jq -c ".chains.\"$chain_id\".supportedDebankProtocols // []" "$ACCOUNTS_JSON")

      # Sum filtered protocols. Debank returns short ids on mainnet (`aave3`) and
      # `<chain>_<short>` elsewhere (`arb_aave3`); accept either. Bind .id to $pid
      # before the comparison — `index(.id)` would re-resolve `.id` against $allowed.
      proto_sum=$(jq -r \
        --arg dc "$debank_chain" \
        --argjson allowed "$supported_protos" \
        '
          [
            .[]
            | select(.chain == $dc)
            | .id as $pid
            | select(
                ($allowed | index($pid)) != null
                or ($allowed | map($dc + "_" + .) | index($pid)) != null
              )
            | (.portfolio_item_list // [])[]
            | .stats.net_usd_value // 0
          ] | add // 0
        ' "$proto_dir/$i.json")

      # Build NAV-registered asset address allowlist for this chain (lowercased).
      asset_allowlist=$(jq -c \
        --arg c "$chain_id" \
        '[(.tokens[$c] // {}) | to_entries[] | .value.address | ascii_downcase]' \
        "$ASSETS_JSON")

      # Fetch and filter wallet token_list for this (chain × account).
      tok_resp=$(debank_curl "https://pro-openapi.debank.com/v1/user/token_list?id=${addr}&chain_id=${debank_chain}")
      if [[ -z "$tok_resp" ]]; then
        echo "  [warn] $label chain $chain_id: token_list request failed; using protocol total only"
        tok_resp="[]"
      fi
      tok_sum=$(jq -r \
        --argjson allowed "$asset_allowlist" \
        '
          [.[]
           | (.id // "") as $tid
           | select($tid != "")
           | select($allowed | index($tid | ascii_downcase))
           | (.amount // 0) * (.price // 0)]
          | add // 0
        ' <<<"$tok_resp")

      total=$(awk "BEGIN { printf \"%.6f\", $proto_sum + $tok_sum }")
      jq_inplace ".accounts[$i].expected.\"$chain_id\".debankUsd = \"$total\""
      printf "  %s chain %s: protocols=%.4f tokens=%.4f total=%s\n" \
        "$label" "$chain_id" "$proto_sum" "$tok_sum" "$total"
    done
  done
else
  echo "=== 3. Skipping Debank refresh (no key or probe failed) ==="
fi

# ─── 4. Tolerance check + report ──────────────────────────────────────────────
echo
echo "=== 4. Tolerance check & diff report -> $REPORT_MD ==="

tolerance=$(jq -r '.tolerance // 0.01' "$ACCOUNTS_JSON")

# Re-probe units after the run so the report reflects actual consumption rather than a stale snapshot.
debank_units_at_end=""
if [[ "$debank_active" == "true" ]]; then
  debank_units_at_end=$(debank_units_balance)
fi

{
  echo "# Refresh integration snapshot — report"
  echo
  echo "Tolerance: ${tolerance}"
  if [[ -n "$debank_units_at_start" || -n "$debank_units_at_end" ]]; then
    echo
    echo "| Debank units | Value |"
    echo "|---|---|"
    [[ -n "$debank_units_at_start" ]] && echo "| at start | ${debank_units_at_start} |"
    [[ -n "$debank_units_at_end" ]]   && echo "| at end   | ${debank_units_at_end} |"
    if [[ -n "$debank_units_at_start" && -n "$debank_units_at_end" ]]; then
      consumed=$(awk "BEGIN { printf \"%d\", $debank_units_at_start - $debank_units_at_end }")
      echo "| consumed | ${consumed} |"
    fi
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

# Exit code conventions:
#   0 — clean (every chain succeeded, no tolerance violations).
#   1 — at least one chain in step 2 failed (RPC down, OOM, forge revert).
#   2 — every chain succeeded but at least one (chain × account) drifted past tolerance.
# Step-2 failures take precedence over tolerance failures because they mean the snapshot
# is partial (not all chains regenerated) — the tolerance comparison is over a known-good
# subset, but the run itself didn't complete.
if (( ${#failed_chains[@]} > 0 )); then
  echo "${#failed_chains[@]} chain(s) failed in step 2: ${failed_chains[*]}"
  exit 1
fi
if (( violations > 0 )); then
  echo "$violations tolerance violation(s) detected — see $REPORT_MD."
  exit 2
fi
echo "All snapshots within tolerance."
