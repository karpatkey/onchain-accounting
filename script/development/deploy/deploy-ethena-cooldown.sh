#!/usr/bin/env bash
# Deploy + register the Ethena sUSDe cooldown balance adapter on a running dev anvil fork.
#
# Usage:  deploy-ethena-cooldown.sh <chainId>
#   e.g.  deploy-ethena-cooldown.sh 1
#
# EthenaCooldownBalanceAdapter is a standalone (non-meta) adapter pointed at Ethena's StakedUSDeV2
# (sUSDe). It reports the USDe owed to an account in the unstaking cooldown (sUSDe.cooldowns(account)
# .underlyingAmount), denominated in USDe (priced via USDe/USD). This helper `forge create`s it and calls
# addBalanceAdapters on the dev NAV. USDe must be registered on the NAV (deploy.sh registers the USDe/USD
# Chainlink feed at bootstrap). Requires deploy.sh to have run first.
set -euo pipefail

CID=${1:?chainId required}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
CHAINS_CFG="$DEV_DIR/config/chains.json"

# Ethena StakedUSDeV2 (sUSDe) + USDe (mainnet). Override per chain via env (Ethena is mainnet-only today).
STAKED_USDE=${DEV_ETHENA_SUSDE:-0x9D39A5DE30e57443BfF2A8307A4256c8797A3497}
UNDERLYING_TOKEN=${DEV_ETHENA_USDE:-0x4c9EDD5852cd905f086C759E8383e09bff1E68B3}

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

echo "=== deploy Ethena cooldown adapter  chain=$CID NAV=$NAV"
echo "    stakedUSDe:      $STAKED_USDE (sUSDe)"
echo "    underlyingToken: $UNDERLYING_TOKEN (USDe)"

OUT=$(
  forge create src/balances/protocols/EthenaCooldownBalanceAdapter.sol:EthenaCooldownBalanceAdapter \
    --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" --broadcast \
    --constructor-args "$STAKED_USDE" "$UNDERLYING_TOKEN" "$NAV" 2>&1
) || true
ADAPTER=$(printf '%s\n' "$OUT" | grep -i "Deployed to:" | awk '{print $3}' || true)
if [ -z "$ADAPTER" ]; then
  printf '%s\n' "$OUT" | tail -30
  echo "error: forge create produced no address (is the NAV a contract on this fork?)" >&2
  exit 1
fi
echo "  EthenaCooldown: $ADAPTER"

cast send "$NAV" "addBalanceAdapters(address[])" "[$ADAPTER]" \
  --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" >/dev/null
echo "  registered on NAV (addBalanceAdapters)"

jq --arg a "$ADAPTER" '. + {"EthenaCooldown": $a}' "$ADDR_FILE" > "$ADDR_FILE.tmp" && mv "$ADDR_FILE.tmp" "$ADDR_FILE"
echo "  recorded in $ADDR_FILE"
