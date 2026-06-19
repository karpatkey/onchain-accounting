#!/usr/bin/env bash
# Deploy + register the Euler V2 eVaults meta-adapter on a running dev anvil fork.
#
# Usage:  deploy-euler-vaults-meta.sh <chainId> <eVault[,eVault2,...]>
#   e.g.  deploy-euler-vaults-meta.sh 1 0xB6D6D89ad4b4D61C15a293e28b74f77F6817fF48,0x2B47c128b35DDDcB66Ce2FA5B33c95314a7de245
#
# With no eVault arg, reads the instance set from
#   script/config/nav-config/meta-balance-adapters/<chainId>.json (.EulerVaultsMeta.instances).
#
# Requires deploy.sh to have run first (NAV proxy must exist in state/<chainId>-addresses.json).
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

# eVaults: positional arg wins; otherwise pull the configured instance set.
if [ "$#" -ge 2 ] && [ -n "${2:-}" ]; then
  VAULTS="$2"
else
  [ -f "$NAV_CONFIG" ] || { echo "error: $NAV_CONFIG not found and no eVaults passed" >&2; exit 1; }
  VAULTS=$(jq -r '(.EulerVaultsMeta.instances // []) | join(",")' "$NAV_CONFIG")
fi
[ -n "$VAULTS" ] && [ "$VAULTS" != "null" ] || { echo "error: no eVault instances resolved" >&2; exit 1; }

PROTOCOL_NAME=${DEV_PROTOCOL_NAME:-"Euler"}

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

echo "=== deploy Euler V2 eVaults meta  chain=$CID NAV=$NAV"
echo "    eVaults: $VAULTS"

out=$(
  DEV_NAV_PROXY="$NAV" \
  DEV_PROTOCOL_NAME="$PROTOCOL_NAME" \
  DEV_EULER_VAULTS="$VAULTS" \
  FOUNDRY_PROFILE=dev \
  forge script "$DEPLOY_DIR/deploy-euler-vaults-meta.s.sol:DeployEulerVaultsMeta" \
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
echo "  EulerVaultsMeta: $adapter"

# Persist into the addresses file for the app / later reference.
jq --arg a "$adapter" '. + {EulerVaultsMeta: $a}' "$ADDR_FILE" > "$ADDR_FILE.tmp" && mv "$ADDR_FILE.tmp" "$ADDR_FILE"
echo "  -> recorded in $ADDR_FILE"
