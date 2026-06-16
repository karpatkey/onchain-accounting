#!/usr/bin/env bash
# Deploy + register the Kelp DAO rsETH Withdrawal Queue balance oracle on a running dev anvil fork.
#
# Usage:  deploy-kelp-withdrawal-queue.sh <chainId>
#   e.g.  deploy-kelp-withdrawal-queue.sh 1
#
# KelpWithdrawalQueueBalanceOracle is a standalone (non-meta) adapter pointed at Kelp's
# LRTWithdrawalManager (the rsETH exit queue). It reports the assets owed across an account's open
# withdrawal requests — one credit position per Kelp-supported payout asset (stETH, ETHx, native ETH)
# that is also registered on the NAV. The supported-asset set is discovered at runtime from
# LRTConfig.getSupportedAssetList(), so the constructor takes only (withdrawalManager, navCalculator).
# stETH and native ETH are registered on the dev NAV at bootstrap; ETHx uses a custom feed the dev
# deploy.sh skips, so an ETHx request is correctly dropped from getOraclePositions (still readable via
# getOracleBalanceForAsset).
#
# Requires deploy.sh to have run first (NAV proxy must exist in state/<chainId>-addresses.json).
set -euo pipefail

CID=${1:?chainId required}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
CHAINS_CFG="$DEV_DIR/config/chains.json"

# Kelp LRTWithdrawalManager (mainnet). Override per chain via env (Kelp WQ is mainnet-only today).
WITHDRAWAL_MANAGER=${DEV_KELP_WQ:-0x62De59c08eB5dAE4b7E6F7a8cAd3006d6965ec16}

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

echo "=== deploy Kelp Withdrawal Queue oracle  chain=$CID NAV=$NAV"
echo "    withdrawalManager: $WITHDRAWAL_MANAGER"

# Capture the full output non-fatally (under `set -e`, a piped grep no-match would otherwise abort
# the script before the guard below runs and swallow the forge error).
OUT=$(
  forge create src/balances/protocols/KelpWithdrawalQueue.sol:KelpWithdrawalQueueBalanceOracle \
    --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" --broadcast \
    --constructor-args "$WITHDRAWAL_MANAGER" "$NAV" 2>&1
) || true
ADAPTER=$(printf '%s\n' "$OUT" | grep -i "Deployed to:" | awk '{print $3}' || true)
if [ -z "$ADAPTER" ]; then
  printf '%s\n' "$OUT" | tail -30
  echo "error: forge create produced no address (is the NAV a contract on this fork?)" >&2
  exit 1
fi
echo "  KelpWithdrawalQueue: $ADAPTER"

cast send "$NAV" "addBalanceOracle(address)" "$ADAPTER" \
  --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" >/dev/null
echo "  registered on NAV (addBalanceOracle)"

jq --arg a "$ADAPTER" '. + {"KelpWithdrawalQueue": $a}' "$ADDR_FILE" > "$ADDR_FILE.tmp" && mv "$ADDR_FILE.tmp" "$ADDR_FILE"
echo "  recorded in $ADDR_FILE"
