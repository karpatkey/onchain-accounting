#!/usr/bin/env bash
# Register Custom-priced assets (IPriceFeedCustom adapters) directly via cast send, one tx per asset.
# Companion to register-assets.sh, which handles only Chainlink-type assets and explicitly skips Custom.
#
# Usage:  register-custom-assets.sh <chainId>
# Reads every type=="Custom" token for the chain from script/config/assets.json.
#
# Key assumption: we fork a chain where NAV v2 is already LIVE, so the custom price-feed contracts
# already exist on the fork at their prod addresses (the fork inherits mainnet state). We therefore
# just register the asset in NAV pointing at that existing feed — no fresh feed deploy needed.
# A feed address with NO code on the fork is reported and skipped (it is a feed not yet live on the
# forked chain; deploy it via prod script/deploy/03_DeployPriceFeeds.s.sol against this RPC instead).
set -euo pipefail

CID=${1:?chainId required}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
ASSETS_JSON="$REPO_ROOT/script/config/assets.json"
CHAINS_CFG="$DEV_DIR/config/chains.json"

PORT=$(jq -r ".\"$CID\".port // empty" "$CHAINS_CFG")
[ -z "$PORT" ] && { echo "ERROR: chainId $CID has no .port in $CHAINS_CFG — is it a configured dev chain?"; exit 1; }
RPC="http://127.0.0.1:$PORT"

PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
SENDER="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
ADDR_FILE="$STATE_DIR/$CID-addresses.json"
[ -f "$ADDR_FILE" ] || { echo "ERROR: $ADDR_FILE not found — deploy the fork for chainId $CID first."; exit 1; }
NAV=$(jq -r '.NAVCalculatorProxy // empty' "$ADDR_FILE")
[ -z "$NAV" ] && { echo "ERROR: NAVCalculatorProxy missing in $ADDR_FILE"; exit 1; }

# IPrices.PriceType.Custom == 3
CUSTOM_PRICE_TYPE=3

if ! command -v cast >/dev/null 2>&1; then
  export PATH="$HOME/.foundry/bin:$PATH"
fi
command -v cast >/dev/null 2>&1 || { echo "ERROR: 'cast' not found (install Foundry or add ~/.foundry/bin to PATH)"; exit 1; }

# Every type=="Custom" token configured for this chain.
LIST=$(jq -r ".tokens.\"$CID\" | to_entries[] | select(.value.type==\"Custom\") | .key" "$ASSETS_JSON")
[ -z "$LIST" ] && { echo "no custom-type assets for chainId $CID"; exit 0; }

echo "=== register-custom-assets.sh chain=$CID NAV=$NAV"

ok=0; fail=0; skip=0
for sym in $LIST; do
  jq_path=".tokens.\"$CID\".\"$sym\""
  ADDR=$(jq -r "${jq_path}.address // \"\"" "$ASSETS_JSON")
  FEED=$(jq -r "${jq_path}.pricefeed // \"\"" "$ASSETS_JSON")
  HB=$(jq -r "${jq_path}.heartbeat // 0" "$ASSETS_JSON")

  if [ -z "$FEED" ] || [ -z "$ADDR" ] || [ "$HB" = "0" ] || [ "$HB" = "null" ]; then
    printf "  FAIL   %-12s missing field (address/pricefeed/heartbeat)\n" "$sym"
    fail=$((fail+1))
    continue
  fi

  # The custom feed must already exist on the fork (NAV v2 is live on the forked chain). If it has
  # no code, it is a not-yet-live feed — skip + report; deploy it via prod 03 against this RPC.
  CODE=$(cast code "$FEED" --rpc-url "$RPC" 2>/dev/null || echo "0x")
  if [ "$CODE" = "0x" ] || [ -z "$CODE" ]; then
    printf "  skip   %-12s feed %s has NO code on fork (not live; use prod 03)\n" "$sym" "$FEED"
    skip=$((skip+1))
    continue
  fi

  # Idempotent: registerAsset wires the feed atomically, so an already-registered asset already
  # has its feed. Re-running would revert. Skip.
  REG=$(cast call "$NAV" "isAssetRegistered(address)(bool)" "$ADDR" --rpc-url "$RPC" 2>/dev/null || echo "false")
  if [ "$REG" = "true" ]; then
    printf "  skip   %-12s already registered\n" "$sym"
    skip=$((skip+1))
    continue
  fi

  if out=$(cast send "$NAV" "registerAsset(address,address,uint8,uint256)" "$ADDR" "$FEED" "$CUSTOM_PRICE_TYPE" "$HB" \
        --rpc-url "$RPC" --private-key "$PK" --from "$SENDER" 2>&1); then
    printf "  %-13s %-12s feed=%s hb=%s\n" "registerAsset" "$sym" "$FEED" "$HB"
    ok=$((ok+1))
  else
    # `|| true`: under `set -o pipefail` a no-match grep (exit 1) would otherwise abort the loop and mask the send failure.
    snippet=$(echo "$out" | grep -iE "revert|error|failed" | head -1 | tr -d '\n' | cut -c1-100 || true)
    printf "  FAIL   %-12s %s\n" "$sym" "$snippet"
    fail=$((fail+1))
  fi
done

echo "--- chain $CID custom summary: ok=$ok fail=$fail skip=$skip"
