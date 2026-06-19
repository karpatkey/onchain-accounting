#!/usr/bin/env bash
# Register Chainlink-priced assets directly via cast send, one tx per asset.
# Faster + simpler than forge script for batch registrations: no simulation phase,
# no atomic-all-or-nothing rollback, easy to see exactly which asset failed.
#
# Usage:  register-assets.sh <chainId>
# Reads asset list + Chainlink feed addresses from
#   script/config/nav-config/assets-and-price-feeds/<chainId>.json
# (the per-chain config introduced by the PR #70 config split, which deleted the old
# monolithic script/config/assets.json). Each symbol entry is { address, priceFeeds: [
# { type, address, heartbeat }, ... ] }. Only entries whose FIRST price feed is type
# "Chainlink" are registered here; Custom-type assets are deployed via prod's
# script/deploy/03_DeployPriceFeeds.s.sol against the dev anvil RPC (see development/README.md).
set -euo pipefail

CID=${1:?chainId required}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
ASSETS_JSON="$REPO_ROOT/script/config/nav-config/assets-and-price-feeds/$CID.json"
CHAINS_CFG="$DEV_DIR/config/chains.json"

[ -f "$ASSETS_JSON" ] || { echo "error: $ASSETS_JSON not found" >&2; exit 1; }

PORT=$(jq -r ".\"$CID\".port" "$CHAINS_CFG")
RPC="http://127.0.0.1:$PORT"

PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
SENDER="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
NAV=$(jq -r '.NAVCalculatorProxy' "$STATE_DIR/$CID-addresses.json")

if ! command -v cast >/dev/null 2>&1; then
  export PATH="$HOME/.foundry/bin:$PATH"
fi

# Every symbol in the per-chain config (native ETH/xDAI included — it is skipped below
# because 01_DeployNAV already registered NATIVE_ADDRESS + wired its feed).
LIST=$(jq -r 'keys[]' "$ASSETS_JSON")
[ -z "$LIST" ] && { echo "no symbols for chainId $CID"; exit 0; }

echo "=== register-assets.sh chain=$CID NAV=$NAV"

ok=0; fail=0; skip=0
for sym in $LIST; do
  jq_path=".\"$sym\""
  ADDR=$(jq -r "${jq_path}.address // \"\"" "$ASSETS_JSON")
  TYPE=$(jq -r "${jq_path}.priceFeeds[0].type // \"\"" "$ASSETS_JSON")
  FEED=$(jq -r "${jq_path}.priceFeeds[0].address // \"\"" "$ASSETS_JSON")
  HB=$(jq -r "${jq_path}.priceFeeds[0].heartbeat // 0" "$ASSETS_JSON")

  if [ "$TYPE" != "Chainlink" ]; then
    printf "  skip   %-12s type=%s\n" "$sym" "$TYPE"
    skip=$((skip+1))
    continue
  fi
  if [ -z "$FEED" ] || [ -z "$ADDR" ] || [ "$HB" = "0" ] || [ "$HB" = "null" ]; then
    # Treat missing-field as a FAILURE, not a skip. A skip is reserved for intentional
    # cases (e.g. Custom-type assets handled by 03_DeployPriceFeeds.s.sol). A missing
    # field is a config-incomplete state — if we counted it as a skip and `fail` stayed
    # 0, the script would stamp `assetsRegisteredCount` and `deploy.sh` would never
    # retry. Bumping it into `fail` keeps the retry loop active until the config is
    # filled in.
    printf "  FAIL   %-12s missing field (address/pricefeed/heartbeat)\n" "$sym"
    fail=$((fail+1))
    continue
  fi

  # Skip assets already registered — registerAsset sets the Chainlink feed atomically, and the native
  # asset (NATIVE_ADDRESS) is registered + feed-wired by 01_DeployNAV, so a registered asset always
  # already has its feed. Re-running registerAsset would revert (already registered); addPriceFeed
  # would revert too (feed already present). Skipping keeps the step idempotent across retries.
  REG=$(cast call "$NAV" "isAssetRegistered(address)(bool)" "$ADDR" --rpc-url "$RPC" 2>/dev/null || echo "false")
  if [ "$REG" = "true" ]; then
    printf "  skip   %-12s already registered\n" "$sym"
    skip=$((skip+1))
    continue
  fi
  if out=$(cast send "$NAV" "registerAsset(address,address,uint8,uint256)" "$ADDR" "$FEED" 0 "$HB" \
        --rpc-url "$RPC" --private-key "$PK" --from "$SENDER" 2>&1); then
    printf "  %-6s %-12s feed=%s hb=%s\n" "registerAsset" "$sym" "$FEED" "$HB"
    ok=$((ok+1))
  else
    snippet=$(echo "$out" | grep -iE "revert|error|failed" | head -1 | tr -d '\n' | cut -c1-100)
    printf "  FAIL   %-12s %s\n" "$sym" "$snippet"
    fail=$((fail+1))
  fi
done

echo "--- chain $CID summary: ok=$ok fail=$fail skip=$skip"

# Persist count to addresses file for idempotency ONLY when every attempted registration succeeded.
# If any tx failed, leave assetsRegisteredCount unwritten so deploy.sh re-runs this script next
# invocation (each registerAsset/setPriceFeed is per-asset idempotent on the contract side, so
# replay is safe).
if [ "$fail" -eq 0 ]; then
  jq --argjson n "$ok" '. + {assetsRegisteredCount: $n}' "$STATE_DIR/$CID-addresses.json" \
    > "$STATE_DIR/$CID-addresses.json.tmp" && mv "$STATE_DIR/$CID-addresses.json.tmp" "$STATE_DIR/$CID-addresses.json"
else
  echo "--- chain $CID: $fail failure(s) — NOT stamping assetsRegisteredCount; deploy.sh will retry"
fi
