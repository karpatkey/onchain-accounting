#!/usr/bin/env bash
# Register Chainlink-priced assets directly via cast send, one tx per asset.
# Faster + simpler than forge script for batch registrations: no simulation phase,
# no atomic-all-or-nothing rollback, easy to see exactly which asset failed.
#
# Usage:  register-assets.sh <chainId>
# Reads asset list + Chainlink feed addresses from script/config/assets.json.
# Skips Custom-type (handled by 03_DeployCustomFeeds.s.sol + 04_RegisterCustomAssets.sh).
set -euo pipefail

CID=${1:?chainId required}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
ASSETS_JSON="$REPO_ROOT/script/config/assets.json"
CHAINS_CFG="$DEV_DIR/config/chains.json"

PORT=$(jq -r ".\"$CID\".port" "$CHAINS_CFG")
RPC="http://127.0.0.1:$PORT"

PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
SENDER="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
NAV=$(jq -r '.NAVCalculatorProxy' "$STATE_DIR/$CID-addresses.json")

if ! command -v cast >/dev/null 2>&1; then
  export PATH="$HOME/.foundry/bin:$PATH"
fi

declare -A SYMBOLS
SYMBOLS[1]="ETH WETH wstETH eETH weETH rETH ETH+ ezETH rsETH MORPHO USDC BAL AURA RPL GEAR stETH CRV CVX USDS USDT DAI GHO USDe sUSDe RLUSD crvUSD sUSDS syrupUSDC COMP WBTC AAVE"
SYMBOLS[10]="ETH WETH wstETH USDC USDT COMP"
SYMBOLS[100]="xDAI WXDAI WETH wstETH USDCe sDAI GHO"
SYMBOLS[42161]="ETH WETH wstETH weETH ezETH rsETH MORPHO USDC USDT GHO syrupUSDC COMP"
SYMBOLS[8453]="ETH WETH wstETH weETH cbETH MORPHO USDC GHO COMP"

LIST="${SYMBOLS[$CID]:-}"
[ -z "$LIST" ] && { echo "no symbols for chainId $CID"; exit 0; }

echo "=== register-assets.sh chain=$CID NAV=$NAV"

ok=0; fail=0; skip=0
for sym in $LIST; do
  jq_path=".tokens.\"$CID\".\"$sym\""
  TYPE=$(jq -r "${jq_path}.type // \"\"" "$ASSETS_JSON")
  ADDR=$(jq -r "${jq_path}.address // \"\"" "$ASSETS_JSON")
  FEED=$(jq -r "${jq_path}.pricefeed // \"\"" "$ASSETS_JSON")
  HB=$(jq -r "${jq_path}.heartbeat // 0" "$ASSETS_JSON")

  if [ "$TYPE" != "Chainlink" ]; then
    printf "  skip   %-12s type=%s\n" "$sym" "$TYPE"
    skip=$((skip+1))
    continue
  fi
  if [ -z "$FEED" ] || [ -z "$ADDR" ] || [ "$HB" = "0" ] || [ "$HB" = "null" ]; then
    printf "  skip   %-12s missing field\n" "$sym"
    skip=$((skip+1))
    continue
  fi

  # Check if already registered. If yes, use setPriceFeed; else registerAsset.
  REG=$(cast call "$NAV" "isAssetRegistered(address)(bool)" "$ADDR" --rpc-url "$RPC" 2>/dev/null || echo "false")
  if [ "$REG" = "true" ]; then
    action="setPriceFeed"
    sel="setPriceFeed(address,address,uint8,uint256)"
  else
    action="registerAsset"
    sel="registerAsset(address,address,uint8,uint256)"
  fi
  if out=$(cast send "$NAV" "$sel" "$ADDR" "$FEED" 0 "$HB" \
        --rpc-url "$RPC" --private-key "$PK" --from "$SENDER" 2>&1); then
    printf "  %-6s %-12s feed=%s hb=%s\n" "$action" "$sym" "$FEED" "$HB"
    ok=$((ok+1))
  else
    snippet=$(echo "$out" | grep -iE "revert|error|failed" | head -1 | tr -d '\n' | cut -c1-100)
    printf "  FAIL   %-12s %s\n" "$sym" "$snippet"
    fail=$((fail+1))
  fi
done

echo "--- chain $CID summary: ok=$ok fail=$fail skip=$skip"

# Persist count to addresses file for idempotency
jq --argjson n "$ok" '. + {assetsRegisteredCount: $n}' "$STATE_DIR/$CID-addresses.json" \
  > "$STATE_DIR/$CID-addresses.json.tmp" && mv "$STATE_DIR/$CID-addresses.json.tmp" "$STATE_DIR/$CID-addresses.json"
