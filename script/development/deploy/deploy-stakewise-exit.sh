#!/usr/bin/env bash
# Deploy + register the StakeWise V3 exit-queue cache adapter on a running dev anvil fork.
#
# Usage:  deploy-stakewise-exit.sh <chainId>
#   e.g.  deploy-stakewise-exit.sh 1
#
# StakeWiseV3ExitQueueBalanceAdapter is a mutable, owner-gated cache adapter (ADR 0014, sibling of the ether.fi
# withdrawals adapter): an off-chain agent submits each (vault, positionTicket, timestamp) exit tuple and the
# adapter values it from live on-chain reads. This helper `forge create`s it (owner = anvil account #0, so
# submit-stakewise-positions.sh can feed it) and calls addBalanceAdapters on the dev NAV. Native ETH must be
# registered (deploy.sh wires the native feed). Then run submit-stakewise-positions.sh to play the agent.
# Requires deploy.sh to have run first.
set -euo pipefail

CID=${1:?chainId required}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
CHAINS_CFG="$DEV_DIR/config/chains.json"

# StakeWise VaultsRegistry + native-ETH sentinel (mainnet). Override per chain via env.
VAULTS_REGISTRY=${DEV_STAKEWISE_REGISTRY:-0x3a0008a588772446f6e656133C2D5029CC4FC20E}
UNDERLYING_TOKEN=${DEV_STAKEWISE_UNDERLYING:-0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE}

# Anvil prefunded account #0 (holds MANAGER after 01_DeployNAV; also the adapter owner on the dev fork).
DEV_PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEV_DEPLOYER_ADDR="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

if ! command -v forge >/dev/null 2>&1; then export PATH="$HOME/.foundry/bin:$PATH"; fi
if ! command -v jq >/dev/null 2>&1; then echo "error: jq not on PATH" >&2; exit 1; fi
if ! command -v cast >/dev/null 2>&1; then export PATH="$HOME/.foundry/bin:$PATH"; fi

PORT=$(jq -r ".\"$CID\".port" "$CHAINS_CFG")
RPC="http://127.0.0.1:$PORT"
ADDR_FILE="$STATE_DIR/$CID-addresses.json"
[ -f "$ADDR_FILE" ] || { echo "error: $ADDR_FILE not found — run deploy.sh $CID first" >&2; exit 1; }
NAV=$(jq -r '.NAVCalculatorProxy' "$ADDR_FILE")
if [ "$NAV" = "null" ] || [ -z "$NAV" ]; then echo "error: no NAVCalculatorProxy in $ADDR_FILE" >&2; exit 1; fi

echo "=== deploy StakeWise V3 exit-queue adapter  chain=$CID NAV=$NAV"
echo "    vaultsRegistry:  $VAULTS_REGISTRY"
echo "    underlyingToken: $UNDERLYING_TOKEN (native ETH)"
echo "    admin+assistant: $DEV_DEPLOYER_ADDR (dev account #0; admin=assistant for local)"

OUT=$(
  forge create src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueBalanceAdapter.sol:StakeWiseV3ExitQueueBalanceAdapter \
    --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" --broadcast \
    --constructor-args "$VAULTS_REGISTRY" "$UNDERLYING_TOKEN" "$NAV" "$DEV_DEPLOYER_ADDR" "$DEV_DEPLOYER_ADDR" 2>&1
) || true
ADAPTER=$(printf '%s\n' "$OUT" | grep -i "Deployed to:" | awk '{print $3}' || true)
if [ -z "$ADAPTER" ]; then
  printf '%s\n' "$OUT" | tail -30
  echo "error: forge create produced no address (is the NAV a contract on this fork?)" >&2
  exit 1
fi
echo "  StakeWiseV3ExitQueue: $ADAPTER"

cast send "$NAV" "addBalanceAdapters(address[])" "[$ADAPTER]" \
  --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" >/dev/null
echo "  registered on NAV (addBalanceAdapters)"

jq --arg a "$ADAPTER" '. + {"StakeWiseV3ExitQueue": $a}' "$ADDR_FILE" > "$ADDR_FILE.tmp" && mv "$ADDR_FILE.tmp" "$ADDR_FILE"
echo "  recorded in $ADDR_FILE"
echo "  -> next: submit-stakewise-positions.sh $CID   (agent step: submit a holder's real exit tuple)"
