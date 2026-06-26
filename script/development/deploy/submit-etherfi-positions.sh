#!/usr/bin/env bash
# Play the ether.fi submitter agent on a running dev anvil fork: submit a holder's WithdrawRequestNFT
# tokenIds into the deployed EtherFiWithdrawalsBalanceAdapter, so the dashboard shows the queue leg.
#
# Usage:  submit-etherfi-positions.sh <chainId> [holder] [tokenId ...]
#   e.g.  submit-etherfi-positions.sh 1
#         submit-etherfi-positions.sh 1 0xcFFab3dFdCa60d838512c41a772e799b71dF1Af4 80154 80155
#
# In production the kpk-agents bot discovers tokenIds via the Transfer-event scan; on the dev fork we pass a
# known real holder + tokenId (default: 0xcFFab3… owns #80154, ~0.2531 ETH pending). The adapter re-verifies
# ownerOf on read, so only genuinely-owned ids contribute. Requires deploy-etherfi-withdrawals.sh first.
set -euo pipefail

CID=${1:?chainId required}
HOLDER=${2:-0xcFFab3dFdCa60d838512c41a772e799b71dF1Af4}
shift $(( $# >= 2 ? 2 : 1 )) || true
TOKEN_IDS=("$@")
[ ${#TOKEN_IDS[@]} -eq 0 ] && TOKEN_IDS=(80154)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHAINS_CFG="$REPO_ROOT/script/development/config/chains.json"
STATE_DIR="$REPO_ROOT/script/development/state"
NATIVE=0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
DEV_PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"  # account #0 = adapter owner

if ! command -v cast >/dev/null 2>&1; then export PATH="$HOME/.foundry/bin:$PATH"; fi
PORT=$(jq -r ".\"$CID\".port" "$CHAINS_CFG")
RPC="http://127.0.0.1:$PORT"
ADDR_FILE="$STATE_DIR/$CID-addresses.json"
ADAPTER=$(jq -r '.EtherFiWithdrawalQueue' "$ADDR_FILE")
[ "$ADAPTER" = "null" ] || [ -z "$ADAPTER" ] && { echo "error: EtherFiWithdrawalQueue not in $ADDR_FILE — run deploy-etherfi-withdrawals.sh $CID first" >&2; exit 1; }

# Build the uint256[] literal: [id1,id2,...]
IDS_CSV=$(IFS=,; echo "${TOKEN_IDS[*]}")
echo "=== submit ether.fi tokenIds  adapter=$ADAPTER  holder=$HOLDER  ids=[$IDS_CSV]"

cast send "$ADAPTER" "submitTokenIds(address,uint256[])" "$HOLDER" "[$IDS_CSV]" \
  --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" >/dev/null
echo "  submitted."

OWED=$(cast call "$ADAPTER" "getAdapterBalanceForAsset(address,address)(uint256,bool)" "$HOLDER" "$NATIVE" --rpc-url "$RPC" 2>/dev/null | head -1)
echo "  cached tokenIds: $(cast call "$ADAPTER" 'tokenIdsOf(address)(uint256[])' "$HOLDER" --rpc-url "$RPC" 2>/dev/null)"
echo "  adapter reports ETH owed = $OWED wei  (~$(cast from-wei "${OWED%% *}" 2>/dev/null || echo '?') ETH)"
echo "  -> sync-app-env.sh $CID, restart Next.js, enter $HOLDER — the ether.fi withdrawal leg should show."
