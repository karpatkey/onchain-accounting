#!/usr/bin/env bash
# Verify all deployed contracts on all configured chains.
# For each contract: check explorer API; if not verified, run forge verify-contract.
# Requires: forge, jq, curl. Env: ALCHEMY_API_KEY (or chain RPC URLs), ETHERSCAN_API_KEY for all explorers.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"
# Load .env so ALCHEMY_API_KEY (and explorer keys) are set when script is run without sourcing
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi
# Prefer ALCHEMY_API_KEY, fallback to ALCHEMY_APİ_KEY (alternate name used in config)
: "${ALCHEMY_API_KEY:=${ALCHEMY_APİ_KEY:-}}"

CHAIN_IDS=(1 10 100 137 42161 8453)
rpc_url() {
  local cid="$1"
  local url
  case "$cid" in
    1)   url="${MAINNET_URL:-https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}}";;
    10)  url="${OP_URL:-https://opt-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}}";;
    100) url="${GNOSIS_URL:-https://gnosis-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}}";;
    137) url="${POLYGON_URL:-https://polygon-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}}";;
    42161) url="${ARBITRUM_URL:-https://arb-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}}";;
    8453) url="${BASE_URL:-https://base-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}}";;
    *)   echo "Unknown chain $cid" >&2; exit 1;;
  esac
  echo "$url"
}

api_host() {
  case "$1" in
    1)   echo "api.etherscan.io";;
    10)  echo "api-optimistic.etherscan.io";;
    100) echo "api.gnosisscan.io";;
    137) echo "api.polygonscan.com";;
    42161) echo "api.arbiscan.io";;
    8453) echo "api.basescan.org";;
    *)   echo "";;
  esac
}

api_key_var() {
  echo "ETHERSCAN_API_KEY"
}

is_verified() {
  local chain_id="$1"
  local address="$2"
  local host api_key key_var
  host=$(api_host "$chain_id")
  key_var=$(api_key_var "$chain_id")
  api_key="${!key_var}"
  if [[ -z "$host" || -z "$api_key" ]]; then
    echo "skip"
    return
  fi
  local resp
  resp=$(curl -sS "https://${host}/api?module=contract&action=getsourcecode&address=${address}&apikey=${api_key}") || { echo "skip"; return; }
  local code
  # .result can be an array (normal) or a string (API error); only index when array
  code=$(echo "$resp" | jq -r 'if (.result | type) == "array" and (.result[0] != null) then .result[0].SourceCode // empty else empty end')
  if [[ -z "$code" || "$code" == *"Contract source code not verified"* ]]; then
    echo "no"
  else
    echo "yes"
  fi
}

run_verify() {
  local chain_id="$1"
  local name="$2"
  local address="$3"
  local contract_path="$4"
  local constructor_args="$5"
  local key_var
  key_var=$(api_key_var "$chain_id")
  local api_key="${!key_var}"
  if [[ -z "$api_key" ]]; then
    echo "  [SKIP] $name (no API key for chain $chain_id)"
    return
  fi
  local extra=()
  [[ -n "$constructor_args" && "$constructor_args" != "0x" ]] && extra+=(--constructor-args "$constructor_args")
  if forge verify-contract --chain-id "$chain_id" --compiler-version v0.8.30 --etherscan-api-key "$api_key" \
    "${extra[@]}" "$address" "$contract_path"; then
    echo "  [OK] $name"
  else
    echo "  [FAIL] $name"
  fi
}

# Collect VERIFY lines from each chain (one run per chain to get correct addresses from config)
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
for cid in "${CHAIN_IDS[@]}"; do
  url=$(rpc_url "$cid")
  if [[ "$url" == *"alchemy.com"* ]]; then
    if [[ -z "${ALCHEMY_API_KEY}" || "${ALCHEMY_API_KEY}" == "x" ]]; then
      echo "Set ALCHEMY_API_KEY in .env or env (or use MAINNET_URL, etc.) to verify chain $cid" >&2
      continue
    fi
  fi
  forge script script/verify/VerifyEtherscan.s.sol:VerifyEtherscan --rpc-url "$url" 2>/dev/null | grep 'VERIFY|' | sed 's/^[[:space:]]*//' >> "$TMP" || true
done
[[ ! -s "$TMP" ]] && { echo "No VERIFY lines collected. Set RPC URLs and run again." >&2; exit 1; }

while IFS='|' read -r _ chain_id name address contract_path constructor_args; do
  constructor_args="${constructor_args:-0x}"
  constructor_args="${constructor_args//[[:space:]]/}"
  status=$(is_verified "$chain_id" "$address")
  if [[ "$status" == "yes" ]]; then
    echo "[VERIFIED] chain $chain_id $name $address"
  elif [[ "$status" == "skip" ]]; then
    echo "[SKIP] chain $chain_id $name (no API key or request failed)"
  else
    echo "[SUBMIT] chain $chain_id $name $address"
    run_verify "$chain_id" "$name" "$address" "$contract_path" "$constructor_args"
  fi
done < "$TMP"
