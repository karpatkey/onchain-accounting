#!/usr/bin/env bash
# Run all development deploy scripts against the running anvil forks.
#
# Phase 1: 01_DeployNAV.s.sol — fresh NAV implementation + proxy on every fork, native feed wired.
# Phase 2: 02_RegisterAssets.s.sol — register the full production asset set with their feeds,
#          using the same Chainlink/custom feed addresses that exist on the forked chains.
#
# Idempotency: deploy.sh checks state/<chain>-addresses.json before each step and skips chains
# that already have the corresponding contract deployed. To force a redeploy, run reset-state.sh
# (or just delete the relevant entry from the addresses file).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
CONFIG="$DEV_DIR/config/chains.json"

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

for cid in $(jq -r 'keys[]' "$CONFIG"); do
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
    echo "[$name $cid] anvil not running — start-forks.sh first; skipping"
    continue
  fi

  echo
  echo "=== [$name $cid] $rpc ==="

  # Step 01: NAV proxy
  if [ -f "$addr_file" ] && [ "$(jq -r '.NAVCalculatorProxy // ""' "$addr_file")" != "" ]; then
    echo "01_DeployNAV: skip (NAV already at $(jq -r '.NAVCalculatorProxy' "$addr_file"))"
  else
    echo "01_DeployNAV: running"
    out=$(
      DEV_NATIVE_SYMBOL="$native" \
      DEV_SEQUENCER_FEED="$sequencer" \
      DEV_NATIVE_FEED="$native_feed" \
      DEV_NATIVE_HEARTBEAT="$native_heartbeat" \
      forge script "$DEV_DIR/01_DeployNAV.s.sol:DeployNAV" \
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

  # Step 02: register the full asset set on this chain's NAV
  proxy=$(jq -r '.NAVCalculatorProxy' "$addr_file")
  registered_count=$(jq -r '.assetsRegisteredCount // 0' "$addr_file")
  if [ "$registered_count" -gt 0 ]; then
    echo "02_RegisterAssets: skip ($registered_count assets already registered)"
  else
    echo "02_RegisterAssets: running"
    out=$(
      DEV_NAV_PROXY="$proxy" \
      forge script "$DEV_DIR/02_RegisterAssets.s.sol:RegisterAssets" \
        --rpc-url "$rpc" \
        --private-key "$DEV_PRIVATE_KEY" \
        --sender "$DEV_DEPLOYER_ADDR" \
        --broadcast \
        2>&1
    )
    if ! echo "$out" | grep -q "REGISTERED_ASSETS_DONE"; then
      echo "$out" | tail -30
      echo "error: 02_RegisterAssets failed; aborting"
      exit 1
    fi
    # Stamp the addresses file so re-runs skip it. We count the printed action lines.
    reg=$(echo "$out" | grep -E "registerAsset|setPriceFeed" | wc -l)
    jq --argjson n "$reg" '. + {assetsRegisteredCount: $n}' "$addr_file" > "$addr_file.tmp" && mv "$addr_file.tmp" "$addr_file"
    echo "  $reg assets registered/updated"
  fi
done

echo
echo "done. run script/development/sync-app-env.sh to point the app at these addresses."
