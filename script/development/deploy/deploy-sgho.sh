#!/usr/bin/env bash
# Deploy + register the sGHO (Aave Savings GHO) balance oracle on a running dev anvil fork.
#
# Usage:  deploy-sgho.sh <chainId>
#   e.g.  deploy-sgho.sh 1
#
# ERC4626WrapBalanceOracle is a standalone (non-meta) adapter pointed at the sGHO vault. This helper
# `forge create`s it and calls addBalanceOracle on the dev NAV. The constructor reverts unless GHO is
# registered on the NAV (register-assets.sh registers GHO on chain 1). sGHO vault default below;
# override via DEV_SGHO_WRAPPER.
#
# Requires deploy.sh to have run first (NAV proxy must exist in state/<chainId>-addresses.json).
set -euo pipefail

CID=${1:?chainId required}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
CHAINS_CFG="$DEV_DIR/config/chains.json"

# Mainnet sGHO vault (the wrapper the adapter points at). Override per chain via env.
# `:-` so an explicitly-empty override still falls back (this helper has no skip-on-empty semantics).
SGHO_WRAPPER=${DEV_SGHO_WRAPPER:-0xE1753F2e00940cC31213dd92013cF019DFE4ca1d}

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

echo "=== deploy sGHO oracle  chain=$CID NAV=$NAV"
echo "    wrapper: $SGHO_WRAPPER"

# Capture the full output non-fatally (under `set -e`, a piped grep no-match would otherwise abort
# the script before the guard below runs and swallow the forge error).
OUT=$(
  forge create src/balances/protocols/ERC4626Wrap.sol:ERC4626WrapBalanceOracle \
    --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" --broadcast \
    --constructor-args "$SGHO_WRAPPER" "$NAV" 2>&1
) || true
ADAPTER=$(printf '%s\n' "$OUT" | grep -i "Deployed to:" | awk '{print $3}' || true)
if [ -z "$ADAPTER" ]; then
  printf '%s\n' "$OUT" | tail -30
  echo "error: forge create produced no address (is GHO registered on the NAV?)" >&2
  exit 1
fi
echo "  ERC4626Wrap_sGHO: $ADAPTER"

cast send "$NAV" "addBalanceOracle(address)" "$ADAPTER" \
  --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" >/dev/null
echo "  registered on NAV (addBalanceOracle)"

jq --arg a "$ADAPTER" '. + {"ERC4626Wrap_sGHO": $a}' "$ADDR_FILE" > "$ADDR_FILE.tmp" && mv "$ADDR_FILE.tmp" "$ADDR_FILE"
echo "  recorded in $ADDR_FILE"
