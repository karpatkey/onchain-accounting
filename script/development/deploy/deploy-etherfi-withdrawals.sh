#!/usr/bin/env bash
# Deploy + register the ether.fi withdrawal-queue cache adapter on a running dev anvil fork.
#
# Usage:  deploy-etherfi-withdrawals.sh <chainId>
#   e.g.  deploy-etherfi-withdrawals.sh 1
#
# EtherFiWithdrawalQueueBalanceAdapter is a mutable, owner-gated cache adapter (ADR 0014): an off-chain agent
# submits the account's WithdrawRequestNFT tokenIds and the adapter values them from live on-chain reads.
# This helper `forge create`s it (owner = anvil account #0, so submit-etherfi-positions.sh can feed it) and
# calls addBalanceAdapters on the dev NAV. Native ETH must be registered (deploy.sh wires the native feed).
# Then run submit-etherfi-positions.sh to play the agent. Requires deploy.sh to have run first.
set -euo pipefail

CID=${1:?chainId required}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
CHAINS_CFG="$DEV_DIR/config/chains.json"

# ether.fi WithdrawRequestNFT + LiquidityPool + native-ETH sentinel (mainnet). Override per chain via env.
WITHDRAW_REQUEST_NFT=${DEV_ETHERFI_NFT:-0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c}
LIQUIDITY_POOL=${DEV_ETHERFI_LP:-0x308861A430be4cce5502d0A12724771Fc6DaF216}
UNDERLYING_TOKEN=${DEV_ETHERFI_UNDERLYING:-0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE}

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

echo "=== deploy ether.fi withdrawals adapter  chain=$CID NAV=$NAV"
echo "    withdrawRequestNft: $WITHDRAW_REQUEST_NFT"
echo "    liquidityPool:      $LIQUIDITY_POOL"
echo "    underlyingToken:    $UNDERLYING_TOKEN (native ETH)"
echo "    admin+assistant:    $DEV_DEPLOYER_ADDR (dev account #0; admin=assistant for local)"

OUT=$(
  forge create src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueBalanceAdapter.sol:EtherFiWithdrawalQueueBalanceAdapter \
    --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" --broadcast \
    --constructor-args "$WITHDRAW_REQUEST_NFT" "$LIQUIDITY_POOL" "$UNDERLYING_TOKEN" "$NAV" "$DEV_DEPLOYER_ADDR" "$DEV_DEPLOYER_ADDR" 2>&1
) || true
ADAPTER=$(printf '%s\n' "$OUT" | grep -i "Deployed to:" | awk '{print $3}' || true)
if [ -z "$ADAPTER" ]; then
  printf '%s\n' "$OUT" | tail -30
  echo "error: forge create produced no address (is the NAV a contract on this fork?)" >&2
  exit 1
fi
echo "  EtherFiWithdrawalQueue: $ADAPTER"

cast send "$NAV" "addBalanceAdapters(address[])" "[$ADAPTER]" \
  --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" >/dev/null
echo "  registered on NAV (addBalanceAdapters)"

jq --arg a "$ADAPTER" '. + {"EtherFiWithdrawalQueue": $a}' "$ADDR_FILE" > "$ADDR_FILE.tmp" && mv "$ADDR_FILE.tmp" "$ADDR_FILE"
echo "  recorded in $ADDR_FILE"
echo "  -> next: submit-etherfi-positions.sh $CID   (agent step: submit the holder's real tokenId)"
