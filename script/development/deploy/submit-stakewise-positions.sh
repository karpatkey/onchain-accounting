#!/usr/bin/env bash
# Play the StakeWise exit-queue submitter agent on a running dev anvil fork: submit a holder's exit tuple
# (vault, positionTicket, timestamp) into the deployed StakeWiseV3ExitQueueAssistedBalanceAdapter, so the dashboard shows
# the exit-queue leg.
#
# Usage:  submit-stakewise-positions.sh <chainId> [holder] [vault] [positionTicket] [timestamp]
#   e.g.  submit-stakewise-positions.sh 1
#
# In production the kpk-agents bot discovers tuples via the ExitQueueEntered-event scan; on the dev fork we pass a
# known real holder + tuple. Default: the ENS DAO Safe's Genesis-vault exit (ticket 2418433…2194, ts 1782159731).
# NOTE: that exact position is only valued while it is open — the anvil fork must be pinned in its open window
# (~block 25,378,000–25,382,000) for it to render; against a HEAD fork it has been claimed and reads 0. For a live
# HEAD fork, pass a currently-open exit tuple instead. The adapter re-verifies the tuple on read via
# calculateExitedAssets(receiver=account), so only genuinely-owned positions contribute.
set -euo pipefail

CID=${1:?chainId required}
HOLDER=${2:-0x4F2083f5fBede34C2714aFfb3105539775f7FE64}
VAULT=${3:-0xAC0F906E433d58FA868F936E8A43230473652885}
TICKET=${4:-241843370089062440762194}
TS=${5:-1782159731}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHAINS_CFG="$REPO_ROOT/script/development/config/chains.json"
STATE_DIR="$REPO_ROOT/script/development/state"
NATIVE=0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
DEV_PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"  # account #0 = adapter owner

if ! command -v cast >/dev/null 2>&1; then export PATH="$HOME/.foundry/bin:$PATH"; fi
PORT=$(jq -r ".\"$CID\".port" "$CHAINS_CFG")
RPC="http://127.0.0.1:$PORT"
ADDR_FILE="$STATE_DIR/$CID-addresses.json"
ADAPTER=$(jq -r '.StakeWiseV3ExitQueueAssisted' "$ADDR_FILE")
[ "$ADAPTER" = "null" ] || [ -z "$ADAPTER" ] && { echo "error: StakeWiseV3ExitQueueAssisted not in $ADDR_FILE — run deploy-stakewise-exit.sh $CID first" >&2; exit 1; }

echo "=== submit StakeWise exit tuple  adapter=$ADAPTER  holder=$HOLDER"
echo "    (vault=$VAULT, positionTicket=$TICKET, timestamp=$TS)"

cast send "$ADAPTER" "submitPositions(address,(address,uint256,uint256)[])" "$HOLDER" "[($VAULT,$TICKET,$TS)]" \
  --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" >/dev/null
echo "  submitted."

OWED=$(cast call "$ADAPTER" "getAdapterBalanceForAsset(address,address)(uint256,bool)" "$HOLDER" "$NATIVE" --rpc-url "$RPC" 2>/dev/null | head -1)
echo "  cached positions: $(cast call "$ADAPTER" 'positionsOf(address)((address,uint256,uint256)[])' "$HOLDER" --rpc-url "$RPC" 2>/dev/null)"
echo "  adapter reports ETH owed = $OWED wei  (~$(cast from-wei "${OWED%% *}" 2>/dev/null || echo '?') ETH)"
echo "  -> sync-app-env.sh $CID, restart Next.js, enter $HOLDER — the StakeWise exit-queue leg should show."
