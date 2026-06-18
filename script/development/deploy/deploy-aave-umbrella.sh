#!/usr/bin/env bash
# Deploy + register the Aave Umbrella balance adapter on a running dev anvil fork.
#
# Usage:  deploy-aave-umbrella.sh <chainId>
#   e.g.  deploy-aave-umbrella.sh 1
#
# AaveUmbrellaBalanceAdapter is a standalone (non-meta) adapter: it pins only the Umbrella
# RewardsController and discovers the stake-token set at runtime. So this helper just `forge create`s
# it and calls addBalanceAdapters on the dev NAV (it is plain, so it has no instance set to seed).
# Mainnet RewardsController default below; override via DEV_UMBRELLA_REWARDS_CONTROLLER.
#
# Requires deploy.sh to have run first (NAV proxy must exist in state/<chainId>-addresses.json, with the
# bare reserves USDC/USDT/WETH/GHO registered — register-assets.sh does this for chain 1).
set -euo pipefail

CID=${1:?chainId required}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
CHAINS_CFG="$DEV_DIR/config/chains.json"

# Mainnet Umbrella RewardsController (the adapter's only pinned address). Override per chain via env.
# `:-` so an explicitly-empty override still falls back (this helper has no skip-on-empty semantics).
REWARDS_CONTROLLER=${DEV_UMBRELLA_REWARDS_CONTROLLER:-0x4655Ce3D625a63d30bA704087E52B4C31E38188B}

# Anvil prefunded account #0 (holds MANAGER after 01_DeployNAV).
DEV_PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

if ! command -v forge >/dev/null 2>&1; then export PATH="$HOME/.foundry/bin:$PATH"; fi
if ! command -v jq >/dev/null 2>&1; then echo "error: jq not on PATH" >&2; exit 1; fi
if ! command -v cast >/dev/null 2>&1; then export PATH="$HOME/.foundry/bin:$PATH"; fi

PORT=$(jq -r ".\"$CID\".port" "$CHAINS_CFG")
RPC="http://127.0.0.1:$PORT"
ADDR_FILE="$STATE_DIR/$CID-addresses.json"
[ -f "$ADDR_FILE" ] || { echo "error: $ADDR_FILE not found — run deploy.sh $CID first" >&2; exit 1; }
NAV=$(jq -r '.NAVCalculatorProxy' "$ADDR_FILE")
if [ "$NAV" = "null" ] || [ -z "$NAV" ]; then echo "error: no NAVCalculatorProxy in $ADDR_FILE" >&2; exit 1; fi

echo "=== deploy Aave Umbrella adapter  chain=$CID NAV=$NAV"
echo "    rewardsController: $REWARDS_CONTROLLER"

# Capture the full output non-fatally (under `set -e`, a piped grep no-match would otherwise abort
# the script before the guard below runs and swallow the forge error).
OUT=$(
  forge create src/balances/protocols/AaveUmbrella.sol:AaveUmbrellaBalanceAdapter \
    --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" --broadcast \
    --constructor-args "$REWARDS_CONTROLLER" "$NAV" 2>&1
) || true
ADAPTER=$(printf '%s\n' "$OUT" | grep -i "Deployed to:" | awk '{print $3}' || true)
if [ -z "$ADAPTER" ]; then
  printf '%s\n' "$OUT" | tail -30
  echo "error: forge create produced no address (are the bare reserves registered on the NAV?)" >&2
  exit 1
fi
echo "  AaveUmbrella: $ADAPTER"

cast send "$NAV" "addBalanceAdapters(address[])" "[$ADAPTER]" \
  --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" >/dev/null
echo "  registered on NAV (addBalanceAdapters)"

jq --arg a "$ADAPTER" '. + {"AaveUmbrella": $a}' "$ADDR_FILE" > "$ADDR_FILE.tmp" && mv "$ADDR_FILE.tmp" "$ADDR_FILE"
echo "  recorded in $ADDR_FILE"
