#!/usr/bin/env bash
# Deploy + register the Nexus Mutual staked-NXM balance adapter on a running dev anvil fork.
#
# Usage:  deploy-nexus.sh <chainId>
#   e.g.  deploy-nexus.sh 1
#
# NexusStakedNxmBalanceAdapter is a simple immutable view adapter (no agent, no owner): it discovers an
# account's StakingNFT positions by scanning tokenInfo(1..totalSupply) and values them via
# StakingViewer.getAggregatedTokens into NXM-denominated Staking (active+expired) + Rewards legs.
# NXM is priced by a custom RAMM feed (NXM_PriceOracle), which dev deploy.sh does NOT auto-register
# (it wires Chainlink assets only). So this helper, in order:
#   1. deploys NXM_PriceOracle and registerAsset()s NXM with it (Custom price type),
#   2. forge create's the adapter,
#   3. addBalanceAdapters() on the dev NAV.
# Requires deploy.sh to have run first. The Nexus Safe 0x8e53D04644E9ab0412a8c6bd228C84da7664cFE3 is a
# live holder, so no seeding is needed — enter it in the dashboard after sync-app-env.sh.
set -euo pipefail

CID=${1:?chainId required}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
CHAINS_CFG="$DEV_DIR/config/chains.json"

# Nexus Mutual mainnet contracts + NXM pricing inputs (override per env). NXM custom feed = RAMM book value
# (ETH/NXM) * ETH/USD Chainlink; same args as the prod custom-price-feed config for NXM.
STAKING_NFT=${DEV_NEXUS_STAKING_NFT:-0xcafea508a477D94c502c253A58239fb8F948e97f}
STAKING_VIEWER=${DEV_NEXUS_STAKING_VIEWER:-0xcafea5c7d25a192ba70ECA0E2dB62F835c1cF81F}
NXM_TOKEN=${DEV_NEXUS_NXM:-0xd7c49CEE7E9188cCa6AD8FF264C1DA2e69D4Cf3B}
NXM_RAMM=${DEV_NEXUS_RAMM:-0xcafea54f03E1Cc036653444e581A10a43B2487CD}
ETH_USD_ORACLE=${DEV_ETH_USD_ORACLE:-0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419}
ETH_USD_HEARTBEAT=${DEV_ETH_USD_HEARTBEAT:-3600}
PRICE_TYPE_CUSTOM=3 # IPrices.PriceType.Custom

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

echo "=== deploy Nexus staked-NXM adapter  chain=$CID NAV=$NAV"
echo "    stakingNft:    $STAKING_NFT"
echo "    stakingViewer: $STAKING_VIEWER"
echo "    underlying:    $NXM_TOKEN (NXM)"

# --- 1. NXM custom price feed + asset registration (skip if NXM already registered) ----------------------
if cast call "$NAV" "isAssetRegistered(address)(bool)" "$NXM_TOKEN" --rpc-url "$RPC" 2>/dev/null | grep -qi true; then
  echo "  NXM already registered on NAV — skipping feed deploy"
else
  echo "--- deploy NXM_PriceOracle (RAMM book value * ETH/USD)"
  FEED_OUT=$(
    forge create src/prices/protocols/NXM_Price.sol:NXM_PriceOracle \
      --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" --broadcast \
      --constructor-args "$NXM_TOKEN" "$NXM_RAMM" "$ETH_USD_ORACLE" "$ETH_USD_HEARTBEAT" 2>&1
  ) || true
  NXM_FEED=$(printf '%s\n' "$FEED_OUT" | grep -i "Deployed to:" | awk '{print $3}' || true)
  if [ -z "$NXM_FEED" ]; then
    printf '%s\n' "$FEED_OUT" | tail -30
    echo "error: NXM_PriceOracle deploy failed (is RAMM live on this fork block?)" >&2
    exit 1
  fi
  echo "  NXM_PriceOracle: $NXM_FEED"
  cast send "$NAV" "registerAsset(address,address,uint8,uint256)" \
    "$NXM_TOKEN" "$NXM_FEED" "$PRICE_TYPE_CUSTOM" "$ETH_USD_HEARTBEAT" \
    --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" >/dev/null
  echo "  registered NXM on NAV (Custom feed)"
  jq --arg a "$NXM_FEED" '. + {"NXM_PriceOracle": $a}' "$ADDR_FILE" > "$ADDR_FILE.tmp" && mv "$ADDR_FILE.tmp" "$ADDR_FILE"
fi

# --- 2. adapter ------------------------------------------------------------------------------------------
echo "--- deploy NexusStakedNxmBalanceAdapter"
OUT=$(
  forge create src/balances/protocols/NexusStakedNxm.sol:NexusStakedNxmBalanceAdapter \
    --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" --broadcast \
    --constructor-args "$STAKING_NFT" "$STAKING_VIEWER" "$NXM_TOKEN" "$NAV" 2>&1
) || true
ADAPTER=$(printf '%s\n' "$OUT" | grep -i "Deployed to:" | awk '{print $3}' || true)
if [ -z "$ADAPTER" ]; then
  printf '%s\n' "$OUT" | tail -30
  echo "error: forge create produced no address (is the NAV a contract on this fork?)" >&2
  exit 1
fi
echo "  NexusStakedNxm: $ADAPTER"

# --- 3. register on NAV ----------------------------------------------------------------------------------
cast send "$NAV" "addBalanceAdapters(address[])" "[$ADAPTER]" \
  --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" >/dev/null
echo "  registered on NAV (addBalanceAdapters)"

jq --arg a "$ADAPTER" '. + {"NexusStakedNxm": $a}' "$ADDR_FILE" > "$ADDR_FILE.tmp" && mv "$ADDR_FILE.tmp" "$ADDR_FILE"
echo "  recorded in $ADDR_FILE"
echo "  -> next: sync-app-env.sh $CID, then enter 0x8e53D04644E9ab0412a8c6bd228C84da7664cFE3 in the dashboard"
