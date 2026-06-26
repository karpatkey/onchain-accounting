#!/usr/bin/env bash
# Fetches ERC20DefaultBalanceAdapter address from existing NAVCalculator proxies (forge cast call)
# and updates script/config/chains/<chainId>.json balanceAdapters.ERC20Default.deployed.
# Requires: cast (foundry), jq. Set ALCHEMY_API_KEY (or chain-specific RPC URLs) in .env or env.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_DIR="$ROOT/script/config/chains"
cd "$ROOT"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi
: "${ALCHEMY_API_KEY:=${ALCHEMY_APİ_KEY:-}}"

rpc_url() {
  local cid="$1"
  case "$cid" in
    1)   echo "${MAINNET_URL:-https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}}";;
    10)  echo "${OP_URL:-https://opt-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}}";;
    100) echo "${GNOSIS_URL:-https://gnosis-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}}";;
    137) echo "${POLYGON_URL:-https://polygon-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}}";;
    42161) echo "${ARBITRUM_URL:-https://arb-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}}";;
    8453) echo "${BASE_URL:-https://base-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}}";;
    *)   echo ""; return 1;;
  esac
}

CHAIN_IDS=(1 10 100 137 42161 8453)
NAV_PROXY_JSON_PATH=".deployed.NAVCalculatorProxy"
DEPLOYED_JSON_PATH=".balanceAdapters.ERC20Default.deployed"

for cid in "${CHAIN_IDS[@]}"; do
  config="$CONFIG_DIR/${cid}.json"
  if [[ ! -f "$config" ]]; then
    echo "[SKIP] chain $cid: no config $config"
    continue
  fi

  nav_proxy=$(jq -r "$NAV_PROXY_JSON_PATH // empty" "$config")
  if [[ -z "$nav_proxy" || "$nav_proxy" == "null" ]]; then
    echo "[SKIP] chain $cid: no NAVCalculatorProxy in config"
    continue
  fi

  url=$(rpc_url "$cid" || true)
  if [[ -z "$url" || "$url" == *"${ALCHEMY_API_KEY}"* && -z "${ALCHEMY_API_KEY}" ]]; then
    echo "[SKIP] chain $cid: no RPC URL (set ALCHEMY_API_KEY or \${cid}_URL)"
    continue
  fi

  echo -n "Chain $cid ($nav_proxy): "
  addr=$(cast call "$nav_proxy" "erc20DefaultAdapter()(address)" --rpc-url "$url" 2>/dev/null || true)
  if [[ -z "$addr" || "$addr" == "0x0000000000000000000000000000000000000000" ]]; then
    echo "no adapter or call failed"
    continue
  fi

  # Normalize to checksummed-style (cast returns lowercase)
  addr=$(echo "$addr" | tr -d '\n')
  jq --arg a "$addr" "$DEPLOYED_JSON_PATH = \$a" "$config" > "${config}.tmp"
  mv "${config}.tmp" "$config"
  echo "ERC20Default -> $addr (config updated)"
done

echo "Done."
