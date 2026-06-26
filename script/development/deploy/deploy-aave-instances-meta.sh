#!/usr/bin/env bash
# Deploy + register the Aave V3 instances meta-adapter on a running dev anvil fork.
#
# Usage:  deploy-aave-instances-meta.sh <chainId>
#   e.g.  deploy-aave-instances-meta.sh 1
#
# Deploys the Aave V3 meta (instances = Core + Lido ProtocolDataProviders), registering it via a single atomic
# addMetaBalanceAdapter(adapter, instances) call (register + seed) — mirrors
# script/deploy/06_Configure.s.sol. Mainnet ProtocolDataProvider defaults below; override per chain via the
# DEV_V3_DATA_PROVIDERS env var (comma-separated).
#
# Requires deploy.sh to have run first (NAV proxy must exist in state/<chainId>-addresses.json).
set -euo pipefail

CID=${1:?chainId required}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
DEPLOY_DIR="$DEV_DIR/deploy"
CHAINS_CFG="$DEV_DIR/config/chains.json"

# Mainnet instance ProtocolDataProviders (override per chain via env):
#   Aave V3 Core: 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3  (getMarketId "Aave Ethereum Market")
#   Aave V3 Lido: 0xB85B2bFEbeC4F5f401dbf92ac147A3076391fCD5  (getMarketId "Aave V3 Lido Ethereum" — Prime)
# `${VAR-default}` (no colon): only an UNSET var falls back to the default; an explicitly-empty value stays
# empty and hits the `-z "$dps"` skip branch in deploy_one — so e.g. DEV_V3_DATA_PROVIDERS="" skips deploy.
V3_DPS=${DEV_V3_DATA_PROVIDERS-0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3,0xB85B2bFEbeC4F5f401dbf92ac147A3076391fCD5}

# Anvil prefunded account #0 (holds MANAGER after 01_DeployNAV).
DEV_PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEV_DEPLOYER_ADDR="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

if ! command -v forge >/dev/null 2>&1; then export PATH="$HOME/.foundry/bin:$PATH"; fi
if ! command -v jq >/dev/null 2>&1; then echo "error: jq not on PATH" >&2; exit 1; fi

PORT=$(jq -r ".\"$CID\".port" "$CHAINS_CFG")
RPC="http://127.0.0.1:$PORT"
ADDR_FILE="$STATE_DIR/$CID-addresses.json"
[ -f "$ADDR_FILE" ] || { echo "error: $ADDR_FILE not found — run deploy.sh $CID first" >&2; exit 1; }
NAV=$(jq -r '.NAVCalculatorProxy' "$ADDR_FILE")
if [ "$NAV" = "null" ] || [ -z "$NAV" ]; then echo "error: no NAVCalculatorProxy in $ADDR_FILE" >&2; exit 1; fi

deploy_one() {
  local name="$1" dps="$2" key="$3"
  [ -z "$dps" ] && { echo "=== skip $name (no data providers)"; return 0; }
  echo "=== deploy $name meta  chain=$CID NAV=$NAV"
  echo "    instances: $dps"
  local out line adapter
  out=$(
    DEV_NAV_PROXY="$NAV" \
    DEV_PROTOCOL_NAME="$name" \
    DEV_DATA_PROVIDERS="$dps" \
    FOUNDRY_PROFILE=dev \
    forge script "$DEPLOY_DIR/deploy-aave-instances-meta.s.sol:DeployAaveInstancesMeta" \
      --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" --sender "$DEV_DEPLOYER_ADDR" --broadcast 2>&1
  )
  line=$(printf '%s\n' "$out" | grep -E '^\s*DEPLOYED ' | tail -1 || true)
  if [ -z "$line" ]; then
    printf '%s\n' "$out" | tail -40
    echo "error: $name deploy produced no DEPLOYED line; aborting" >&2
    exit 1
  fi
  adapter=$(echo "$line" | awk '{print $2}')
  echo "  ${key}: $adapter"
  jq --arg k "$key" --arg a "$adapter" '. + {($k): $a}' "$ADDR_FILE" > "$ADDR_FILE.tmp" && mv "$ADDR_FILE.tmp" "$ADDR_FILE"
}

deploy_one "Aave V3" "$V3_DPS" "AaveV3InstancesMeta"
echo "  -> recorded in $ADDR_FILE"
