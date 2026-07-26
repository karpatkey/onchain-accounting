#!/usr/bin/env bash
# Deploy + register the PancakeSwap V3 pools assisted adapter on a running dev anvil fork (ADR 0015).
#
# Usage:  deploy-pancakeswap-v3-meta.sh <chainId> [account] [tokenId,tokenId2,...]
#   e.g.  deploy-pancakeswap-v3-meta.sh 1 0x783C3255340f8Ba524452A9BE5d12a77e9Ce1F53 12345,67890
#
# Requires deploy.sh to have run first (NAV proxy must exist in state/<chainId>-addresses.json).
# Registers the adapter via addBalanceAdapters and, if an account + tokenIds are given, seeds them via
# submitTokenIds (the deployer holds ASSISTANT_ROLE on the dev fork). The adapter reports 0 until ids are fed.
set -euo pipefail

CID=${1:?chainId required}
ACCOUNT=${2:-}
TOKEN_IDS=${3:-}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
DEPLOY_DIR="$DEV_DIR/deploy"
CHAINS_CFG="$DEV_DIR/config/chains.json"

# Canonical PancakeSwap V3 NonfungiblePositionManager (CREATE2 — same address on every chain that
# has PancakeSwap V3: Ethereum, BSC, Base, Arbitrum, ...). Override via DEV_NPM if a chain diverges.
NPM=${DEV_NPM:-0x46A15B0b27311cedF172AB29E4f4766fbE7F4364}

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

echo "=== deploy PancakeSwap V3 assisted  chain=$CID NAV=$NAV NPM=$NPM"
echo "    account: ${ACCOUNT:-<none>}  tokenIds: ${TOKEN_IDS:-<none>}"

out=$(
  DEV_NAV_PROXY="$NAV" \
  DEV_NPM="$NPM" \
  DEV_ACCOUNT="$ACCOUNT" \
  DEV_TOKEN_IDS="$TOKEN_IDS" \
  FOUNDRY_PROFILE=dev \
  forge script "$DEPLOY_DIR/deploy-pancakeswap-v3-meta.s.sol:DeployPancakeSwapV3" \
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
echo "  PancakeSwapV3PoolsAssisted: $adapter"

# Persist into the addresses file for the app / later reference.
jq --arg a "$adapter" '. + {PancakeSwapV3PoolsAssisted: $a}' "$ADDR_FILE" > "$ADDR_FILE.tmp" && mv "$ADDR_FILE.tmp" "$ADDR_FILE"
echo "  -> recorded in $ADDR_FILE"
