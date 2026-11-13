#!/usr/bin/env bash
# Bring all running anvil forks up to a usable NAV baseline for testing.
#
# Steps per chain:
#   01. Deploy NAV (impl + proxy + initialize + grant MANAGER + wire native Chainlink feed).
#       Uses dev's own 01_DeployNAV.s.sol — a single-shot script that bakes the prod multi-phase
#       deploy (impl + proxy + handoff) into one tx batch suitable for anvil's prefunded EOA #0.
#   02. Register the full production Chainlink-priced asset set via `register-assets.sh`
#       (cast-based fallback — forge script hangs on Alchemy-backed forks for batch tx scripts).
#
# Custom-priced assets (sUSDe, wstETH, ...) and per-protocol balance adapters are NOT deployed
# here. Those are handled by the prod-equivalent scripts under script/deploy/, invoked separately:
#   - prod/03_DeployPriceFeeds.s.sol   for custom price feeds
#   - prod/04_DeployBalanceAdapters.s.sol for adapter instances
# The development tree intentionally keeps only what differs from prod (NAV bootstrap + cast-based
# asset registration). Adapter deploys + custom feeds reuse prod scripts directly.
#
# Idempotency: each step checks state/<chain>-addresses.json and skips if already done. Run
# anvil/reset-state.sh to force a fresh deploy.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
CONFIG="$DEV_DIR/config/chains.json"
DEPLOY_DIR="$DEV_DIR/deploy"

# Anvil prefunded account #0 — same on every fork.
DEV_PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEV_DEPLOYER_ADDR="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

if ! command -v forge >/dev/null 2>&1; then
  if [ -x "$HOME/.foundry/bin/forge" ]; then
    export PATH="$HOME/.foundry/bin:$PATH"
  else
    echo "error: forge not on PATH" >&2; exit 1
  fi
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq not on PATH" >&2; exit 1
fi

mkdir -p "$STATE_DIR"

# Optional positional args restrict to a subset of chain ids (e.g. `deploy.sh 1` for mainnet
# only). With no args, every chain in chains.json is processed (non-running anvils are skipped).
if [ "$#" -gt 0 ]; then
  CHAIN_IDS="$*"
  for cid in $CHAIN_IDS; do
    if [ "$(jq -r "has(\"$cid\")" "$CONFIG")" != "true" ]; then
      echo "error: chain $cid not in $CONFIG" >&2; exit 1
    fi
  done
else
  CHAIN_IDS=$(jq -r 'keys[]' "$CONFIG")
fi

for cid in $CHAIN_IDS; do
  name=$(jq -r ".\"$cid\".name" "$CONFIG")
  port=$(jq -r ".\"$cid\".port" "$CONFIG")
  native=$(jq -r ".\"$cid\".nativeSymbol" "$CONFIG")
  sequencer=$(jq -r ".\"$cid\".sequencerFeed" "$CONFIG")
  native_feed=$(jq -r ".\"$cid\".nativeChainlinkFeed" "$CONFIG")
  native_heartbeat=$(jq -r ".\"$cid\".nativeChainlinkHeartbeat" "$CONFIG")
  pid_file="$STATE_DIR/$cid.pid"
  addr_file="$STATE_DIR/$cid-addresses.json"
  rpc="http://127.0.0.1:$port"

  if [ ! -f "$pid_file" ] || ! kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    echo "[$name $cid] anvil not running — anvil/start-forks.sh first; skipping"
    continue
  fi

  echo
  echo "=== [$name $cid] $rpc ==="

  # Step 01: NAV proxy + ERC20DefaultOracle + native asset registration.
  if [ -f "$addr_file" ] && [ "$(jq -r '.NAVCalculatorProxy // ""' "$addr_file")" != "" ]; then
    echo "01_DeployNAV: skip (NAV already at $(jq -r '.NAVCalculatorProxy' "$addr_file"))"
  else
    echo "01_DeployNAV: running"
    out=$(
      DEV_NATIVE_SYMBOL="$native" \
      DEV_SEQUENCER_FEED="$sequencer" \
      DEV_NATIVE_FEED="$native_feed" \
      DEV_NATIVE_HEARTBEAT="$native_heartbeat" \
      FOUNDRY_PROFILE=default \
      forge script "$DEPLOY_DIR/01_DeployNAV.s.sol:DeployNAV" \
        --rpc-url "$rpc" \
        --private-key "$DEV_PRIVATE_KEY" \
        --sender "$DEV_DEPLOYER_ADDR" \
        --broadcast \
        2>&1
    )
    line=$(printf '%s\n' "$out" | grep -E '^\s*DEPLOYED ' | tail -1 || true)
    if [ -z "$line" ]; then
      echo "$out" | tail -30
      echo "error: 01_DeployNAV produced no DEPLOYED line; aborting"
      exit 1
    fi
    impl=$(echo "$line" | awk '{print $2}')
    proxy=$(echo "$line" | awk '{print $3}')
    default_oracle=$(echo "$line" | awk '{print $4}')
    jq -n \
      --arg impl "$impl" \
      --arg proxy "$proxy" \
      --arg defaultOracle "$default_oracle" \
      --arg deployer "$DEV_DEPLOYER_ADDR" \
      '{NAVCalculatorImplementation:$impl, NAVCalculatorProxy:$proxy, ERC20DefaultOracle:$defaultOracle, deployer:$deployer}' \
      > "$addr_file"
    echo "  proxy: $proxy"
    echo "  default oracle: $default_oracle"
    echo "  -> $addr_file"
  fi

  # Step 02: register Chainlink-priced assets via cast (forge-script alternative hangs).
  registered_count=$(jq -r '.assetsRegisteredCount // 0' "$addr_file")
  if [ "$registered_count" -gt 0 ]; then
    echo "02_RegisterAssets: skip ($registered_count assets already registered)"
  else
    echo "02_RegisterAssets: running"
    bash "$DEPLOY_DIR/register-assets.sh" "$cid"
  fi
done

echo
echo "done. next:"
echo "  - prod/03_DeployPriceFeeds.s.sol per chain (custom feeds, when needed)"
echo "  - prod/04_DeployBalanceAdapters.s.sol per chain (adapters, when needed)"
