#!/usr/bin/env bash
# Deploy + register the StakeWise V3 vaults meta-adapter on a running dev anvil fork.
#
# Usage:  deploy-stakewise-v3-meta.sh <chainId> [vault[,vault2,...]]
#   e.g.  deploy-stakewise-v3-meta.sh 100
#
# With no vault arg, reads the instance set from
#   script/config/nav-config/meta-balance-adapters/<chainId>.json (.StakeWiseV3VaultsMeta.instances).
# The constructor args (underlyingToken, osTokenVaultController) are read from
#   script/config/contracts-deployment-config/meta-balance-adapters/<chainId>.json.
#
# Requires deploy.sh to have run first (NAV proxy must exist in state/<chainId>-addresses.json) and the
# underlying staking asset (GNO on Gnosis) to be registered + priced (register-assets.sh).
# Registers + seeds the meta-adapter with a single atomic addMetaBalanceAdapter(adapter, instances)
# call (ADR 0010), mirroring script/deploy/06_Configure.s.sol.
set -euo pipefail

CID=${1:?chainId required}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
DEPLOY_DIR="$DEV_DIR/deploy"
CHAINS_CFG="$DEV_DIR/config/chains.json"
NAV_CONFIG="$REPO_ROOT/script/config/nav-config/meta-balance-adapters/$CID.json"
DEPLOY_CONFIG="$REPO_ROOT/script/config/contracts-deployment-config/meta-balance-adapters/$CID.json"

if ! command -v forge >/dev/null 2>&1; then export PATH="$HOME/.foundry/bin:$PATH"; fi
if ! command -v jq >/dev/null 2>&1; then echo "error: jq not on PATH" >&2; exit 1; fi

# Vaults: positional arg wins; otherwise pull the configured instance set.
if [ "$#" -ge 2 ] && [ -n "${2:-}" ]; then
  VAULTS="$2"
else
  [ -f "$NAV_CONFIG" ] || { echo "error: $NAV_CONFIG not found and no vaults passed" >&2; exit 1; }
  VAULTS=$(jq -r '(.StakeWiseV3VaultsMeta.instances // []) | join(",")' "$NAV_CONFIG")
fi
[ -n "$VAULTS" ] && [ "$VAULTS" != "null" ] || { echo "error: no StakeWise vault instances resolved" >&2; exit 1; }

[ -f "$DEPLOY_CONFIG" ] || { echo "error: $DEPLOY_CONFIG not found" >&2; exit 1; }
UNDERLYING=$(jq -r '.StakeWiseV3VaultsMeta.constructor.underlyingToken' "$DEPLOY_CONFIG")
OSTOKEN_CTRL=$(jq -r '.StakeWiseV3VaultsMeta.constructor.osTokenVaultController' "$DEPLOY_CONFIG")
PROTOCOL_NAME=${DEV_PROTOCOL_NAME:-$(jq -r '.StakeWiseV3VaultsMeta.constructor.protocol // "StakeWise V3"' "$DEPLOY_CONFIG")}
[ "$UNDERLYING" != "null" ] && [ "$OSTOKEN_CTRL" != "null" ] || { echo "error: missing underlyingToken/osTokenVaultController in $DEPLOY_CONFIG" >&2; exit 1; }

# Anvil prefunded account #0 (holds MANAGER after 01_DeployNAV).
DEV_PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEV_DEPLOYER_ADDR="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

PORT=$(jq -r ".\"$CID\".port" "$CHAINS_CFG")
RPC="http://127.0.0.1:$PORT"
ADDR_FILE="$STATE_DIR/$CID-addresses.json"
[ -f "$ADDR_FILE" ] || { echo "error: $ADDR_FILE not found — run deploy.sh $CID first" >&2; exit 1; }
NAV=$(jq -r '.NAVCalculatorProxy' "$ADDR_FILE")
if [ "$NAV" = "null" ] || [ -z "$NAV" ]; then echo "error: no NAVCalculatorProxy in $ADDR_FILE" >&2; exit 1; fi

echo "=== deploy StakeWise V3 vaults meta  chain=$CID NAV=$NAV"
echo "    underlying=$UNDERLYING  osTokenController=$OSTOKEN_CTRL"
echo "    vaults: $VAULTS"

out=$(
  DEV_NAV_PROXY="$NAV" \
  DEV_PROTOCOL_NAME="$PROTOCOL_NAME" \
  DEV_UNDERLYING_TOKEN="$UNDERLYING" \
  DEV_OSTOKEN_CONTROLLER="$OSTOKEN_CTRL" \
  DEV_STAKEWISE_VAULTS="$VAULTS" \
  FOUNDRY_PROFILE=dev \
  forge script "$DEPLOY_DIR/deploy-stakewise-v3-meta.s.sol:DeployStakeWiseV3VaultsMeta" \
    --rpc-url "$RPC" \
    --private-key "$DEV_PRIVATE_KEY" \
    --sender "$DEV_DEPLOYER_ADDR" \
    --broadcast \
    2>&1
)
line=$(printf '%s\n' "$out" | grep -E '^\s*DEPLOYED ' | tail -1 || true)
if [ -z "$line" ]; then
  printf '%s\n' "$out" | tail -40
  echo "error: deploy produced no DEPLOYED line; aborting"
  exit 1
fi
adapter=$(echo "$line" | awk '{print $2}')
echo "  StakeWiseV3VaultsMeta: $adapter"

jq --arg a "$adapter" '. + {StakeWiseV3VaultsMeta: $a}' "$ADDR_FILE" > "$ADDR_FILE.tmp" && mv "$ADDR_FILE.tmp" "$ADDR_FILE"
echo "  -> recorded in $ADDR_FILE"
