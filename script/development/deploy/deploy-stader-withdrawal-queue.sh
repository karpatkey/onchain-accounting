#!/usr/bin/env bash
# Deploy + register the Stader ETHx Withdrawal Queue balance adapter on a running dev anvil fork.
#
# Usage:  deploy-stader-withdrawal-queue.sh <chainId>
#   e.g.  deploy-stader-withdrawal-queue.sh 1
#
# StaderWithdrawalQueueBalanceAdapter is a standalone (non-meta) adapter pointed at Stader's
# UserWithdrawalManager. It reports the ETH owed across an account's open (un-claimed) withdrawal
# requests, denominated in WETH (the position is ETH owed by the manager once ETHx is burned; priced
# via ETH/USD). This helper `forge create`s it and calls addBalanceAdapters on the dev NAV. WETH must be
# registered on the NAV for the position to render (deploy.sh registers the WETH/USD feed at bootstrap).
#
# Requires deploy.sh to have run first (NAV proxy must exist in state/<chainId>-addresses.json).
set -euo pipefail

CID=${1:?chainId required}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
CHAINS_CFG="$DEV_DIR/config/chains.json"

# Stader UserWithdrawalManager (mainnet). Override per chain via env (Stader WQ is mainnet-only today).
USER_WITHDRAWAL_MANAGER=${DEV_STADER_WQ:-0x9F0491B32DBce587c50c4C43AB303b06478193A7}
# WETH — the position is ETH owed by the manager; NAV prices it via ETH/USD.
UNDERLYING_TOKEN=${DEV_STADER_UNDERLYING:-0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2}

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

echo "=== deploy Stader Withdrawal Queue adapter  chain=$CID NAV=$NAV"
echo "    userWithdrawalManager: $USER_WITHDRAWAL_MANAGER"
echo "    underlyingToken:       $UNDERLYING_TOKEN (WETH)"

# Capture the full output non-fatally (under `set -e`, a piped grep no-match would otherwise abort
# the script before the guard below runs and swallow the forge error).
OUT=$(
  forge create src/balances/protocols/StaderWithdrawalQueueBalanceAdapter.sol:StaderWithdrawalQueueBalanceAdapter \
    --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" --broadcast \
    --constructor-args "$USER_WITHDRAWAL_MANAGER" "$UNDERLYING_TOKEN" "$NAV" 2>&1
) || true
ADAPTER=$(printf '%s\n' "$OUT" | grep -i "Deployed to:" | awk '{print $3}' || true)
if [ -z "$ADAPTER" ]; then
  printf '%s\n' "$OUT" | tail -30
  echo "error: forge create produced no address (is the NAV a contract on this fork?)" >&2
  exit 1
fi
echo "  StaderWithdrawalQueue: $ADAPTER"

cast send "$NAV" "addBalanceAdapters(address[])" "[$ADAPTER]" \
  --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" >/dev/null
echo "  registered on NAV (addBalanceAdapters)"

jq --arg a "$ADAPTER" '. + {"StaderWithdrawalQueue": $a}' "$ADDR_FILE" > "$ADDR_FILE.tmp" && mv "$ADDR_FILE.tmp" "$ADDR_FILE"
echo "  recorded in $ADDR_FILE"
