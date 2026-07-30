#!/usr/bin/env bash
# Refresh fork blocks + NAV snapshots + (optional) DeBank reference for the integration
# tests, all driven from test/integration/accounts.json.
#
# Steps:
#   1. For each chain (in parallel): bump `forkBlock` to the latest block via `cast block-number`.
#      The pre-bump value is retained: if step 2 does not regenerate that chain's NAV, the
#      bump is ROLLED BACK, because a new fork block beside old navUsd8dp values is what
#      turns a missing snapshot into a phantom drift.
#   1.5. For each (account × chain) with non-zero unclaimed Merkl rewards, fetch proofs from the
#      Merkl API and write them to test/integration/merkl-proofs.json. Captures the active
#      Distributor merkleRoot at the new fork block for diagnostics. The integration test
#      consumes this fixture in setUp; failed proof submissions are tolerated.
#   2. For each chain (in parallel): run `RefreshIntegrationSnapshot.s.sol` which forks at the
#      new block, replays the deploy pipeline, reads NAV per enabled account, and prints
#      SNAPSHOT lines. Each chain's stdout is captured to its own log; once all chains
#      finish, the script parses SNAPSHOT lines and writes navUsd8dp into accounts.json.
#      A chain is only SUCCESSFUL if it produced at least one SNAPSHOT line and every line
#      reports a healthy NAV (`sequencerDown == false`, zero stale price assets). Anything
#      else fails the chain: a NAV pinned from an unhealthy read becomes the expectation
#      every later run agrees with, so the bad number goes quiet instead of getting louder.
#   3. (Optional) If `DEBANK_API_KEY` is set: per account, fetch /v1/user/all_complex_protocol_list
#      ONCE (covers all chains), and per (chain × account) fetch /v1/user/token_list. Sum
#      two buckets into expected.<chainId>.debankUsd:
#        (a) full net_usd_value of every protocol in chains[chainId].supportedDeBankProtocols
#            — NAV has its own balance adapter for each, so its accounting (debt netting,
#            interest, rewards) is the apples-to-apples reference;
#        (b) wallet token_list filtered to NAV-registered assets in
#            script/config/nav-config/assets-and-price-feeds/<chainId>.json (keyed by symbol →
#            {address, priceFeeds}), plus the native sentinel via the chain id when registered.
#            This mirrors `IERC20.balanceOf(account)` exactly and so is what NAV's default
#            ERC20 adapter reads (USDC, USDT, GHO, stETH, rsETH, native ETH, …).
#      The filter is what makes the comparison apples-to-apples: many accounts hold positions
#      outside NAV's coverage; an unfiltered DeBank total would always exceed NAV. Logs the
#      API key tier and remaining units at the start; degrades gracefully if missing/expired/
#      out of units.
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
NAV_ASSETS_DIR="script/config/nav-config/assets-and-price-feeds"
CHAINS_CONFIG_DIR="script/config/chains"
WALLET_AGGREGATING_REGISTRY="script/test/wallet-aggregating-adapters.json"
MERKL_PROOFS_JSON="test/integration/merkl-proofs.json"
MERKL_DISTRIBUTOR="0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae"
REPORT_MD="${REPORT_MD:-refresh-report.md}"
# Persistent DeBank response cache consumed by generate-comparison-report.py --from-cache.
DEBANK_CACHE_DIR="test/integration/debank-cache"

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
if [[ ! -d "$NAV_ASSETS_DIR" ]]; then
  echo "missing $NAV_ASSETS_DIR (per-chain asset+feed config)" >&2
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
    polygon-mainnet) [[ -n "${POLYGON_URL:-}" ]] && { echo "$POLYGON_URL"; return; } ;;
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

# Wrapper for DeBank curl calls: bounded timeout + light retry so a slow DeBank can't hang CI.
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

# ─── 0. DeBank tier introspection (informational) ─────────────────────────────
debank_active="false"
debank_units_at_start=""
if [[ -n "${DEBANK_API_KEY:-}" ]]; then
  echo "Probing DeBank /v1/account/units …"
  debank_units_at_start=$(debank_units_balance)
  if [[ -n "$debank_units_at_start" ]]; then
    echo "DeBank API key OK. Units at start: $debank_units_at_start"
    debank_active="true"
  else
    echo "DeBank /v1/account/units returned no balance — proceeding without DeBank cross-check."
  fi
else
  echo "DEBANK_API_KEY not set — DeBank cross-check skipped."
fi

# ─── 1. Bump forkBlock per chain (parallel) ───────────────────────────────────
echo
echo "=== 1. Bumping forkBlock for each chain (parallel) ==="
chain_ids=$(jq -r '.chains | keys[]' "$ACCOUNTS_JSON")

block_dir=$(mktemp -d)
trap 'rm -rf "$block_dir"' EXIT
declare -A block_pid
# Pre-bump forkBlock per chain, so a chain whose NAV never regenerates in step 2 can be
# rolled back to the block its stale snapshots were actually computed at. Without this the
# JSON ends up holding a NEW fork block beside OLD navUsd8dp values — the pairing that
# manufactured ACCOUNT_8_COMPOUND_BASE's phantom 19% drift in PR #174.
declare -A old_fork_block
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
  old_fork_block[$chain_id]="$old_block"
  jq_inplace ".chains.\"$chain_id\".forkBlock = $new_block"
  echo "  chain $chain_id: $old_block -> $new_block"
done

# ─── 1.5. Capture Merkl proofs per chain at the new fork blocks ───────────────
# For each (account × chain), query the Merkl API for unclaimed reward entries and write
# them to test/integration/merkl-proofs.json.
#
# ⚠️ NOTHING CONSUMES THIS FIXTURE TODAY. `_seedMerklProofs` was removed with the old Merkl adapter in #141 and has
# not been restored — IntegrationFromConfigBase.fork.sol contains no Merkl code, and the re-added
# MerklRewardsAttestedBalanceAdapter ships `enabled:false` on every chain. This step is kept so the fixture stays in
# sync with the fork blocks (it must be captured AT bump time or not at all — see below), but the integration
# baselines contain no Merkl positions. Re-wiring the harness is a tracked follow-up, coupled to per-chain enablement.
# Once re-wired, the consumer submits each proof against the deployed adapter via `submitProofs`; failed submissions
# are tolerated and logged (NAV treats them as 0).
#
# Why this is here, after the fork-block bump and before the NAV snapshot: proofs from
# the Merkl API are valid against `Distributor.getMerkleRoot()` at the *current* moment.
# Forks pinned to "right now" (which is what step 1 does — bumping to `cast block-number`)
# get the matching root. If Merkl rotates the root between this step and step 2, some
# proofs fail to verify and the test reports zero contribution for those entries.
echo
echo "=== 1.5. Capturing Merkl proofs (per chain × account) ==="
proof_dir=$(mktemp -d)
trap 'rm -rf "$block_dir" "$proof_dir"' EXIT
account_count=$(jq '.accounts | length' "$ACCOUNTS_JSON")

# Initialize merkl-proofs.json with the file header — chain blocks appended below.
{
  echo '{'
  echo '  "$comment": "Per-chain Merkl proof fixtures consumed by IntegrationFromConfigBase.fork.sol. Regenerated by script/test/refresh-integration-snapshot.sh on every bump — do not edit by hand.",'
  echo '  "$schema_comment": "{ <chainId>: { rootBlock, expectedRoot, users[], tokens[], amounts[], proofs[][] } } — users/tokens/amounts/proofs are zip-aligned."'
} > "$proof_dir/header.json"

merkl_total_chains=0
merkl_total_proofs=0
for chain_id in $chain_ids; do
  fork_block=$(jq -r ".chains.\"$chain_id\".forkBlock" "$ACCOUNTS_JSON")
  rpc=$(rpc_for_chain "$chain_id")
  expected_root="0x0000000000000000000000000000000000000000000000000000000000000000"
  if [[ -n "$rpc" ]]; then
    root_at_fork=$(cast call "$MERKL_DISTRIBUTOR" "getMerkleRoot()(bytes32)" \
      --rpc-url "$rpc" --block "$fork_block" 2>/dev/null || echo "")
    if [[ -n "$root_at_fork" && "$root_at_fork" != "null" ]]; then
      expected_root="$root_at_fork"
    fi
  fi

  # Skip chains where Distributor isn't initialized (e.g., test chains).
  if [[ "$expected_root" == "0x0000000000000000000000000000000000000000000000000000000000000000" ]]; then
    echo "  chain $chain_id: Distributor root is zero at block $fork_block — skipping Merkl capture"
  fi

  # Collect per-account entries into a single JSONL stream.
  : > "$proof_dir/$chain_id.entries"
  for ((i=0; i<account_count; i++)); do
    addr=$(jq -r ".accounts[$i].address" "$ACCOUNTS_JSON")
    enabled=$(jq -r ".accounts[$i].enabledChains | index($chain_id) // \"\"" "$ACCOUNTS_JSON")
    [[ -z "$enabled" || "$enabled" == "null" ]] && continue

    merkl_resp=$(curl -fsSL --max-time 30 \
      "https://api.merkl.xyz/v4/users/${addr}/rewards?chainId=${chain_id}" 2>/dev/null || echo "")
    [[ -z "$merkl_resp" ]] && continue

    # Filter to entries with non-zero unclaimed amount; emit one JSON object per entry.
    # Use `$addr` (lowercase) as the user key to match what NAVCalculator and our adapter use.
    echo "$merkl_resp" | jq -c --arg addr "$addr" '
      (.[0].rewards // []) | map(
        select((.amount | tonumber) > (.claimed | tonumber)) |
        { user: $addr, token: .token.address, amount: .amount, proofs: .proofs }
      ) | .[]
    ' >> "$proof_dir/$chain_id.entries" 2>/dev/null || true
  done

  if [[ -s "$proof_dir/$chain_id.entries" ]]; then
    chain_block=$(jq -s \
      --arg block "$fork_block" \
      --arg root "$expected_root" \
      '{
        rootBlock: ($block | tonumber),
        expectedRoot: $root,
        users:   [.[].user],
        tokens:  [.[].token],
        amounts: [.[].amount],
        proofs:  [.[].proofs]
      }' "$proof_dir/$chain_id.entries")
  else
    chain_block=$(jq -n \
      --arg block "$fork_block" \
      --arg root "$expected_root" \
      '{
        rootBlock: ($block | tonumber),
        expectedRoot: $root,
        users: [], tokens: [], amounts: [], proofs: []
      }')
  fi
  echo "$chain_block" > "$proof_dir/$chain_id.block.json"
  n=$(echo "$chain_block" | jq '.users | length')
  echo "  chain $chain_id: $n unclaimed reward entry(ies) captured (root=$expected_root)"
  merkl_total_chains=$((merkl_total_chains+1))
  merkl_total_proofs=$((merkl_total_proofs+n))
done

# Stitch the per-chain blocks into a single JSON file.
{
  cat "$proof_dir/header.json"
  for chain_id in $chain_ids; do
    echo ","
    printf '  "%s": ' "$chain_id"
    cat "$proof_dir/$chain_id.block.json"
  done
  echo
  echo '}'
} > "$proof_dir/merged.json"
# Validate + pretty-print into the canonical location.
if jq . "$proof_dir/merged.json" > "$MERKL_PROOFS_JSON.tmp"; then
  mv "$MERKL_PROOFS_JSON.tmp" "$MERKL_PROOFS_JSON"
  echo "  wrote $MERKL_PROOFS_JSON ($merkl_total_proofs proof(s) across $merkl_total_chains chain(s))"
else
  echo "  [warn] merged JSON failed jq validation; leaving $MERKL_PROOFS_JSON unchanged"
  rm -f "$MERKL_PROOFS_JSON.tmp"
fi

# ─── 2. Refresh NAV snapshot per chain (parallel, throttled) ──────────────────
# Each forge fork+deploy peaks at ~900MB RSS. Five concurrent forges need ~4.5GB;
# default 5 runs all chains in parallel on 16GB+ hosts. Lower via env on smaller
# machines (e.g. MAX_PARALLEL=2 on an 8GB box).
MAX_PARALLEL="${MAX_PARALLEL:-5}"
echo
echo "=== 2. Refreshing NAV snapshots (parallel, MAX_PARALLEL=$MAX_PARALLEL) ==="

# Pre-build once so the parallel forge invocations share a warm cache and don't
# race on `out/` writes during compile.
echo "  pre-building (so parallel forge tests share cache)…"
forge build > /dev/null

forge_dir=$(mktemp -d)
# Replace EXIT trap so both temp dirs are cleaned up at any exit path.
trap 'rm -rf "$block_dir" "$forge_dir"' EXIT

# Track outcomes per chain so step 4 can include succeeded chains and report on failures.
failed_chains=()
ok_chains=()

# Reap any already-finished children to keep the active count accurate.
running=0

# Map chain ID to the concrete integration test contract name (child of IntegrationFromConfigBase).
chain_to_contract() {
  case "$1" in
    1)     echo "MainnetIntegrationFromConfig" ;;
    10)    echo "OptimismIntegrationFromConfig" ;;
    100)   echo "GnosisIntegrationFromConfig" ;;
    8453)  echo "BaseIntegrationFromConfig" ;;
    42161) echo "ArbitrumIntegrationFromConfig" ;;
    *)     echo "" ;;
  esac
}

# Spawn one forge test process for chain_id, redirecting stdout+stderr to per-chain logs.
# Uses `forge test --match-test test_emitSnapshots` instead of `forge script` to avoid
# the chain-1 hang (forge script hangs on Mainnet; forge test does not — see
# docs/howto/refresh-integration-test-blocks.md §"forge script hangs on Mainnet").
# SNAPSHOT line format is identical so harvest_chain needs no changes.
spawn_forge() {
  local chain_id="$1"
  local contract
  contract=$(chain_to_contract "$chain_id")
  (
    FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-slow}" \
      REFRESH_NAV_POSITIONS=1 \
      forge test \
        --match-contract "$contract" \
        --match-test "test_emitSnapshots" \
        -vv \
      > "$forge_dir/$chain_id.out" 2> "$forge_dir/$chain_id.err"
    echo $? > "$forge_dir/$chain_id.rc"
    # Drop a marker so the parent can detect "this chain finished" via filesystem.
    touch "$forge_dir/$chain_id.done"
  ) &
  echo "  chain $chain_id: forge test started (pid=$!, slot $((running+1))/$MAX_PARALLEL)"
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
  # Collect first, apply only if every snapshot for this chain is healthy. Applying a
  # subset is not a safe middle ground: the unapplied accounts keep stale navUsd8dp while
  # step 1 has already advanced this chain's forkBlock, which is precisely the mismatch
  # that fabricates drift.
  local matched=0
  local unhealthy=0
  local pending=()
  local _marker snap_chain idx _addr nav_value seq_down stale_count entry
  while IFS='|' read -r _marker snap_chain idx _addr nav_value seq_down stale_count; do
    [[ -z "${snap_chain:-}" ]] && continue
    # `sequencerDown` and `stalePriceAssets.length` are the NAV's own health flags, emitted
    # by IntegrationFromConfigBase alongside the value. They used to be parsed and dropped,
    # which let the harness PIN a NAV computed on a down sequencer or over stale prices —
    # a snapshot-integrity defect, not a reporting one: once baked into expected values,
    # every later run agrees with the bad number and the suite goes quiet.
    if [[ "${seq_down:-false}" == "true" ]]; then
      echo "  [UNHEALTHY] chain $snap_chain account[$idx]: sequencerDown — refusing to pin this NAV" >&2
      unhealthy=$((unhealthy+1))
      continue
    fi
    if [[ -n "${stale_count:-}" && "$stale_count" =~ ^[0-9]+$ && "$stale_count" -gt 0 ]]; then
      echo "  [UNHEALTHY] chain $snap_chain account[$idx]: $stale_count stale price asset(s) — refusing to pin this NAV" >&2
      unhealthy=$((unhealthy+1))
      continue
    fi
    pending+=("$idx|$snap_chain|$nav_value")
    matched=$((matched+1))
  done < <(grep -oE 'SNAPSHOT\|[^[:space:]]+' "$forge_dir/$chain_id.out" || true)

  # A forge run can exit 0 and still emit no usable SNAPSHOT lines (test filtered out, an
  # account loop that reverted and was swallowed, a log format drift). That used to be
  # booked as success: every account on the chain kept its stale NAV, DeBank refreshed
  # against the NEW fork block, and the mismatch surfaced as a tolerance violation (exit 2)
  # rather than a partial snapshot (exit 1, which takes precedence and diagnoses itself).
  if (( unhealthy > 0 )); then
    echo "  [FAIL] chain $chain_id: $unhealthy unhealthy snapshot(s); applying none of this chain's $((matched+unhealthy))" >&2
    failed_chains+=("$chain_id")
    return
  fi
  if (( matched == 0 )); then
    echo "  [FAIL] chain $chain_id: forge rc=0 but zero SNAPSHOT lines — snapshot NOT refreshed" >&2
    failed_chains+=("$chain_id")
    return
  fi

  for entry in "${pending[@]}"; do
    IFS='|' read -r idx snap_chain nav_value <<< "$entry"
    jq_inplace ".accounts[$idx].expected.\"$snap_chain\".navUsd8dp = \"$nav_value\""
    echo "  chain $snap_chain account[$idx]: navUsd8dp = $nav_value"
  done
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

# Make step 2's outcome atomic per chain. Reads failed_chains/ok_chains/old_fork_block and
# sets `skipped_chains` plus a narrowed `chain_ids`.
#
# Two things have to move together with the NAV, or a missing snapshot becomes a phantom drift:
#   - forkBlock, rolled BACK for a failed chain, so its surviving navUsd8dp stays paired with
#     the block it was actually computed at.
#   - the DeBank reference, which must NOT be refreshed for a failed chain. DeBank is only
#     available at CURRENT state — there is no historical endpoint — so a fresh reference
#     against an old-block NAV is exactly the mismatch that produced #174's fake 19%.
# Narrowing `chain_ids` is what enforces the second. It previously was not narrowed at all,
# while the log claimed "proceeding to step 3/4 with the chains that succeeded".
finalize_step2_outcomes() {
  local chain_id restore_block
  skipped_chains=()
  (( ${#failed_chains[@]} == 0 )) && return 0

  echo
  echo "  step 2 finished with ${#failed_chains[@]} failed chain(s): ${failed_chains[*]}"
  for chain_id in "${failed_chains[@]}"; do
    restore_block="${old_fork_block[$chain_id]:-}"
    if [[ -n "$restore_block" ]]; then
      jq_inplace ".chains.\"$chain_id\".forkBlock = $restore_block"
      echo "  chain $chain_id: forkBlock rolled back to $restore_block (NAV not regenerated)"
    fi
  done

  skipped_chains=("${failed_chains[@]}")
  if (( ${#ok_chains[@]} > 0 )); then
    chain_ids=$(printf '%s\n' "${ok_chains[@]}")
  else
    chain_ids=""
  fi
  echo "  proceeding to step 3/4 with the ${#ok_chains[@]} chain(s) that succeeded: ${ok_chains[*]:-none}"
}

finalize_step2_outcomes

# ─── 3. Refresh DeBank reference per (chain × account) ─────────────────────────
# Filtered comparison: sum only the DeBank protocols whose ids appear in the chain's
# `supportedDeBankProtocols` allowlist, plus only the wallet tokens whose addresses are
# registered as NAV assets in `script/config/nav-config/assets-and-price-feeds/<chainId>.json`.
# This is what makes drift
# meaningful — without filtering, any account holding a position outside NAV's coverage
# would always show NAV < DeBank.
#
# One /v1/user/all_complex_protocol_list call per account covers every chain (DeBank
# returns all chains in the response and we slice by `.chain == debankChainId`).
# /v1/user/token_list is fetched once per (chain × account) since it is chain-scoped.
echo
if [[ "$debank_active" == "true" ]]; then
  echo "=== 3. Refreshing DeBank references (filtered) ==="
  account_count=$(jq '.accounts | length' "$ACCOUNTS_JSON")

  # Cache complex_protocol_list per account address — one DeBank call covers all chains.
  proto_dir=$(mktemp -d)
  trap 'rm -rf "$block_dir" "$forge_dir" "$proto_dir"' EXIT

  for ((i=0; i<account_count; i++)); do
    addr=$(jq -r ".accounts[$i].address" "$ACCOUNTS_JSON")
    label=$(jq -r ".accounts[$i].label" "$ACCOUNTS_JSON")
    # Skip placeholder accounts (address not yet filled in).
    if [[ -z "$addr" || "$addr" == "<"* ]]; then
      echo "  [skip] $label: no address set (placeholder)"
      continue
    fi

    proto_resp=$(debank_curl "https://pro-openapi.debank.com/v1/user/all_complex_protocol_list?id=${addr}")
    if [[ -z "$proto_resp" ]]; then
      echo "  [warn] $label: complex_protocol_list request failed; protocol totals will be 0"
      proto_resp="[]"
    fi
    echo "$proto_resp" > "$proto_dir/$i.json"
    # Persist to the comparison-report cache so it can regenerate without API calls.
    mkdir -p "$DEBANK_CACHE_DIR"
    echo "$proto_resp" | jq '.' > "${DEBANK_CACHE_DIR}/${addr,,}-protocols.json" 2>/dev/null || true

    for chain_id in $chain_ids; do
      enabled=$(jq -r ".accounts[$i].enabledChains | index($chain_id)" "$ACCOUNTS_JSON")
      [[ "$enabled" == "null" ]] && continue

      debank_chain=$(jq -r ".chains.\"$chain_id\".debankChainId" "$ACCOUNTS_JSON")
      supported_protos=$(jq -c ".chains.\"$chain_id\".supportedDeBankProtocols // []" "$ACCOUNTS_JSON")

      # Build NAV-registered asset address allowlist for this chain (lowercased).
      # Union of two sources, matching generate-comparison-report.py's `all_covered`:
      #   1. nav-config/assets-and-price-feeds/<chain>.json — standalone priceable assets in the
      #      NAV registry (keyed by symbol → {address, priceFeeds}). Missing file ⇒ {} (no assets).
      #   2. wallet-aggregating-adapters.json — tokens NOT in (1) but consumed by an
      #      enabled adapter via balanceOf (e.g. Cap reads cUsd + stcUsd via constructor
      #      args in chains/<cid>.json). Without this, accounts holding cUsd/stcUsd would
      #      have an anchor that disagrees with the report's rendered total.
      chain_cfg="$CHAINS_CONFIG_DIR/${chain_id}.json"
      assets_file="$NAV_ASSETS_DIR/${chain_id}.json"
      chain_assets=$([[ -f "$assets_file" ]] && cat "$assets_file" || echo '{}')
      asset_allowlist=$(jq -c -n \
        --argjson assets "$chain_assets" \
        --slurpfile chain "$chain_cfg" \
        --slurpfile reg "$WALLET_AGGREGATING_REGISTRY" \
        '
          ([($assets // {}) | to_entries[] | select(.key | startswith("$") | not) | .value.address | ascii_downcase])
          +
          [
            $reg[0]
            | to_entries[]
            | select(.key | startswith("$") | not)
            | .key as $adapter_key
            | .value as $param_names
            | ($chain[0].balanceAdapters[$adapter_key] // null)
            | select(. != null and .enabled == true)
            | .constructor as $ctor
            | $param_names[]
            | $ctor[.]
            | select(. != null)
            | ascii_downcase
          ]
        ')

      # Sum 1 — protocols in supportedDeBankProtocols: full net_usd_value of every
      # portfolio_item_list entry. NAV has its own balance adapter for each, so its
      # accounting (debt netting, interest accrual, etc.) is the apples-to-apples reference.
      # DeBank returns short ids on mainnet (`aave3`) and `<chain>_<short>` elsewhere
      # (`arb_aave3`); accept either. Bind .id to $pid before the comparison —
      # `index(.id)` would re-resolve `.id` against $allowed.
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

      # Sum 2 — wallet token_list, restricted to NAV-registered assets that AREN'T
      # already accounted for in a protocol entry above.
      #
      # We pass `is_all=false` because DeBank's default (`is_all=true`) returns every
      # wallet-held token including LSTs (rETH, sUSDS, wstETH, ETHx, …) which DeBank
      # *also* categorises under their staking protocols (Rocket Pool, Sky, Lido,
      # Stader). Summing both Sum 1 and an `is_all=true` Sum 2 double-counts those
      # positions — observed as ACCOUNT_10 mainnet anchor inflated by ~$58M from
      # rETH+sUSDS+ETHx+wstETH wallet entries that were already counted under their
      # respective protocols. With `is_all=false`, DeBank suppresses tokens that have
      # a protocol_list entry, leaving only "pure wallet" holdings (USDC, GHO, native
      # ETH, etc.) — matching how NAV counts each economic position exactly once
      # (either via a balance adapter OR a wallet/Holding price feed, never both).
      #
      # generate-comparison-report.py uses the same `is_all=false` flag for its
      # rendered DeBank wallet table; keeping the two scripts symmetric is what
      # makes the stored anchor reconcile with the rendered tables.
      #
      # Native token id from DeBank matches `debank_chain` (`eth`, `arb`, `xdai`, …) and
      # is accepted iff NAV registers the ERC-7528 native sentinel (0xEee…eEeE) for this
      # chain — `ERC20DefaultBalanceAdapter._getBalanceForAsset` returns `account.balance` for it.
      tok_resp=$(debank_curl "https://pro-openapi.debank.com/v1/user/token_list?id=${addr}&chain_id=${debank_chain}&is_all=false")
      if [[ -z "$tok_resp" ]]; then
        echo "  [warn] $label chain $chain_id: token_list request failed; using protocol total only"
        tok_resp="[]"
      fi
      echo "$tok_resp" | jq '.' > "${DEBANK_CACHE_DIR}/${addr,,}-tokens-${chain_id}.json" 2>/dev/null || true
      tok_sum=$(jq -r \
        --arg dc "$debank_chain" \
        --argjson allowed "$asset_allowlist" \
        '
          ($allowed | index("0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")) as $native_ok
          | [.[]
             | (.id // "") as $tid
             | select($tid != "")
             | select(
                 ($allowed | index($tid | ascii_downcase)) != null
                 or ($native_ok != null and $tid == $dc)
               )
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
  echo "=== 3. Skipping DeBank refresh (no key or probe failed) ==="
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
  # Name what this run did NOT cover. A report that silently omits a chain reads as
  # "everything checked and only these drifted", which is how five weeks of these went
  # unread — the one number that looked alarming was an artifact of an uncovered chain.
  if (( ${#skipped_chains[@]} > 0 )); then
    echo
    echo "> **Incomplete run.** NAV was not regenerated for chain(s): ${skipped_chains[*]}."
    echo "> Their \`forkBlock\` was rolled back and their DeBank reference left untouched, so"
    echo "> they are absent from the table below rather than compared against a stale pairing."
    echo "> This run exits 1 (partial snapshot), which takes precedence over tolerance drift."
  fi
  if [[ -n "$debank_units_at_start" || -n "$debank_units_at_end" ]]; then
    echo
    echo "| DeBank units | Value |"
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
    # Numeric zero check: step 3 writes "0.000000" via printf for empty chains, which
    # the old string compare against "0"/"0.0" missed → division by 0. Use awk to test
    # numerically and skip drift entirely for any debankUsd that parses to 0.
    if [[ -n "$debank" ]] && awk "BEGIN { exit !($debank > 0) }"; then
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
#   1 — at least one chain in step 2 failed. Four ways now, not one: forge rc != 0 (RPC
#       down, OOM, revert); forge rc == 0 but ZERO SNAPSHOT lines; any snapshot reporting
#       `sequencerDown`; any snapshot reporting stale price assets. The last three used to
#       be booked as success, which downgraded a partial snapshot to a tolerance violation.
#   2 — every chain succeeded but at least one (chain × account) drifted past tolerance.
# Step-2 failures take precedence over tolerance failures because they mean the snapshot
# is partial (not all chains regenerated) — the tolerance comparison is over a known-good
# subset, but the run itself didn't complete. A failed chain now has its forkBlock rolled
# back and is excluded from steps 3 and 4 entirely, so its stale NAV is never compared
# against a fresh DeBank reference; the report names it as skipped.
if (( ${#failed_chains[@]} > 0 )); then
  echo "${#failed_chains[@]} chain(s) failed in step 2: ${failed_chains[*]}"
  exit 1
fi
if (( violations > 0 )); then
  echo "$violations tolerance violation(s) detected — see $REPORT_MD."
  exit 2
fi
echo "All snapshots within tolerance."
