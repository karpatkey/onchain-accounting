#!/usr/bin/env bash
# Deploy + register the Lido stETH Withdrawal Queue balance oracle on a running dev anvil fork.
#
# Usage:  deploy-lido-withdrawal-queue.sh <chainId>
#   e.g.  deploy-lido-withdrawal-queue.sh 1
#
# LidoWithdrawalQueueBalanceOracle is a standalone (non-meta) adapter pointed at Lido's
# WithdrawalQueueERC721. It reports the ETH owed across an account's open (un-claimed) withdrawal
# requests, denominated in native ETH (the asset Lido pays on claim; priced via ETH/USD). This
# helper `forge create`s it and calls addBalanceOracle on the dev NAV. Native ETH must be registered
# on the NAV for the position to render (01_DeployNAV registers the native ETH/USD feed at bootstrap).
#
# Requires deploy.sh to have run first (NAV proxy must exist in state/<chainId>-addresses.json).
set -euo pipefail

CID=${1:?chainId required}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
CHAINS_CFG="$DEV_DIR/config/chains.json"

# Lido WithdrawalQueueERC721 (mainnet). Override per chain via env (Lido WQ is mainnet-only today).
WITHDRAWAL_QUEUE=${DEV_LIDO_WQ:-0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1}
# ERC-7528 native-ETH sentinel — what Lido pays on claim and how the adapter denominates positions.
UNDERLYING_TOKEN=${DEV_LIDO_UNDERLYING:-0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE}

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

echo "=== deploy Lido Withdrawal Queue oracle  chain=$CID NAV=$NAV"
echo "    withdrawalQueue: $WITHDRAWAL_QUEUE"
echo "    underlyingToken: $UNDERLYING_TOKEN (native ETH)"

# Capture the full output non-fatally (under `set -e`, a piped grep no-match would otherwise abort
# the script before the guard below runs and swallow the forge error).
OUT=$(
  forge create src/balances/protocols/LidoWithdrawalQueue.sol:LidoWithdrawalQueueBalanceOracle \
    --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" --broadcast \
    --constructor-args "$WITHDRAWAL_QUEUE" "$UNDERLYING_TOKEN" "$NAV" 2>&1
) || true
ADAPTER=$(printf '%s\n' "$OUT" | grep -i "Deployed to:" | awk '{print $3}' || true)
if [ -z "$ADAPTER" ]; then
  printf '%s\n' "$OUT" | tail -30
  echo "error: forge create produced no address (is the NAV a contract on this fork?)" >&2
  exit 1
fi
echo "  LidoWithdrawalQueue: $ADAPTER"

cast send "$NAV" "addBalanceOracle(address)" "$ADAPTER" \
  --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" >/dev/null
echo "  registered on NAV (addBalanceOracle)"

jq --arg a "$ADAPTER" '. + {"LidoWithdrawalQueue": $a}' "$ADDR_FILE" > "$ADDR_FILE.tmp" && mv "$ADDR_FILE.tmp" "$ADDR_FILE"
echo "  recorded in $ADDR_FILE"
